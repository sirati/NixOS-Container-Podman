# Optional per-session D-Bus session bus for `develop --dbus`. Many GUI
# apps assume a working session bus exists and misbehave without one in
# ways that have nothing to do with D-Bus on the surface - e.g. Chrome's
# keyboard/IME handling touches D-Bus, and a missing bus can manifest as
# input just not working rather than a clean D-Bus error.
#
# dbus is NOT a dependency of this flake - the container needs a
# dbus-daemon-providing package in its own package set (e.g. pkgs.dbus).
# The binary path is therefore a fixed in-container symlink path
# resolved at RUNTIME, same convention as wprsd in wprs.nix.
#
# Returns a string of bash function definitions. Relies on the caller
# having set $NAME and provided pm() and ensure_xdg_runtime.

{ tools }:

''
  DBUS_DAEMON_BIN=/run/current-system/sw/bin/dbus-daemon

  # start_session_dbus <mount_id> <uid> <gid>: idempotently start a
  # per-session D-Bus session daemon as the session user. NOT
  # BindsTo=$scope - same reason as wprsd in wprs.nix: the session
  # scope doesn't exist yet at this point in develop's flow, and
  # systemd-run refuses outright to create a unit whose BindsTo=
  # target doesn't exist. Torn down explicitly from
  # inner-watchdog.sh instead. Prints DBUS_SESSION_BUS_ADDRESS on
  # success, same convention as setup_wayland/start_wprsd.
  start_session_dbus() {
    local mount_id=$1 uid=$2 gid=$3
    local unit="session-dbus-$mount_id.service"
    local addr="unix:path=/run/user/$uid/bus"

    if ! pm exec -u root "$NAME" /run/current-system/sw/bin/test -x "$DBUS_DAEMON_BIN" 2>/dev/null; then
      echo "--dbus: dbus-daemon not found in the container - add pkgs.dbus to this container's package set" >&2
      return 1
    fi

    ensure_xdg_runtime "$uid" "$gid"

    if ! pm exec -u root "$NAME" \
        /run/current-system/sw/bin/systemctl is-active --quiet "$unit" 2>/dev/null; then
      pm exec -u root "$NAME" \
        /run/current-system/sw/bin/systemd-run \
          --unit="$unit" --collect --quiet \
          --uid="$uid" --gid="$gid" \
          "$DBUS_DAEMON_BIN" \
            --session --nofork "--address=$addr" >/dev/null
    fi

    local _i dbus_ready=0
    for _i in $(seq 1 50); do
      if pm exec -u root "$NAME" /run/current-system/sw/bin/test -S "/run/user/$uid/bus" 2>/dev/null; then
        dbus_ready=1
        break
      fi
      sleep 0.1
    done
    if [ "$dbus_ready" -ne 1 ]; then
      echo "--dbus: dbus-daemon did not create its socket - check 'systemctl status $unit' in the container" >&2
      return 1
    fi

    printf 'DBUS_SESSION_BUS_ADDRESS=%s\n' "$addr"
  }
''
