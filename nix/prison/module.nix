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
#                       Torn down in reverse on stop.
#
#   <n>-<svc>.service   Type=exec, one per service, BindsTo <n>.service.
#                       Runs the container in the foreground so systemd
#                       supervises and restarts it directly -- there is
#                       nothing inside the prison that could.
#
# The ruleset is loaded into a namespace the prison owns but cannot reach:
# `podman unshare` enters the rootless user namespace that owns the netns,
# which is where the capability to write a ruleset lives. Nothing in the
# prison is on that side of the boundary.
#
# No command line is written here either. This file asks the backend for argv
# and puts it in a unit.

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
    concatMapStringsSep
    escapeShellArg
    escapeShellArgs
    ;

  backend = import ./podman-backend.nix { inherit pkgs lib; };
  fuse = import ../fuse.nix { inherit pkgs; };
  fuseBin = "${fuse}/bin/nix-store-shared-fuse";

  nftBin = "${pkgs.nftables}/bin/nft";
  nsenterBin = "${pkgs.util-linux}/bin/nsenter";
  storeUnit = import ./store-unit.nix {
    inherit
      lib
      pkgs
      backend
      fuseBin
      ;
  };
  storeUnitName = p: s: "${p.name}-store-${s.name}";

  serviceHelpers = import ./service-unit.nix { inherit lib pkgs backend; };
  inherit (serviceHelpers) syncCmd serviceUnit;

  prisonUnit =
    p:
    let
      # A prison that joins another's netns owns no namespace: no owner
      # container to start, no ruleset to load, nothing to tear down but
      # its own store views. Its unit still mounts the views and syncs
      # configs, and waits for the owning prison's unit first so the
      # namespace exists before any service tries to join it.
      joining = (p.joins or null) != null;
      storeUnits = map (s: "${storeUnitName p s}.service") p.allServices;
      setup = pkgs.writeShellApplication {
        name = "${p.name}-up";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.podman
          pkgs.util-linux
          pkgs.nftables
        ];
        text = ''
          set -euo pipefail
          STATE=${escapeShellArg p.stateDir}
          mkdir -p "$STATE/store" "$STATE/config"

          # A writable persistent path is a host directory bound in; podman
          # would otherwise create it as root. Read-only entries are not
          # created: a credential that does not exist is a deployment error,
          # and an empty file conjured here would hide it.
          ${concatMapStringsSep "\n" (
            s:
            concatMapStringsSep "\n" (pm: ''
              mkdir -p ${escapeShellArg pm.host}
              # chown from inside the user namespace: the service runs as an
              # unprivileged uid *in the container*, which on the host is a
              # mapped subuid, not this user. Chowning to the host user would
              # give the container root's id and leave the service unable to
              # write its own state.
              podman unshare chown ${toString s.uid}:${toString s.gid} ${escapeShellArg pm.host}
            '') (lib.filter (pm: !(pm.readOnly or false)) s.persist)
          ) p.allServices}

          ${concatMapStringsSep "\n" (s: syncCmd p s) (lib.filter (s: s.hasConfig) p.allServices)}

          ${lib.optionalString (!joining) ''
            if ! ${backend.podmanBin} container exists ${backend.ownerName p} 2>/dev/null; then
              ${escapeShellArgs (backend.runOwner p)} >/dev/null
            elif [ "$(${backend.podmanBin} inspect ${backend.ownerName p} --format '{{.State.Status}}' 2>/dev/null)" != running ]; then
              ${backend.podmanBin} start ${backend.ownerName p} >/dev/null
            fi
          ''}

          ${lib.optionalString p.wantsNetwork ''
            gpid=$(${backend.podmanBin} inspect ${backend.ownerName p} --format '{{.State.Pid}}' | tr -d '[:space:]')
            if [ -z "$gpid" ] || [ "$gpid" = 0 ]; then
              echo "${p.name}: namespace owner did not start" >&2
              exit 1
            fi
            ${backend.podmanBin} unshare ${pkgs.bash}/bin/bash -c \
              '${nsenterBin} --net=/proc/'"$gpid"'/ns/net ${nftBin} -f ${p.ruleset}'
          ''}
        '';
      };

      teardown = pkgs.writeShellApplication {
        name = "${p.name}-down";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.podman
        ];
        text = ''
          set -uo pipefail
          ${lib.optionalString (
            !joining
          ) "${backend.podmanBin} rm -f ${backend.ownerName p} >/dev/null 2>&1 || true"}
          exit 0
        '';
      };
    in
    nameValuePair p.name {
      description =
        "${p.name}: "
        + (
          if joining then
            "store views and config (shares ${p.joins} network namespace)"
          else
            "namespace owner, store views and network policy"
        );
      after = [
        (if p.wantsNetwork then "network-online.target" else "network.target")
        # %U expands to the numeric uid selected by User=.  Keep the
        # rootless Podman user manager alive until every prison unit has
        # stopped; otherwise shutdown can remove its D-Bus socket while
        # podman is still stopping containers.
        "user@%U.service"
      ]
      ++ storeUnits
      ++ lib.optional joining "${p.joins}.service";
      wants = lib.optional p.wantsNetwork "network-online.target";
      requires =
        [ "user@%U.service" ]
        ++ storeUnits
        ++ lib.optional joining "${p.joins}.service";
      bindsTo = storeUnits;
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = p.user;
        ExecStart = "${setup}/bin/${p.name}-up";
        ExecStop = "${teardown}/bin/${p.name}-down";
      };
    };
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

    systemd.services =
      (mapAttrs' (_: p: prisonUnit p) cfg)
      // lib.listToAttrs (
        lib.concatMap (p: map (s: storeUnit p s) p.allServices) (builtins.attrValues cfg)
      )
      // lib.listToAttrs (
        lib.concatMap (p: map (s: serviceUnit p s) p.svcList) (builtins.attrValues cfg)
      );
  };
}
