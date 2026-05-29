# Per-session HOST watchdog management. One process per develop
# mount_id; listens on $HOST_WATCHDOG_DIR/<mount_id>/sock and exits
# after teardown. Spawned by `develop` once the in-container side is
# ready. The watchdog script body itself lives in host-watchdog.nix;
# these are the lifecycle helpers that start/stop it.
#
# Returns a string of bash function definitions. Relies on the caller
# having set $HOST_WATCHDOG_DIR.

{ hostWatchdogPath }:

''
  # Per-session host watchdog. One process per mount_id; listens
  # on $HOST_WATCHDOG_DIR/<mount_id>/sock; exits after teardown.
  # Spawned by develop, only after the in-container side has
  # set things up. Idempotent: skipped if already running for
  # that mount_id.
  session_watchdog_running() {
    local mount_id=$1
    local pid_file="$HOST_WATCHDOG_DIR/$mount_id/pid"
    [ -f "$pid_file" ] \
      && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null
  }

  start_session_watchdog() {
    local mount_id=$1
    if session_watchdog_running "$mount_id"; then return 0; fi
    mkdir -p "$HOST_WATCHDOG_DIR/$mount_id"
    nohup ${hostWatchdogPath} "$STATE_DIR" "$mount_id" \
      </dev/null \
      >"$HOST_WATCHDOG_DIR/$mount_id/log" 2>&1 &
    disown
    echo $! > "$HOST_WATCHDOG_DIR/$mount_id/pid"
    # Brief wait for the socket to come up.
    local _i
    for _i in $(seq 1 20); do
      [ -S "$HOST_WATCHDOG_DIR/$mount_id/sock" ] && return 0
      sleep 0.1
    done
    return 0
  }

  stop_all_session_watchdogs() {
    if [ ! -d "$HOST_WATCHDOG_DIR" ]; then return 0; fi
    local d
    for d in "$HOST_WATCHDOG_DIR"/*/; do
      [ -d "$d" ] || continue
      local pid_file="$d/pid"
      if [ -f "$pid_file" ]; then
        kill "$(cat "$pid_file")" 2>/dev/null || true
        rm -f "$pid_file"
      fi
      rm -f "$d/sock"
      rmdir "$d" 2>/dev/null || true
    done
  }
''
