# Develop sessions: per-project throwaway identities, the native-ACL mount,
# the git server, the filtered agent, host port forwarding, and teardown.
#
# Split out of run.nix. The body is emitted verbatim in the same position, so
# the generated script is unchanged -- verified by hashing it before and after.

{ tools
, storeLib
, gitServeHooks
, gitServeGuard
, netGatewayStop
}:

''
      mount_id="''${safe:0:180}-$(printf '%s' "$hostpath" | sha256sum | cut -c1-8)"
    fi
    if [ -z "$mount_id" ]; then mount_id=project; fi
    case "$mount_id" in [-.]*) mount_id="_$mount_id" ;; esac
    printf '%s\n' "$mount_id"
  }

  # ---------------------------------------------------------------------
  # Native mounts.
  #
  # A develop session normally sees its project through bindfs, because
  # ownership names exactly one uid: the host directory belongs to the
  # invoking user, which inside the container is uid 0, so the session user
  # cannot write it. bindfs rewrites that on the fly.
  #
  # The rewriting costs the filesystem itself. A FUSE ioctl cannot carry
  # the source fd that FICLONE needs, so reflinks are impossible through
  # bindfs whatever backs it, and a copy-on-write filesystem silently
  # degrades to whole-file copies. The FUSE daemon also caps how many
  # files the whole session can hold open at once.
  #
  # An ACL can name a second uid, which is the piece ownership was
  # missing. The container id map already pairs each container id with a
  # host id, so granting that host id rwx lets the session in without
  # touching ownership - and then the mount can be a plain bind, with the
  # filesystem keeping every native capability.
  #
  # The alternative, an idmapped mount, is not available here: the kernel
  # requires CAP_SYS_ADMIN in the user namespace that owns the superblock,
  # and for a host filesystem that is the initial namespace, which a
  # rootless container is not in.
  # ---------------------------------------------------------------------

  # host_id_for <map-file> <container-id>: translate an id inside the
  # container user namespace to the host id backing it, reading the kernel
  # map rather than assuming an offset - `--userns=keep-id` maps container
  # 0 to the invoking user and container 1.. to the subuid range, so there
  # is no single offset to assume. Columns: id-inside, id-outside, length.
  host_id_for() {
    awk -v id="$2" \
      '{ if (id >= $1 && id < $1 + $3) { print $2 + (id - $1); exit } }' "$1"
  }

  # native_supported <hostdir>: can this directory carry a native mount,
  # and is it worth taking one?
  #
  # Probed, not looked up in a table of filesystem names. Reflink support
  # is a property of the mount, the kernel build and sometimes the mkfs
  # options - xfs without reflink=1, btrfs on a kernel without it - and a
  # name-based table gets every one of those wrong. Ask the ioctl instead;
  # it costs one 4 KiB file. ACLs are probed the same way, since without
  # them there is no way to let the session in.
  #
  # A directory that fails either probe falls back to bindfs, which works
  # everywhere. That is the whole point of making this a probe: turning
  # the option on must never be what breaks a session.
  native_supported() {
    local dir=$1 probe rc=1
    probe=$(mktemp -d "$dir/.nixct-native-probe.XXXXXX" 2>/dev/null) || return 1
    if dd if=/dev/zero of="$probe/a" bs=4096 count=1 status=none 2>/dev/null \
       && cp --reflink=always -- "$probe/a" "$probe/b" 2>/dev/null \
       && setfacl -m "u:$(id -u):rwx" -- "$probe" 2>/dev/null; then
      rc=0
    fi
    rm -rf -- "$probe"
    return "$rc"
  }

  # grant_native_acl <hostdir> <container-uid> <container-gid>: let the
  # session user reach a host directory without rewriting its ownership.
  #
  # The default entries carry it both ways. Files the session creates are
  # owned by the mapped subuid, which the invoking user could not
  # otherwise write, so every directory also gets a default entry for the
  # invoking user - the host keeps full access to whatever a session
  # leaves behind.
  #
  # The recursive pass runs only on the first grant: anything already in
  # the tree predates the default entries and would be unreachable
  # otherwise. After that, re-asserting the top-level entry is enough.
  grant_native_acl() {
    local dir=$1 cuid=$2 cgid=$3 pid huid hgid self
    pid=$(pm inspect "$NAME" --format '{{.State.Pid}}' 2>/dev/null | tr -d '[:space:]')
    if [ -z "$pid" ] || [ ! -r "/proc/$pid/uid_map" ]; then
      echo "native: cannot read the container id maps" >&2
      return 1
    fi
    huid=$(host_id_for "/proc/$pid/uid_map" "$cuid")
    hgid=$(host_id_for "/proc/$pid/gid_map" "$cgid")
    if [ -z "$huid" ] || [ -z "$hgid" ]; then
      echo "native: container id $cuid/$cgid is outside the container id map" >&2
      return 1
    fi
    self=$(id -u)
    if getfacl -pn -- "$dir" 2>/dev/null | grep -q "^user:$huid:rwx"; then
      return 0
    fi
    # Said out loud because it is the one slow step here: on a tree with a
    # large build cache in it this walks a lot of inodes, and silence would
    # read as a hang. Only ever happens once per directory.
    echo "native: granting $dir to the session (first time; walks the tree)" >&2
    # rwX, not rwx: X adds execute only where it belongs - on directories
    # and on files that already carry the bit - so a recursive grant does
    # not turn every source file into an executable.
    if ! setfacl -R -m "u:$huid:rwX" -m "u:$self:rwX" -- "$dir" 2>/dev/null; then
      echo "native: cannot set an ACL on $dir" >&2
      return 1
    fi
    if ! find "$dir" -type d -print0 \
         | xargs -0 -r setfacl -m "d:u:$huid:rwx" -m "d:u:$self:rwx" -- \
         2>/dev/null; then
      echo "native: cannot set default ACLs under $dir" >&2
      return 1
    fi
    mkdir -p "$STATE_DIR/native-acl"
    printf '%s\n' "$dir" > "$STATE_DIR/native-acl/$(printf '%s' "$dir" | sha256sum | cut -c1-16)"
    return 0
  }

  # start_git_server <mount-id> <hostpath> <branch> <push-glob>: serve a
  # host repository to a session over git://, instead of mounting it.
  #
  # A mount gives a session the whole working tree and its whole history,
  # and any damage it does lands directly in the real repository. A git
  # remote gives it a transport instead: it clones what it is allowed to
  # read, works in its own copy, and pushes back only where policy allows.
  # Nothing it does can touch a ref outside that.
  #
  # Both halves are git's own, and neither writes to the served repo:
  #   read  - uploadpack.hideRefs hides every ref but the one branch, so a
  #           clone cannot even see the rest of the history.
  #   write - a pre-receive hook, because git refuses to update a HIDDEN
  #           ref at all, which makes hideRefs unusable for a push policy
  #           that is wider than one exact branch.
  # Both arrive through GIT_CONFIG_SYSTEM on the daemon, so the repository
  # keeps its own config and hooks untouched.
  start_git_server() {
    ${gitServeGuard}
    local mount_id=$1 hostpath=$2 branch=$3 glob=$4
    local dir="$STATE_DIR/git-serve"
    local sock="$dir/$mount_id.sock" pid_file="$dir/$mount_id.pid"
    local cfg="$dir/$mount_id.gitconfig"
    mkdir -p "$dir"
    chmod 0700 "$dir"
    if [ -f "$pid_file" ] \
       && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null \
       && [ -S "$sock" ]; then
      return 0
    fi
    {
      printf '[uploadpack]\n'
      printf '\thideRefs = refs\n'
      printf '\thideRefs = !refs/heads/%s\n' "$branch"
      printf '[core]\n'
      printf '\thooksPath = %s\n' "${gitServeHooks}"
    } > "$cfg"
    rm -f "$sock"
    # --export-all rather than a git-daemon-export-ok marker: writing that
    # marker would mean writing into the served repository, which is the
    # one thing this mode exists to avoid. The socket is 0600 and is only
    # ever bound into this one session.
    GIT_CONFIG_SYSTEM="$cfg" NIXCT_GIT_PUSH_GLOB="$glob" \
      nohup ${tools.socat} "UNIX-LISTEN:$sock,fork,mode=0600" \
        "EXEC:${tools.git} daemon --inetd --export-all --enable=receive-pack --base-path=$hostpath" \
        </dev/null >"$dir/$mount_id.log" 2>&1 &
    disown
    echo $! > "$pid_file"
    local _i
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      [ -S "$sock" ] && return 0
      sleep 0.1
    done
    echo "develop: git server did not come up; see $dir/$mount_id.log" >&2
    return 1
  }

  # start_agent_filter <mount-id> <upstream-sock>: run a filtering proxy in
  # front of the agent and echo the socket it serves.
  #
  # Idempotent per session: a second shell joining reuses the running filter
  # rather than starting a rival on the same path. The pid is recorded where
  # the host watchdog looks, so the filter dies with the session - the socket
  # must not outlive the session that was granted it.
  start_agent_filter() {
    local mount_id=$1 upstream=$2
    local dir="$STATE_DIR/agent-filter"
    local sock="$dir/$mount_id.sock" pid_file="$dir/$mount_id.pid"
    mkdir -p "$dir"
    chmod 0700 "$dir"
    if [ -f "$pid_file" ] \
       && kill -0 "$(cat "$pid_file" 2>/dev/null)" 2>/dev/null \
       && [ -S "$sock" ]; then
      printf '%s\n' "$sock"
      return 0
    fi
    local args=(--upstream "$upstream" --listen "$sock")
    local spec
    for spec in "''${agent_allow[@]+''${agent_allow[@]}}"; do
      args+=(--allow "$spec")
    done
    for spec in "''${agent_deny[@]+''${agent_deny[@]}}"; do
      args+=(--deny "$spec")
    done
    rm -f "$sock"
    nohup ${tools.sshAgentFilter} "''${args[@]}" \
      </dev/null >"$dir/$mount_id.log" 2>&1 &
    disown
    echo $! > "$pid_file"
    local _i
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      [ -S "$sock" ] && { printf '%s\n' "$sock"; return 0; }
      sleep 0.1
    done
    echo "develop: ssh-agent filter did not come up; see $dir/$mount_id.log" >&2
    return 1
  }

  # allow_git_dir <session-user> <uid> <gid> <container-path>: mark a path
  # trusted in the session global git config.
  #
  # A native mount is a plain bind, so the directory keeps its HOST owner,
  # which inside the container is uid 0 - not the session user. Both git
  # and libgit2 refuse to open a repository owned by somebody else
  # (CVE-2022-24765), and nix fetches a flake through libgit2, so without
  # this a native session cannot evaluate the flake it is standing in.
  # The ACL grants access but deliberately does not change ownership, so
  # this is the piece that has to say the ownership is expected.
  #
  # safe.directory only counts from a PROTECTED config - system or global,
  # never the repository - which is why this goes in ~/.gitconfig. The
  # host copy from --mount-gitconfig lives at ~/.config/git/config so the
  # two never contend for one file; git reads both.
  allow_git_dir() {
    # shellcheck disable=SC2016
    pm exec -u root "$NAME" \
      /run/current-system/sw/bin/bash -c '
        export PATH=/run/current-system/sw/bin
        set -e
        cfg=/develop-home/$1/$5
        dir=$(dirname -- "$cfg")
        mkdir -p -- "$dir"
        chown "$2:$3" "$dir"
        [ -f "$cfg" ] || printf "[safe]\n" > "$cfg"
        grep -qxF "  directory = $4" "$cfg" \
          || printf "  directory = %s\n" "$4" >> "$cfg"
        chown "$2:$3" "$cfg"
        chmod 0644 "$cfg"
      ' bash "$1" "$2" "$3" "$4" "$5"
  }

  # already_mounted <container-path>: is something already mounted there?
  already_mounted() {
    pm exec -u root "$NAME" \
      /run/current-system/sw/bin/mountpoint -q -- "$1" 2>/dev/null
  }

  # bind_native <container-src> <container-dst> <ro|rw>: hand a directory
  # already visible under /hostmnts to a session as a plain bind mount,
  # with no FUSE in the path. Made private so it cannot propagate back
  # through the rshared /hostmnts peer group into the host mount table.
  bind_native() {
    # shellcheck disable=SC2016
    pm exec -u root "$NAME" \
      /run/current-system/sw/bin/bash -c '
        export PATH=/run/current-system/sw/bin:/run/wrappers/bin
        set -e
        src=$1; dst=$2; mode=$3
        mkdir -p -- "$dst"
        if ! mountpoint -q -- "$dst"; then
          mount --bind -- "$src" "$dst"
          mount --make-private -- "$dst"
          if [ "$mode" = "ro" ]; then
            mount -o remount,bind,ro -- "$dst"
          fi
        fi
      ' bash "$1" "$2" "$3"
  }

  # use_native <hostdir> <container-uid> <container-gid> <label>: decide
  # and prepare. Echoes nothing; returns 0 for a native mount, 1 to fall
  # back to bindfs, after saying which and why.
  use_native() {
    local dir=$1 cuid=$2 cgid=$3 label=$4
    if ! native_supported "$dir"; then
      echo "$label: no reflink or ACL support here - using bindfs" >&2
      return 1
    fi
    if ! grant_native_acl "$dir" "$cuid" "$cgid"; then
      echo "$label: could not grant access - using bindfs" >&2
      return 1
    fi
    return 0
  }

  # ensure_host_port <port>: make the HOST's 127.0.0.1:<port> reachable at the
  # same address inside the container.
  #
  # Not a network route on purpose. Services that only listen on loopback
  # often authenticate by looking the caller up in the host /proc/net/tcp
  # (claude-code-transparent-router does exactly this, and fails closed when
  # the peer is not there). A connection made from the container netns is not
  # in that table at all, so it would be refused however the packets got
  # there. Bridging through a unix socket instead means the TCP connection to
  # the service is opened by a HOST process owned by the invoking user, which
  # is what such a check is asking about:
  #
  #   session -> 127.0.0.1:<port> in the container   (socat, container side)
  #           -> unix socket in $SOCKET_MOUNTS       (shared via the bind)
  #           -> 127.0.0.1:<port> on the host        (socat, host side, us)
  #
  # One pair per port, shared by every session: the container has a single
  # netns, so the port can only be bound once anyway. Anything in the
  # container can therefore use the port - it is as trusted as the service
  # behind it.
  ensure_host_port() {
    local port=$1
    local dir="$SOCKET_MOUNTS/hostports"
    local sock="$dir/$port"
    local pidfile="$HOST_PORT_DIR/$port.pid"
    mkdir -p "$dir" "$HOST_PORT_DIR"
    chmod 0711 "$dir"
    if [ ! -s "$pidfile" ] || ! kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
      rm -f "$sock"
      nohup ${tools.socat} UNIX-LISTEN:"$sock",fork,mode=0600 \
        TCP:127.0.0.1:"$port" >/dev/null 2>&1 &
      echo $! > "$pidfile"
      # Give socat a moment to create the socket, so the container-side
      # listener does not race it on first use.
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -S "$sock" ] && break
        sleep 0.2
      done
    fi
    local unit="hostport-$port.service"
    if ! pm exec -u root "$NAME" \
        /run/current-system/sw/bin/systemctl is-active --quiet "$unit" 2>/dev/null; then
      # Runs as container root, which IS the invoking host user under
      # rootless podman - so it can open the 0600 socket above without any
      # ACL, while the session user only ever touches the TCP port.
      pm exec -u root "$NAME" \
        /run/current-system/sw/bin/systemd-run \
          --unit="$unit" --collect --quiet \
          /run/current-system/sw/bin/socat \
            TCP-LISTEN:"$port",bind=127.0.0.1,fork,reuseaddr \
            UNIX-CONNECT:/var/socket-mounts/hostports/"$port" >/dev/null
    fi
  }

  # stop_host_ports: kill the host-side bridges (the container-side ones die
  # with the container).
  stop_host_ports() {
    [ -d "$HOST_PORT_DIR" ] || return 0
    local f
    for f in "$HOST_PORT_DIR"/*.pid; do
      [ -e "$f" ] || continue
      kill "$(cat "$f" 2>/dev/null)" 2>/dev/null || true
      rm -f "$f"
    done
  }

  # require_no_live_sessions <subcommand> <force>: refuse to tear the
  # container down while someone is working in it.
  #
  # down/stop/purge/boot kill every process in the container, and with
  # ephemeral storage they take the session HOMEs with them - so an
  # ill-timed one costs whatever those sessions were doing. Live sessions
  # are visible as active session-<id>-<n>.scope units, so ask first and
  # name the projects; --force keeps the old behavior.
  require_no_live_sessions() {
    local subcmd=$1 force=$2
    [ "$force" = "1" ] && return 0
    container_running || return 0
    local units
    units=$(pm exec -u root "$NAME" \
      /run/current-system/sw/bin/systemctl list-units --type=scope \
        --state=active --no-legend 'session-*.scope' 2>/dev/null \
      | awk '{print $1}' | grep '^session-' || true)
    [ -n "$units" ] || return 0
    declare -A counts=()
    local order=() unit id
    while IFS= read -r unit; do
      [ -n "$unit" ] || continue
      id=''${unit#session-}; id=''${id%.scope}; id=''${id%-*}
      if [ -z "''${counts[$id]:-}" ]; then order+=("$id"); fi
      counts[$id]=$(( ''${counts[$id]:-0} + 1 ))
    done <<<"$units"
    echo "$subcmd: refusing - $NAME still has live develop session(s):" >&2
    for id in "''${order[@]}"; do
      local src
      # findmnt reports a bind as DEVICE[/sub/path]; the project path is the
      # bracketed part.
      src=$(_WS="$WORK_SHARED/$id" podman unshare ${tools.bash} -c \
              'findmnt -no SOURCE -- "$_WS" 2>/dev/null' 2>/dev/null \
            | sed -n 's/.*\[\(.*\)\]$/\1/p' | head -1)
      echo "  $id (''${counts[$id]} shell(s))''${src:+ -> $src}" >&2
    done
    echo "  they will lose everything outside the project dir. Re-run with --force to do it anyway." >&2
    return 1
  }

  tear_down() {
    if container_running; then pm stop -t 5 "$NAME" >/dev/null || true; fi
    if container_exists; then pm rm -f "$NAME" >/dev/null || true; fi
    ${netGatewayStop}
    stop_all_session_watchdogs
    stop_host_ports
    # Container's mount-ns dying releases the overlays. Clean up
    # any per-session $WORK_SHARED binds and the rshared self-bind.
    _WS=$WORK_SHARED _MG=$MERGED _SM=$SOCKET_MOUNTS \
    _STATE_DIR=$STATE_DIR _HOST_NIX_DAEMON=$HOST_NIX_DAEMON \
      podman unshare "${tools.bash}" -c '
      set +e
      MERGED="$_MG"
      # store.nix unmount fragment reads these.
      STATE_DIR="$_STATE_DIR"
      HOST_NIX_DAEMON="$_HOST_NIX_DAEMON"
      # socat-proxied socket binds: $WS/.sockets/<ns>/<name>
      if [ -d "$_WS/.sockets" ]; then
        for d in "$_WS"/.sockets/*/; do
          [ -d "$d" ] || continue
          for f in "$d"*; do
            [ -e "$f" ] && mountpoint -q -- "$f" && umount -- "$f"
          done
        done
      fi
      # Raw socket binds: $SM/<ns>/<name>
      if [ -d "$_SM" ]; then
        for d in "$_SM"/*/; do
          [ -d "$d" ] || continue
          for f in "$d"*; do
            [ -e "$f" ] && mountpoint -q -- "$f" && umount -- "$f"
          done
        done
      fi
      mountpoint -q -- "$_SM" && umount -- "$_SM"
      # Per-develop project binds: $WS/<id>
      for d in "$_WS"/*; do
        case "$d" in
          *"/.sockets") continue ;;
        esac
        [ -d "$d" ] && mountpoint -q -- "$d" && umount -- "$d"
      done
      mountpoint -q -- "$_WS" && umount -- "$_WS"''
