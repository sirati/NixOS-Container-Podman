# NixOS module: run prisons from systemd units on the host.
#
# Two kinds of unit per prison, because they have different lifetimes:
#
#   <n>.service               oneshot + RemainAfterExit. Mounts each service's
#                             store view, creates the pod, and loads the
#                             nftables ruleset into the namespace owner's
#                             network namespace from the host. Torn down in
#                             reverse on stop.
#
#   <n>-<svc>.service         Type=exec, one per service, BindsTo <n>.service.
#                             Runs the container in the foreground so systemd
#                             supervises and restarts it directly -- there is
#                             nothing inside the prison to do that, by design.
#
# The ruleset is loaded by the host into a namespace the prison owns but cannot
# reach: `podman unshare` enters the rootless user namespace that owns the
# netns, which is where the capability to write a ruleset lives. Nothing in
# the prison is on that side of the boundary.

{ prison }:

{ config, lib, pkgs, ... }:

let
  cfg = config.services.prisons;
  inherit (lib) mkOption types mkIf mapAttrs' nameValuePair concatMapStringsSep escapeShellArgs;

  podmanBin = "${pkgs.podman}/bin/podman";
  crunBin = "${pkgs.crun}/bin/crun";
  nftBin = "${pkgs.nftables}/bin/nft";
  nsenterBin = "${pkgs.util-linux}/bin/nsenter";
  fusermountBin = "${pkgs.fuse3}/bin/fusermount3";

  # Common podman flags for every service container. Everything here is a
  # denial; the additions live in the per-service block below.
  baseFlags = [
    "--runtime" crunBin
    "--cap-drop=ALL"
    "--security-opt" "no-new-privileges"
    "--security-opt" "label=disable"
  ];

  serviceUnit = p: s:
    let
      mnt = "${p.stateDir}/store/${s.name}";
      tmpfsOpts = "rw,noexec,nosuid,nodev,mode=0700";
      stateMounts = lib.concatMap
        (st: [ "--mount" "type=tmpfs,destination=${st.path},tmpfs-size=${st.size or "64M"},tmpfs-mode=0700,noexec,nosuid,nodev" ])
        s.state;
      persistMounts = lib.concatMap
        (pm: [ "--mount" "type=bind,source=${pm.host},destination=${pm.path},rw,noexec,nosuid,nodev" ])
        s.persist;
      capAdds = map (c: "--cap-add=${c}") s.capabilities;
      envArgs = lib.concatLists (lib.mapAttrsToList (k: v: [ "--env" "${k}=${v}" ]) s.environment);
    in
    nameValuePair "${p.name}-${s.name}" {
      description = "prison ${p.name}: service ${s.name}";
      after = [ "${p.name}.service" ];
      bindsTo = [ "${p.name}.service" ];
      partOf = [ "${p.name}.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "exec";
        User = p.user;
        Restart = "on-failure";
        RestartSec = 2;
        # The container is removed on stop so a restart never inherits a
        # half-written writable layer from the previous run.
        ExecStart = escapeShellArgs ([
          podmanBin
          "run"
          "--rm"
          "--name" "${p.name}-${s.name}"
          "--user" "${toString s.uid}:${toString s.gid}"
          "--mount" "type=bind,source=${mnt},destination=/nix/store,ro"
          "--mount" "type=tmpfs,destination=/tmp,tmpfs-size=${s.tmpfsSize},tmpfs-mode=1777,noexec,nosuid,nodev"
        ]
        ++ lib.optionals s.readOnlyRoot [ "--read-only" ]
        ++ lib.optionals s.init [ "--init" "--init-path" p.initBin ]
        # Joins the namespace owned by <n>-net. The service container has no
        # namespace of its own to reconfigure, and the ruleset governing it
        # was loaded from the host into a namespace it cannot reach.
        ++ [ "--network" "container:${p.name}-net" ]
        ++ baseFlags ++ capAdds ++ envArgs ++ stateMounts ++ persistMounts
        ++ s.extraPodmanArgs
        # --rootfs is a BOOLEAN flag: the path is the positional image
        # argument, so it must come last, immediately before argv. Emitting it
        # earlier makes podman parse the next flag as the command --
        # "executable file `--user` not found in $PATH".
        ++ [ "--rootfs" "${s.rootfs}:O" ]
        ++ s.argv);
        ExecStop = escapeShellArgs [ podmanBin "stop" "-t" "10" "${p.name}-${s.name}" ];
      };
    };

  podUnit = p:
    let
      fuseBin = "${p.fuse}/bin/nix-store-shared-fuse";
      netFlag = if p.wantsNetwork then [ "--network" "pasta" ] else [ "--network" "none" ];

      setup = pkgs.writeShellApplication {
        name = "${p.name}-up";
        runtimeInputs = [ pkgs.coreutils pkgs.podman pkgs.util-linux pkgs.fuse3 pkgs.nftables ];
        text = ''
          set -euo pipefail
          STATE=${lib.escapeShellArg p.stateDir}
          mkdir -p "$STATE/store"

          # One FUSE mount per service: each sees its own closure and nothing
          # else, so a service cannot reach a sibling's binaries even though
          # they share a pod.
          ${concatMapStringsSep "\n" (s: ''
            mkdir -p "$STATE/store/${s.name}"
            if ! mountpoint -q "$STATE/store/${s.name}"; then
              ${fuseBin} \
                --bind-target ${s.storeFarm}/nix/store \
                --resolution-root /nix/store \
                --allow-other \
                "$STATE/store/${s.name}"
            fi
          '') p.svcList}

          # The namespace owner. A --rootfs container from the store, not a
          # podman pod: a pod's infra container comes from podman's image
          # machinery, and whether that pulls an OCI image depends on the
          # host's containers.conf rather than on anything declared here.
          #
          # catatonit is statically linked and copied into the rootfs at
          # /pause, so nothing is bind-mounted and the container has no
          # /nix/store at all. No libc, no coreutils, no `sleep`: the
          # container holding the network is one static binary.
          if ! ${podmanBin} container exists ${p.name}-net 2>/dev/null; then
            ${podmanBin} run -d --name ${p.name}-net \
              --runtime ${crunBin} --cap-drop=ALL \
              --security-opt no-new-privileges --security-opt label=disable \
              --read-only \
              ${escapeShellArgs netFlag} ${escapeShellArgs p.publishArgs} \
              --rootfs ${p.netRootfs}:O ${p.pause} -P >/dev/null
          elif [ "$(${podmanBin} inspect ${p.name}-net --format '{{.State.Status}}' 2>/dev/null)" != running ]; then
            ${podmanBin} start ${p.name}-net >/dev/null
          fi

          ${lib.optionalString p.wantsNetwork ''
            # Load the ruleset from the host, into the namespace the owner
            # container owns. podman unshare enters the rootless user
            # namespace that owns it; nothing in the prison is there.
            gpid=$(${podmanBin} inspect ${p.name}-net --format '{{.State.Pid}}' | tr -d '[:space:]')
            if [ -z "$gpid" ] || [ "$gpid" = 0 ]; then
              echo "${p.name}: namespace owner did not start" >&2
              exit 1
            fi
            _G="$gpid" ${podmanBin} unshare ${pkgs.bash}/bin/bash -c \
              '${nsenterBin} --net=/proc/'"$gpid"'/ns/net ${nftBin} -f ${p.ruleset}'
          ''}
        '';
      };

      teardown = pkgs.writeShellApplication {
        name = "${p.name}-down";
        runtimeInputs = [ pkgs.coreutils pkgs.podman pkgs.fuse3 ];
        text = ''
          set -uo pipefail
          STATE=${lib.escapeShellArg p.stateDir}
          ${podmanBin} rm -f ${p.name}-net >/dev/null 2>&1 || true
          ${concatMapStringsSep "\n" (s: ''
            ${fusermountBin} -u "$STATE/store/${s.name}" 2>/dev/null || true
          '') p.svcList}
          exit 0
        '';
      };
    in
    nameValuePair "${p.name}" {
      description = "prison ${p.name}: pod, store views and network policy";
      after = [ "network.target" ];
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
      `prison.mkPrison`. Every prison gets one oneshot unit for its pod,
      store views and network policy, plus one supervised unit per service.
    '';
  };

  config = mkIf (cfg != { }) {
    assertions = lib.mapAttrsToList
      (n: p: {
        assertion = p.__prison or false;
        message = "services.prisons.${n} is not the result of prison.mkPrison.";
      })
      cfg;

    # Rootless podman needs subuid/subgid so the prison has a second identity to
    # run services under -- container root and the service account must not be
    # the same uid, and neither may be the host user.
    users.users = lib.mapAttrs'
      (n: p: nameValuePair p.user {
        isSystemUser = true;
        group = p.user;
        home = p.stateDir;
        createHome = true;
        autoSubUidGidRange = true;
      })
      cfg;

    users.groups = lib.mapAttrs' (n: p: nameValuePair p.user { }) cfg;

    virtualisation.containers.enable = lib.mkDefault true;

    # The store view is a FUSE mount owned by the prison's host user, but the
    # container process runs as a mapped subuid -- a different uid entirely.
    # Without allow_other the kernel denies it access and crun fails with
    # "failed to exec pid1: Permission denied", which reads like a missing
    # binary rather than a mount permission. --allow-other is refused unless
    # this is set.
    programs.fuse.userAllowOther = lib.mkDefault true;

    systemd.services =
      (lib.mapAttrs' (_: p: podUnit p) cfg)
      // lib.listToAttrs (lib.concatMap
        (p: map (s: serviceUnit p s) p.svcList)
        (builtins.attrValues cfg));
  };
}
