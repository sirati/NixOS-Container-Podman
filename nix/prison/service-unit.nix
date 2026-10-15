# Configuration synchronization and supervised service unit generation.
{
  lib,
  pkgs,
  backend,
  storeView,
}:

let
  prisonStart = import ../prison-start.nix { inherit pkgs; };
  storeCheck = import ../prison-store-check.nix { inherit pkgs; };

  inherit (lib) nameValuePair escapeShellArgs;

  # Copy a config tree into the directory bind-mounted into the container.
  # Per file, via a rename inside the same directory, so a reader sees either
  # the old file or the new one and never a half-written one -- and so the
  # directory itself is never replaced, which would detach the bind mount and
  # force the container to be recreated to see the change.
  syncConfig = pkgs.writeShellApplication {
    name = "prison-sync-config";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
    ];
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

  syncCmd =
    p: s:
    escapeShellArgs [
      "${syncConfig}/bin/prison-sync-config"
      "${s.configTree}"
      (backend.configMountPoint p s)
    ];

  # The store views a service runs against: the namespace owner's when the
  # prison owns one, and its own. Restarting a view restarts the owner, which
  # BindsTo every view, and with it every service in the prison.
  viewsOf = p: s: lib.optional (p.infraNet or null != null) p.infraNet ++ [ s ];

  # A start that lands in a switch's window runs the OLD view unit, and the
  # switch, finding the view active, leaves it serving the old closure. Every
  # start of a service therefore checks the running daemons first. If one
  # serves another closure, it queues a restart of the stale views and of
  # this unit, arms a recheck in case that restart is cancelled, and skips
  # this start; too many skips in a row fail the start. Root ("+"), because
  # it restarts system units, arms a transient timer and reads the daemons'
  # command lines.
  storeCheckCmd =
    p: s:
    "+"
    + escapeShellArgs (
      [
        "${storeCheck}/bin/prison-store-check"
        "--systemctl"
        "${pkgs.systemd}/bin/systemctl"
        "--systemd-run"
        "${pkgs.systemd}/bin/systemd-run"
        "--unit"
        "${p.name}-${s.name}.service"
      ]
      ++ lib.concatMap (v: [
        "--view"
        "${storeView.unitName p v}.service"
        (storeView.bindTarget v)
      ]) (viewsOf p s)
    );

  # What every service unit shares, daemon or task.
  commonUnit = p: s: {
    description = "${p.name}: ${s.name}";
    after = [
      "${p.name}.service"
      "prison-user-${p.user}.target"
    ];
    requires = [ "prison-user-${p.user}.target" ];
    bindsTo = [ "${p.name}.service" ];
    partOf = [ "${p.name}.service" ];
    environment.PODMAN_SYSTEMD_UNIT = "${p.name}-${s.name}.service";

    serviceConfig = {
      Delegate = true;
      User = p.user;
      # Exit 1 skips the start without failing it: the queued restart is
      # the recovery. A check that cannot decide fails the start.
      ExecCondition = [ (storeCheckCmd p s) ];
      ExecStartPre = lib.optional s.hasConfig (syncCmd p s);
      # prison-start tells a start this unit's stop interrupted from a
      # start that failed; podman exits 1 for both.
      ExecStart = escapeShellArgs ([ "${prisonStart}/bin/prison-start" ] ++ backend.runService p s);
      # Runs after every stop, including one that interrupted the start or
      # a start that failed, which skip ExecStop and can leave the
      # container behind.
      ExecStopPost = escapeShellArgs (backend.rmArgs p s);
    };
  };

  # A daemon: forking around the detached run, supervised through conmon's
  # pidfile, restarted when it dies, started at boot.
  daemonUnit =
    p: s:
    let
      reload = backend.reloadArgs p s;
    in
    {
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "forking";
        PIDFile = backend.conmonPidFile p s;
        RuntimeDirectory = backend.runtimeDirName p s;
        Restart = "on-failure";
        RestartSec = 2;
        # A stop is not a failure. catatonit reports a daemon that died of
        # the stop's SIGTERM as 143, and conmon passes that on; a stop that
        # lands during ExecStartPre kills the sync with SIGTERM itself.
        SuccessExitStatus = "143 SIGTERM";
        ExecStop = escapeShellArgs (backend.stopArgs p s);
        # Reload re-syncs the configuration and tells the service, without
        # touching the container: the mount is a directory the host rewrites
        # in place, so the new content is already visible inside.
        ExecReload = lib.optionals (reload != null) (
          lib.optional s.hasConfig (syncCmd p s) ++ [ (escapeShellArgs reload) ]
        );
      };
    };

  # A task: the attached run is the unit's process and its exit status the
  # unit's result. A stop signals prison-start, and podman passes the signal
  # to the program. Nothing starts it unless asked, and nothing retries it
  # unless the consumer sets Restart=.
  #
  # No SuccessExitStatus: a task whose program died of SIGTERM (status 143)
  # did not finish and has failed. A stop of the unit is still clean, since
  # prison-start then ends by SIGTERM itself, which systemd counts as clean.
  taskUnit = p: s: {
    wantedBy = [ ];
    serviceConfig = {
      Type = "oneshot";
      Restart = "no";
    };
  };

  serviceUnit =
    p: s:
    nameValuePair "${p.name}-${s.name}" (
      lib.recursiveUpdate (commonUnit p s) ((if s.oneshot or false then taskUnit else daemonUnit) p s)
    );

in
{
  inherit syncCmd storeCheckCmd serviceUnit;
}
