# Socket / X11 / Wayland forwarding helpers, used by the enter and
# develop subcommands. Returns a string of bash function definitions.
#
# Tool resolution comes through `tools`; every reference to bash is
# `${tools.bash}` so it is a full /nix/store path on NixOS and a bare
# name on the portable target. Relies on the caller having set
# $WORK_SHARED and $SOCKET_MOUNTS and provided a pm() wrapper.

{ tools }:

''
  # bind_workdir <host-path> <mount-id>: per-develop bind under
  # $WORK_SHARED/<mount-id>. Args go through env vars, never
  # interpolated into shell strings, to avoid injection from
  # attacker-controlled directory names.
  bind_workdir() {
    _SRC=$1 _DST="$WORK_SHARED/$2" \
      podman unshare "${tools.bash}" -c '
      set -euo pipefail
      mkdir -p -- "$_DST"
      if ! mountpoint -q -- "$_DST"; then
        mount --bind -- "$_SRC" "$_DST"
      fi
    '
  }

  # bind_socket <namespace> <name> <host-sock>: bind a host
  # socket at $WORK_SHARED/.sockets/<ns>/<name>. The in-container
  # socat proxy (spawn_socket_proxy) then exposes it at
  # /run/sockets/<ns>/<name> with the session-user uid. Use for
  # protocols that do NOT need SCM_RIGHTS fd-passing
  # (ssh-agent, dbus session bus, etc.). Args go through env
  # vars to avoid injection.
  bind_socket() {
    _SRC=$3 _DST="$WORK_SHARED/.sockets/$1/$2" \
      podman unshare "${tools.bash}" -c '
      set -euo pipefail
      mkdir -p -- "$(dirname -- "$_DST")"
      [ -e "$_DST" ] || : > "$_DST"
      if ! mountpoint -q -- "$_DST"; then
        mount --bind -- "$_SRC" "$_DST"
      fi
    '
  }

  # bind_raw_socket <namespace> <name> <host-sock>: bind a host
  # socket DIRECTLY at $SOCKET_MOUNTS/<ns>/<name>, no socat
  # proxy. The container sees it at /var/socket-mounts/<ns>/<name>;
  # session users can connect because /var/socket-mounts is
  # 0711 (traverse) and the socket file's host perms gate
  # access (typically 0755 for wayland, 0777 for X11). Use for
  # protocols that REQUIRE SCM_RIGHTS fd-passing (Wayland, X11).
  bind_raw_socket() {
    _SRC=$3 _DST="$SOCKET_MOUNTS/$1/$2" \
      podman unshare "${tools.bash}" -c '
      set -euo pipefail
      mkdir -p -- "$(dirname -- "$_DST")"
      chmod 0711 -- "$(dirname -- "$_DST")"
      [ -e "$_DST" ] || : > "$_DST"
      if ! mountpoint -q -- "$_DST"; then
        mount --bind -- "$_SRC" "$_DST"
      fi
    '
  }

  # bind_raw_socket_from_container <namespace> <name> <container-src-path>:
  # the REVERSE of bind_raw_socket - the socket already exists INSIDE
  # the container (e.g. a daemon listening there), and this exposes it
  # to the HOST at $SOCKET_MOUNTS/<ns>/<name>. Works because
  # /var/socket-mounts is bind-mounted from $SOCKET_MOUNTS with
  # `rshared` propagation (see run.nix): a new mount created on
  # EITHER side of an rshared peer relationship propagates to the
  # other side automatically, so bind-mounting the in-container
  # socket onto the container's own view of that shared dir makes it
  # appear at the host path too, with no separate host-side mount.
  bind_raw_socket_from_container() {
    local ns=$1 name=$2 src=$3
    local dst="/var/socket-mounts/$ns/$name"
    # shellcheck disable=SC2016
    pm exec -u root "$NAME" "${tools.bash}" -lc '
      set -euo pipefail
      dst=$1; src=$2
      mkdir -p -- "$(dirname -- "$dst")"
      chmod 0711 -- "$(dirname -- "$dst")"
      [ -e "$dst" ] || : > "$dst"
      if ! mountpoint -q -- "$dst"; then
        mount --bind -- "$src" "$dst"
      fi
    ' bash "$dst" "$src"
  }

  # grant_wayland_acl <ns> <uid> <host-sock>: grant <uid> (a develop
  # session's throwaway uid, seen from the SAME namespace podman
  # unshare operates in - no translation needed) an rw ACL entry on
  # the real compositor socket, and record the socket path under
  # $STATE_DIR so the session teardown can revoke it. Idempotent
  # (setfacl -m on an existing entry just updates it).
  grant_wayland_acl() {
    local ns=$1 uid=$2 sock=$3
    mkdir -p "$STATE_DIR/wayland-acl"
    printf '%s\n' "$sock" > "$STATE_DIR/wayland-acl/$ns"
    podman unshare "${tools.bash}" -c '
      setfacl -m "u:$1:rw" -- "$2" 2>/dev/null || true
    ' bash "$uid" "$sock"
  }

  # spawn_socket_proxy <namespace> <name> <uid> <gid> [bind_to]:
  # ensure a socat proxy is running inside the container that
  # listens on /run/sockets/<ns>/<name> owned by the session
  # user, forwarding connections to /hostmnts/.sockets/<ns>/<name>.
  #
  # We need a proxy (not bindfs) because FUSE filesystems can't
  # route AF_UNIX connect() syscalls - bindfs would show the
  # socket inode but `connect` to it returns ECONNREFUSED.
  #
  # If <bind_to> is given (e.g. session-<id>.scope), socat dies
  # with that unit via systemd BindsTo. For enter-style forwards
  # there's no scope; socat persists until container down.
  spawn_socket_proxy() {
    local ns=$1 name=$2 uid=$3 gid=$4 bind_to=''${5:-}
    local unit="socket-proxy-''${ns}-''${name}.service"
    # Idempotent: skip if already active.
    if pm exec -u root "$NAME" \
        /run/current-system/sw/bin/systemctl is-active --quiet \
        "$unit" 2>/dev/null; then
      return 0
    fi
    local args=(
      --unit="$unit" --collect --quiet
      --setenv=NS="$ns" --setenv=NAME="$name"
      --setenv=UID_="$uid" --setenv=GID_="$gid"
    )
    if [ -n "$bind_to" ]; then
      args+=(
        --property=BindsTo="$bind_to"
        --property=After="$bind_to"
      )
    fi
    # shellcheck disable=SC2016
    pm exec -u root "$NAME" \
      /run/current-system/sw/bin/systemd-run \
        "''${args[@]}" \
        --setenv=PATH=/run/current-system/sw/bin:/run/wrappers/bin \
        /run/current-system/sw/bin/bash -c '
          set -e
          mkdir -p "/run/sockets/$NS"
          chmod 0711 "/run/sockets/$NS"
          rm -f "/run/sockets/$NS/$NAME"
          exec socat \
            UNIX-LISTEN:"/run/sockets/$NS/$NAME",fork,reuseaddr,user="$UID_",group="$GID_",mode=0600 \
            UNIX-CONNECT:"/hostmnts/.sockets/$NS/$NAME"
        ' >/dev/null
  }

  # ensure_xdg_runtime <uid> <gid>: create /run/user/<uid> owned
  # by the session user, mode 0700. Many GUI apps (Firefox,
  # Wayland clients, dbus libs) hard-require XDG_RUNTIME_DIR.
  # We skip PAM/logind, so we have to mint this directory
  # ourselves. Idempotent.
  ensure_xdg_runtime() {
    local uid=$1 gid=$2
    # shellcheck disable=SC2016
    pm exec -u root "$NAME" \
      /run/current-system/sw/bin/bash -lc '
        set -e
        d="/run/user/$1"
        mkdir -p "$d"
        chown "$1:$2" "$d"
        chmod 0700 "$d"
      ' bash "$uid" "$gid" >/dev/null
  }

  # setup_x11 <mode> <ns> <uid> <gid> [<scope>]: orchestrate the
  # forwarding side of X11. Echoes two lines on stdout for the
  # caller: "DISPLAY=:<n>" and "XCOOKIE=<hex>". Returns 0 on
  # success, 1 if X11 isn't available on the host.
  #
  # mode = "trusted":   use the host's existing cookie (like ssh -Y).
  # mode = "untrusted": run `xauth generate` to mint a fresh
  #                     SECURITY-extension-restricted cookie
  #                     (like ssh -X). Requires the host's X
  #                     server to support the SECURITY extension.
  setup_x11() {
    local mode=$1 ns=$2 uid=$3 gid=$4 scope=''${5:-}
    if [ -z "''${DISPLAY:-}" ]; then
      echo "--x11: \$DISPLAY is not set on the host" >&2
      return 1
    fi
    local hd=''${DISPLAY#:}; hd=''${hd%.*}
    local host_sock=/tmp/.X11-unix/X$hd
    if [ ! -S "$host_sock" ]; then
      echo "--x11: X11 socket not found at $host_sock" >&2
      return 1
    fi

    # Get / generate the cookie.
    local cookie
    case "$mode" in
      trusted)
        cookie=$(xauth list "$DISPLAY" 2>/dev/null \
                  | awk 'NR==1 {print $3}')
        if [ -z "$cookie" ]; then
          echo "--x11: no MIT-MAGIC-COOKIE for $DISPLAY in host xauth" >&2
          return 1
        fi
        ;;
      untrusted)
        local tmp; tmp=$(mktemp --tmpdir nixct-xauth.XXXXXX)
        chmod 600 "$tmp"
        if ! xauth -f "$tmp" generate "$DISPLAY" . \
                     untrusted timeout 0 2>/dev/null; then
          rm -f "$tmp"
          echo "--x11-untrusted: xauth generate failed (SECURITY extension missing?)" >&2
          return 1
        fi
        cookie=$(xauth -f "$tmp" list "$DISPLAY" \
                  | awk 'NR==1 {print $3}')
        rm -f "$tmp"
        ;;
      *) echo "setup_x11: bad mode $mode" >&2; return 1 ;;
    esac

    # Forward the host socket DIRECTLY (no socat) - X11 uses
    # SCM_RIGHTS fd-passing for SHM, DRI, etc.
    bind_raw_socket "$ns" x11 "$host_sock"

    # Inside the container: drop a /tmp/.X11-unix/X<uid> symlink
    # so the conventional path resolves to the bound socket.
    # We use the session uid as the display number to avoid
    # collisions between concurrent sessions.
    # shellcheck disable=SC2016
    pm exec -u root "$NAME" \
      /run/current-system/sw/bin/bash -lc '
        set -e
        mkdir -p /tmp/.X11-unix
        chmod 1777 /tmp/.X11-unix
        ln -sfn "/var/socket-mounts/$1/x11" "/tmp/.X11-unix/X$2"
      ' bash "$ns" "$uid" >/dev/null

    ensure_xdg_runtime "$uid" "$gid"
    printf 'DISPLAY=:%s\n' "$uid"
    printf 'XCOOKIE=%s\n' "$cookie"
    printf 'XDG_RUNTIME_DIR=/run/user/%s\n' "$uid"
  }

  # setup_wayland <ns> <uid> <gid> [<scope>]: forward the
  # Wayland compositor socket. Many clients (including Firefox)
  # only accept WAYLAND_DISPLAY as a RELATIVE name and resolve
  # it against XDG_RUNTIME_DIR. So we make
  # /run/user/<uid>/wayland-0 a symlink to the proxied socket
  # and emit XDG_RUNTIME_DIR + WAYLAND_DISPLAY=wayland-0.
  setup_wayland() {
    local ns=$1 uid=$2 gid=$3 scope=''${4:-}
    local wd=''${WAYLAND_DISPLAY:-wayland-0}
    local host_sock
    case "$wd" in
      /*) host_sock=$wd ;;
      *)
        if [ -z "''${XDG_RUNTIME_DIR:-}" ]; then
          echo "--wayland: XDG_RUNTIME_DIR is not set on the host" >&2
          return 1
        fi
        host_sock=$XDG_RUNTIME_DIR/$wd
        ;;
    esac
    if [ ! -S "$host_sock" ]; then
      echo "--wayland: Wayland socket not found at $host_sock" >&2
      return 1
    fi
    # Forward the host socket DIRECTLY (no socat) - Wayland
    # heavily uses SCM_RIGHTS fd-passing for shm pools,
    # dma-buf imports, etc.
    bind_raw_socket "$ns" wayland "$host_sock"

    # The session uid is not the socket's owning uid (develop's
    # throwaway users in particular), so connect() would otherwise
    # EACCES - AF_UNIX requires write permission on the socket file,
    # and the host compositor socket is normally 0755 owner-only-write.
    # Grant that uid an ACL entry instead of loosening the mode bits
    # (which would expose it to every uid, including other sessions).
    # This modifies the REAL host socket (bind mounts share one inode,
    # so there is no way to permission only the bound alias) - recorded
    # under $STATE_DIR so the session teardown can revoke it; see
    # revoke_wayland_acl in host-watchdog.nix.
    grant_wayland_acl "$ns" "$uid" "$host_sock"

    ensure_xdg_runtime "$uid" "$gid"

    # Make $XDG_RUNTIME_DIR/wayland-0 a symlink to the bound
    # socket so clients that expect the conventional layout
    # find it.
    # shellcheck disable=SC2016
    pm exec -u root "$NAME" \
      /run/current-system/sw/bin/bash -lc '
        set -e
        target="/run/user/$1/wayland-0"
        ln -sfn "/var/socket-mounts/$2/wayland" "$target"
        chown -h "$1:$3" "$target"
      ' bash "$uid" "$ns" "$gid" >/dev/null

    printf 'XDG_RUNTIME_DIR=/run/user/%s\n' "$uid"
    printf 'WAYLAND_DISPLAY=wayland-0\n'
  }

  # parse_socket_spec <spec>: prints "NAME HOSTPATH" or errors out.
  # Accepts "name=host_path" (name must match [A-Za-z0-9._-]+).
  parse_socket_spec() {
    local spec=$1 name path
    case "$spec" in
      *=*) name=''${spec%%=*}; path=''${spec#*=} ;;
      *)
        echo "socket spec must be name=host_path: $spec" >&2
        return 1 ;;
    esac
    case "$name" in
      ""|*[!A-Za-z0-9._-]*|.*|-*)
        echo "invalid socket name: $name" >&2
        return 1 ;;
    esac
    # Resolve and validate the host socket.
    local resolved
    if ! resolved=$(realpath -- "$path" 2>/dev/null); then
      echo "cannot resolve socket path: $path" >&2
      return 1
    fi
    if [ ! -S "$resolved" ]; then
      echo "not a socket: $resolved" >&2
      return 1
    fi
    printf '%s\n%s\n' "$name" "$resolved"
  }
''
