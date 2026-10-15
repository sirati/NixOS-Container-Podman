# NixOS module: run prisons from systemd units on the host.
#
# Three kinds of unit per prison, because they have different privileges and
# lifetimes:
#
#   <n>-store-<svc>.service
#                       Owns one FUSE passthrough store view. This fixed daemon
#                       alone receives the kernel-required CAP_SYS_ADMIN.
#
#   <n>.service         oneshot + RemainAfterExit. Mounts every service's
#                       store view, starts the namespace owner, and loads the
#                       ruleset into its network namespace from the host.
#                       Torn down in reverse on stop, and after a setup
#                       that failed or that a stop interrupted.
#
#   <n>-<svc>.service   Type=forking, one per service, BindsTo <n>.service.
#                       Ready once the detached `podman run` has started the
#                       container; systemd then supervises and restarts it
#                       through conmon's pidfile -- there is nothing inside
#                       the prison that could. Each start first checks that
#                       the running store views serve this unit's closure.
#
# The ruleset is loaded into a namespace the prison owns but cannot reach:
# `podman unshare` enters the rootless user namespace that owns the netns,
# which is where the capability to write a ruleset lives. Nothing in the
# prison is on that side of the boundary.
#
# No command line is written here either. This file asks the backend for argv
# and puts it in a unit: store-unit.nix, owner-unit.nix and service-unit.nix
# build the three kinds.

{ prison }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.prisons;
  inherit (lib)
    mkOption
    types
    mkIf
    mapAttrs'
    nameValuePair
    ;

  backend = import ./podman-backend.nix { inherit pkgs lib; };
  fuse = import ../fuse.nix { inherit pkgs; };

  storeView = import ./store-unit.nix {
    inherit lib pkgs backend;
    fuseBin = "${fuse}/bin/nix-store-shared-fuse";
  };

  serviceHelpers = import ./service-unit.nix { inherit lib pkgs backend storeView; };
  inherit (serviceHelpers) syncCmd serviceUnit;

  ownerUnit = import ./owner-unit.nix { inherit lib pkgs backend storeView syncCmd; };

  # These are the files copied by each generated service unit's ExecStartPre
  # and ExecReload. Keep the inventory derived from the same configTree as
  # syncCmd, so a configuration snapshot cannot drift from the active unit.
  generatedConfigFilesByService = lib.mapAttrs (_: p:
    lib.listToAttrs (map (s: lib.nameValuePair s.name (
      map (rel: "${s.configTree}/${rel}") (builtins.attrNames s.config)
    )) p.svcList)
  ) cfg;

  # The services a prison's start brings back: those the system wants at
  # boot, read from the final unit so a consumer's override counts.
  bootServices =
    p:
    lib.filter (
      s: builtins.elem "multi-user.target" config.systemd.services."${p.name}-${s.name}".wantedBy
    ) p.svcList;

  prisonUnit = p: ownerUnit p (bootServices p);
in
{
  options.services.prisons = mkOption {
    type = types.attrsOf types.attrs;
    default = { };
    description = ''
      Prisons to run, keyed by name. Each value is the result of
      `prison.mkPrison`. Every prison gets one oneshot unit for its namespace
      owner, store views and network policy, plus one supervised unit per
      service.
    '';
  };

  options.services.nixDevContainer = {
    generatedConfigFilesByService = mkOption {
      type = types.attrsOf (types.attrsOf (types.listOf types.str));
      readOnly = true;
      default = generatedConfigFilesByService;
      description = ''
        Store files copied into each prison service's /config directory,
        grouped by prison and service name. This contains configuration
        files only, not a service's package or store closure.
      '';
    };

    generatedConfigFiles = mkOption {
      type = types.listOf types.str;
      readOnly = true;
      default = lib.concatMap (services: lib.concatLists (builtins.attrValues services))
        (builtins.attrValues generatedConfigFilesByService);
      description = ''
        Flat list of store files copied into prison service /config
        directories. Derived from the same config trees used by systemd.
      '';
    };
  };

  config = mkIf (cfg != { }) {
    assertions =
      lib.mapAttrsToList (n: p: {
        assertion = p.__prison or false;
        message = "services.prisons.${n} is not the result of prison.mkPrison.";
      }) cfg
      ++ lib.concatMap (
        n:
        let
          p = cfg.${n};
          target = p.joins or null;
          owners = lib.filter (q: q.name == target) (builtins.attrValues cfg);
        in
        lib.optional (target != null) {
          assertion = owners != [ ] && (builtins.head owners).joins or null == null;
          message =
            "services.prisons.${n} joins ${target}, which is not "
            + "a network-owning prison. Join targets must exist and must "
            + "not themselves join another prison (one hop only).";
        }
      ) (builtins.attrNames cfg);

    # Rootless podman needs subuid/subgid so a prison has a second identity to
    # run services under: the container's root account and the service account
    # must not be the same uid, and neither may be the host user.
    users.users = mapAttrs' (
      _: p:
      nameValuePair p.user {
        isSystemUser = true;
        group = p.user;
        home = p.stateDir;
        createHome = true;
        autoSubUidGidRange = true;
        # Rootless podman needs a systemd user session (cgroup manager
        # systemd, XDG_RUNTIME_DIR): without linger the owner unit's
        # `podman run` degrades to cgroupfs and the pause process setup
        # hangs. Headless servers have no login session to provide one.
        linger = true;
      }
    ) cfg;

    users.groups = mapAttrs' (_: p: nameValuePair p.user { }) cfg;

    # Rootless Podman also needs the newuidmap/newgidmap setuid wrappers.
    # Enabling only the generic containers module creates the subuid ranges,
    # but leaves every prison unable to construct its user namespace.
    virtualisation.podman.enable = lib.mkDefault true;

    # The owner container runs rootless pasta, which binds the published
    # host ports itself. Unprivileged binding below 1024 is denied by
    # default, so a prison publishing 80/443 (or 2222-style SSH) would die
    # in pasta with "Permission denied". Port policy stays in the prison's
    # nft ruleset; this only lets the unprivileged pasta process bind.
    boot.kernel.sysctl."net.ipv4.ip_unprivileged_port_start" = lib.mkDefault 0;

    # The store view is a FUSE mount owned by the prison's host user, but the
    # container runs as a mapped subuid. Without allow_other the kernel denies
    # it and crun fails with "failed to exec pid1: Permission denied", which
    # looks like a missing binary rather than a mount permission.
    programs.fuse.userAllowOther = lib.mkDefault true;

    systemd.generators.prison-user-managers = "${import ./user-manager-generator.nix { inherit pkgs lib; prisons = cfg; }}/bin/prison-user-managers";
    systemd.targets = mapAttrs' (_: p: nameValuePair "prison-user-${p.user}" {
      description = "User manager for prison account ${p.user}";
      # Fail closed if the account lookup generator cannot resolve a UID.
      unitConfig.AssertPathExists = "/run/systemd/generator/prison-user-${p.user}.target.d/account.conf";
    }) cfg;
    systemd.services =
      (mapAttrs' (_: p: prisonUnit p) cfg)
      // lib.listToAttrs (
        lib.concatMap (p: map (s: storeView.mkUnit p s) p.allServices) (builtins.attrValues cfg)
      )
      // lib.listToAttrs (
        lib.concatMap (p: map (s: serviceUnit p s) p.svcList) (builtins.attrValues cfg)
      );
  };
}
