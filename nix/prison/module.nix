# NixOS module: run prisons from systemd units on the host.
#
# Two kinds of unit per prison, because they have different lifetimes:
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

{ config, lib, pkgs, ... }:

let
  cfg = config.services.prisons;
  inherit (lib) mkOption types mkIf mapAttrs' nameValuePair concatMapStringsSep
    escapeShellArg escapeShellArgs;

  backend = import ./podman-backend.nix { inherit pkgs lib; };
  fuse = import ../fuse.nix { inherit pkgs; };
  fuseBin = "${fuse}/bin/nix-store-shared-fuse";

  nftBin = "${pkgs.nftables}/bin/nft";
  nsenterBin = "${pkgs.util-linux}/bin/nsenter";
  fusermountBin = "${pkgs.fuse3}/bin/fusermount3";
  prlimitBin = "${pkgs.util-linux}/bin/prlimit";

  # Raising a hard limit needs privilege, so systemd -- which starts the unit
  # as root -- sets the ceiling, and prlimit lowers each store view to its own
  # cap. The soft limit is deliberately set below the hard one: the FUSE
  # raises it itself on startup, so both mechanisms are exercised rather than
  # one masking a failure in the other.
  nofileArgs = s:
    if s.openFiles == null then [ ]
    else [ prlimitBin "--nofile=${toString (lib.min 1024 s.openFiles)}:${toString s.openFiles}" "--" ];

  unitNofile = p:
    let caps = lib.filter (x: x != null) (map (s: s.openFiles) p.allServices);
    in if caps == [ ] then null else lib.foldl' lib.max 0 caps;

  # Copy a config tree into the directory bind-mounted into the container.
  # Per file, via a rename inside the same directory, so a reader sees either
  # the old file or the new one and never a half-written one -- and so the
  # directory itself is never replaced, which would detach the bind mount and
  # force the container to be recreated to see the change.
  syncConfig = pkgs.writeShellApplication {
    name = "prison-sync-config";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils ];
    text = ''
      set -euo pipefail
      src=$1; dst=$2
      mkdir -p "$dst"
      while IFS= read -r -d ''' f; do
        mkdir -p "$dst/$(dirname "$f")"
        cp -L "$src/$f" "$dst/$f.tmp"
        chmod 0444 "$dst/$f.tmp"
        mv -f "$dst/$f.tmp" "$dst/$f"
      done < <(cd "$src" && find . -type f -print0)
    '';
  };

  syncCmd = p: s: escapeShellArgs [
    "${syncConfig}/bin/prison-sync-config"
    "${s.configTree}"
    (backend.configMountPoint p s)
  ];

  serviceUnit = p: s:
    let reload = backend.reloadArgs p s; in
    nameValuePair "${p.name}-${s.name}" {
      description = "${p.name}: ${s.name}";
      after = [ "${p.name}.service" ];
      bindsTo = [ "${p.name}.service" ];
      partOf = [ "${p.name}.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "exec";
        User = p.user;
        Restart = "on-failure";
        RestartSec = 2;
        ExecStartPre = lib.optional s.hasConfig (syncCmd p s);
        ExecStart = escapeShellArgs (backend.runService p s);
        ExecStop = escapeShellArgs (backend.stopArgs p s);
        # Reload re-syncs the configuration and tells the service, without
        # touching the container: the mount is a directory the host rewrites
        # in place, so the new content is already visible inside.
        ExecReload = lib.optionals (reload != null)
          (lib.optional s.hasConfig (syncCmd p s) ++ [ (escapeShellArgs reload) ]);
      };
    };

  prisonUnit = p:
    let
      setup = pkgs.writeShellApplication {
        name = "${p.name}-up";
        runtimeInputs = [ pkgs.coreutils pkgs.podman pkgs.util-linux pkgs.fuse3 pkgs.nftables ];
        text = ''
          set -euo pipefail
          STATE=${escapeShellArg p.stateDir}
          mkdir -p "$STATE/store" "$STATE/config"

          # A writable persistent path is a host directory bound in; podman
          # would otherwise create it as root. Read-only entries are not
          # created: a credential that does not exist is a deployment error,
          # and an empty file conjured here would hide it.
          ${concatMapStringsSep "\n" (s: concatMapStringsSep "\n" (pm: ''
            mkdir -p ${escapeShellArg pm.host}
            # chown from inside the user namespace: the service runs as an
            # unprivileged uid *in the container*, which on the host is a
            # mapped subuid, not this user. Chowning to the host user would
            # give the container root's id and leave the service unable to
            # write its own state.
            podman unshare chown ${toString s.uid}:${toString s.gid} ${escapeShellArg pm.host}
          '') (lib.filter (pm: !(pm.readOnly or false)) s.persist)) p.allServices}

          # One store view per service: each sees its own closure and nothing
          # else, so a service cannot reach a sibling's binaries even though
          # they share a network namespace. The view is owned by this host
          # user while the container runs as a mapped subuid, hence
          # --allow-other; without it crun reports "failed to exec pid1:
          # Permission denied", which reads like a missing binary.
          ${concatMapStringsSep "\n" (s: ''
            mkdir -p ${escapeShellArg (backend.storeMountPoint p s)}
            if ! mountpoint -q ${escapeShellArg (backend.storeMountPoint p s)}; then
              ${escapeShellArgs (nofileArgs s)} ${fuseBin} \
                --bind-target ${s.storeFarm}/nix/store \
                --resolution-root /nix/store \
                --allow-other \
                ${escapeShellArg (backend.storeMountPoint p s)}
            fi
          '') p.allServices}

          ${concatMapStringsSep "\n" (s: syncCmd p s)
            (lib.filter (s: s.hasConfig) p.allServices)}

          if ! ${backend.podmanBin} container exists ${backend.ownerName p} 2>/dev/null; then
            ${escapeShellArgs (backend.runOwner p)} >/dev/null
          elif [ "$(${backend.podmanBin} inspect ${backend.ownerName p} --format '{{.State.Status}}' 2>/dev/null)" != running ]; then
            ${backend.podmanBin} start ${backend.ownerName p} >/dev/null
          fi

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
        runtimeInputs = [ pkgs.coreutils pkgs.podman pkgs.fuse3 ];
        text = ''
          set -uo pipefail
          ${backend.podmanBin} rm -f ${backend.ownerName p} >/dev/null 2>&1 || true
          ${concatMapStringsSep "\n" (s: ''
            ${fusermountBin} -u ${escapeShellArg (backend.storeMountPoint p s)} 2>/dev/null || true
          '') p.allServices}
          exit 0
        '';
      };
    in
    nameValuePair p.name {
      description = "${p.name}: namespace owner, store views and network policy";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = p.user;
        ExecStart = "${setup}/bin/${p.name}-up";
        ExecStop = "${teardown}/bin/${p.name}-down";
      } // lib.optionalAttrs (unitNofile p != null) {
        # The ceiling each store view is then lowered from.
        LimitNOFILE = unitNofile p;
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
    assertions = lib.mapAttrsToList
      (n: p: {
        assertion = p.__prison or false;
        message = "services.prisons.${n} is not the result of prison.mkPrison.";
      })
      cfg;

    # Rootless podman needs subuid/subgid so a prison has a second identity to
    # run services under: the container's root account and the service account
    # must not be the same uid, and neither may be the host user.
    users.users = mapAttrs'
      (_: p: nameValuePair p.user {
        isSystemUser = true;
        group = p.user;
        home = p.stateDir;
        createHome = true;
        autoSubUidGidRange = true;
      })
      cfg;

    users.groups = mapAttrs' (_: p: nameValuePair p.user { }) cfg;

    virtualisation.containers.enable = lib.mkDefault true;

    # The store view is a FUSE mount owned by the prison's host user, but the
    # container runs as a mapped subuid. Without allow_other the kernel denies
    # it and crun fails with "failed to exec pid1: Permission denied", which
    # looks like a missing binary rather than a mount permission.
    programs.fuse.userAllowOther = lib.mkDefault true;

    systemd.services =
      (mapAttrs' (_: p: prisonUnit p) cfg)
      // lib.listToAttrs (lib.concatMap
        (p: map (s: serviceUnit p s) p.svcList)
        (builtins.attrValues cfg));
  };
}
