# Optional wprs (Wayland proxy: wprsd/wprsc) integration for
# `develop --wprs`. Instead of sharing the real Wayland socket with an
# untrusted per-session develop user (what `--wayland` does - a raw
# bind, full protocol access, SCM_RIGHTS fd-passing), this runs `wprsd`
# INSIDE the session as its own tiny Wayland compositor, and forwards
# only wprsd's own wire protocol out to the host, where a separate
# `wayland-attach`/`wayland-detach` pair of subcommands controls a
# `wprsc` viewer that composites those windows into the REAL host
# compositor. wprsd never touches the host's actual Wayland socket.
#
# XWayland is disabled (--enable-xwayland=false): wprsd hard-crashes
# (not a graceful skip) trying to spawn its embedded XWayland if the
# container doesn't also have an Xwayland binary on $PATH, so this
# only supports native-Wayland apps for now.
#
# wprs itself is NOT a dependency of this flake - it's optional and
# supplied by the downstream caller: `wprsd` must be in the container's
# own package set (e.g. via mkNixct's `packages`), and `wprsc` must be
# on the HOST's $PATH. Every wprsd/wprsc reference below is therefore a
# bare command / a fixed in-container symlink path resolved at RUNTIME,
# not a Nix-store path baked at this flake's build time - the one
# deliberate exception to this script's usual "every tool is
# `${tools.X}`" convention.
#
# Returns a string of bash function definitions. Relies on the caller
# having set $STATE_DIR and $SOCKET_MOUNTS, and provided pm(),
# ensure_xdg_runtime, and bind_raw_socket_from_container.

{ tools }:

''
  # Every environment.systemPackages entry is symlinked here regardless
  # of which package/overlay supplied it, so this path resolves
  # correctly as long as the caller included a wprs package - no
  # build-time dependency on wprs needed.
  WPRSD_BIN=/run/current-system/sw/bin/wprsd

  # start_wprsd <mount_id> <uid> <gid> <scope>: idempotently start
  # wprsd inside the session as the session user, and expose its
  # socket to the host. On success prints env lines (WAYLAND_DISPLAY /
  # XDG_SESSION_TYPE / XDG_RUNTIME_DIR), same convention as
  # setup_wayland/setup_x11.
  #
  # NOT BindsTo=$scope: at this point in `develop`'s flow, the
  # session-$mount_id.scope unit doesn't exist yet (it's only created
  # by the final foreground exec) - systemd-run refuses outright to
  # create a transient unit whose BindsTo= target doesn't exist
  # ("Unit ... not found"), it doesn't just defer the coupling. So
  # wprsd is torn down explicitly instead, from inner-watchdog.sh.
  start_wprsd() {
    local mount_id=$1 uid=$2 gid=$3
    local unit="wprsd-$mount_id.service"

    if ! pm exec -u root "$NAME" /run/current-system/sw/bin/test -x "$WPRSD_BIN" 2>/dev/null; then
      echo "--wprs: wprsd not found in the container - add a wprs package to this container's package set" >&2
      return 1
    fi

    ensure_xdg_runtime "$uid" "$gid"

    if ! pm exec -u root "$NAME" \
        /run/current-system/sw/bin/systemctl is-active --quiet "$unit" 2>/dev/null; then
      pm exec -u root "$NAME" \
        /run/current-system/sw/bin/systemd-run \
          --unit="$unit" --collect --quiet \
          --uid="$uid" --gid="$gid" \
          --setenv="XDG_RUNTIME_DIR=/run/user/$uid" \
          "$WPRSD_BIN" \
            "--socket=/run/user/$uid/wprs.sock" \
            "--wayland-display=wprs-0" \
            "--enable-xwayland=false" >/dev/null
    fi

    # Brief wait for wprsd's socket to appear before wiring up the
    # host-side bind (mirrors start_session_watchdog's own poll).
    local _i wprsd_ready=0
    for _i in $(seq 1 50); do
      if pm exec -u root "$NAME" /run/current-system/sw/bin/test -S "/run/user/$uid/wprs.sock" 2>/dev/null; then
        wprsd_ready=1
        break
      fi
      sleep 0.1
    done
    if [ "$wprsd_ready" -ne 1 ]; then
      echo "--wprs: wprsd did not create its socket - check 'systemctl status $unit' in the container" >&2
      return 1
    fi

    bind_raw_socket_from_container "$mount_id" wprs "/run/user/$uid/wprs.sock"

    printf 'XDG_RUNTIME_DIR=/run/user/%s\n' "$uid"
    printf 'WAYLAND_DISPLAY=wprs-0\n'
    printf 'XDG_SESSION_TYPE=wayland\n'
  }

  # ----- host-side viewer (wprsc) lifecycle, driven by the
  # wayland-attach / wayland-detach subcommands ---------------------

  wprs_viewer_pid_file() {
    printf '%s/wprs-viewers/%s.pid\n' "$STATE_DIR" "$1"
  }

  wprs_viewer_running() {
    local pid_file
    pid_file=$(wprs_viewer_pid_file "$1")
    [ -f "$pid_file" ] && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null
  }

  # wprs_short_sock_path <mount_id>: a short symlink alias for the
  # (potentially long) $SOCKET_MOUNTS/<mount_id>/wprs path. AF_UNIX
  # connect() is limited to ~108 bytes (sockaddr_un/SUN_LEN); a real
  # $STATE_DIR-derived path routinely exceeds that once combined with
  # a real project name and its hash suffix. mount --bind has no such
  # limit, but wprsc's own connect() does, so it needs a short path -
  # a symlink (which the kernel resolves via normal, unlimited path
  # resolution before the length check applies to what's PASSED to
  # connect()) works around it without a second bind mount.
  wprs_short_sock_path() {
    local short
    short=$(printf '%s' "$1" | sha256sum | cut -c1-16)
    printf '%s/nixct-wprs-%s.sock\n' "''${XDG_RUNTIME_DIR:-/tmp}" "$short"
  }

  wprs_attach() {
    local mount_id=$1
    local sock="$SOCKET_MOUNTS/$mount_id/wprs"
    local pid_file short_sock
    pid_file=$(wprs_viewer_pid_file "$mount_id")
    short_sock=$(wprs_short_sock_path "$mount_id")

    if wprs_viewer_running "$mount_id"; then
      echo "wayland-attach: already attached (pid $(cat "$pid_file"))"
      return 0
    fi

    local wprsc_bin
    if ! wprsc_bin=$(command -v wprsc); then
      echo "wayland-attach: wprsc not found on \$PATH - install wprs on the host" >&2
      return 1
    fi

    # $SOCKET_MOUNTS only shows the reverse-bound socket as a live mount
    # from within the podman-unshare namespace (the same reason
    # bind_raw_socket/bind_workdir always operate through it, not the
    # top-level shell) - check and run wprsc there too. WAYLAND_DISPLAY/
    # XDG_RUNTIME_DIR are passed through explicitly since podman unshare
    # doesn't guarantee the same resolvable \$PATH the caller has.
    # `echo $$` runs BEFORE exec, so it captures wprsc's own pid (exec
    # replaces the process image without changing the pid).
    mkdir -p "$(dirname -- "$pid_file")"
    if ! podman unshare "${tools.bash}" -c "test -S '$sock'"; then
      echo "wayland-attach: no wprsd socket for this session - run \`develop --wprs <path>\` first" >&2
      return 1
    fi
    ln -sf -- "$sock" "$short_sock"
    nohup podman unshare "${tools.bash}" -c "
      echo \$\$ > '$pid_file'
      export WAYLAND_DISPLAY='$WAYLAND_DISPLAY' XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR'
      exec '$wprsc_bin' --socket='$short_sock'
    " </dev/null >/dev/null 2>&1 &
    disown
    sleep 0.3
    echo "wayland-attach: attached (pid $(cat "$pid_file" 2>/dev/null))"
  }

  wprs_detach() {
    local mount_id=$1
    local pid_file
    pid_file=$(wprs_viewer_pid_file "$mount_id")
    rm -f -- "$(wprs_short_sock_path "$mount_id")"
    if wprs_viewer_running "$mount_id"; then
      kill "$(cat "$pid_file")" 2>/dev/null || true
      echo "wayland-detach: detached"
    else
      echo "wayland-detach: not attached"
    fi
    rm -f "$pid_file"
  }
''
