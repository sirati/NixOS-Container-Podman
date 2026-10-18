# The prison's own unit, <n>.service. Mounts every
# service's store view, syncs configs, starts the namespace owner and loads
# the ruleset into its network namespace from the host. Torn down in reverse
# on stop, and after a setup that failed or that a stop interrupted. An
# owning prison's unit then waits on its namespace owner and is restarted
# when the owner dies; a joining prison's is a oneshot.
{
  lib,
  pkgs,
  backend,
  storeView,
  syncCmd,
}:

let
  inherit (lib)
    nameValuePair
    concatMapStringsSep
    escapeShellArg
    escapeShellArgs
    ;

  nftBin = "${pkgs.nftables}/bin/nft";
  nsenterBin = "${pkgs.util-linux}/bin/nsenter";
in
# `wantedServices`: the services this prison's start must bring back, the
# ones the system wants at boot. BindsTo stops every child when a store view
# tears down this owner; starting the owner must start them again.
p: wantedServices:
let
  # A prison that joins another's netns owns no namespace: no owner
  # container to start, no ruleset to load, nothing to tear down but
  # its own store views. Its unit still mounts the views and syncs
  # configs, and waits for the owning prison's unit first so the
  # namespace exists before any service tries to join it.
  joining = (p.joins or null) != null;
  storeUnits = map (s: "${storeView.unitName p s}.service") p.allServices;
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

      ${lib.optionalString (!joining) ''
        # Up: this unit now lives as long as the namespace owner does. Its
        # death ends the unit, and systemd restarts it (Restart= below):
        # the owner runs under no unit of its own, so nothing else would.
        ${pkgs.systemd}/bin/systemd-notify --ready
        ${backend.podmanBin} wait ${backend.ownerName p} >/dev/null || true
        # A failure, for OnFailure= and the fault reports, and then a restart.
        echo "${p.name}: namespace owner died" >&2
        exit 3
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
    "suid-sgid-wrappers.service"
    # Dependency specifiers use the system manager's identity, not User=.
    # The generator resolves the account's allocated UID at boot/reload.
    "prison-user-${p.user}.target"
  ]
  ++ storeUnits
  ++ lib.optional joining "${p.joins}.service";
  # BindsTo stops every child when a store view tears down this owner.
  # Starting the owner must bring back unchanged children as well.
  # Wants and not Requires for the setuid wrappers: an update that changes
  # any wrapper stops and starts their unit, and Requires would stop every
  # prison with it. Setup runs after them and fails by itself without them.
  wants =
    lib.optional p.wantsNetwork "network-online.target"
    ++ [ "suid-sgid-wrappers.service" ]
    ++ map (s: "${p.name}-${s.name}.service") wantedServices;
  requires =
    [ "prison-user-${p.user}.target" ]
    ++ storeUnits
    ++ lib.optional joining "${p.joins}.service";
  bindsTo = storeUnits;
  wantedBy = [ "multi-user.target" ];
  path = [ "/run/wrappers" ];
  # An owning prison's unit supervises its namespace owner: ready once set
  # up, ended when the owner dies, then set up again a bounded number of
  # times. Its BindsTo children stop with it, and its Wants bring them back.
  unitConfig = lib.optionalAttrs (!joining) {
    StartLimitIntervalSec = 600;
    StartLimitBurst = 5;
  };
  serviceConfig = (if joining then {
    Type = "oneshot";
    RemainAfterExit = true;
  } else {
    Type = "notify";
    # systemd-notify runs as a child of the setup script.
    NotifyAccess = "all";
    # As for the oneshot it replaces: setup may take long on a busy host.
    TimeoutStartSec = "infinity";
    Restart = "always";
    RestartSec = 5;
  }) // {
    User = p.user;
    ExecStart = "${setup}/bin/${p.name}-up";
    # ExecStopPost and not ExecStop: systemd skips ExecStop when a stop
    # interrupts setup or setup fails, which would leave the namespace
    # owner running. A stop's SIGTERM ending setup is not a failure.
    ExecStopPost = "${teardown}/bin/${p.name}-down";
    SuccessExitStatus = "SIGTERM";
  };
}
