# Container lifecycle: the podman wrapper, container state queries, terminal
# and lxcfs helpers, and the invocation that starts the container.
#
# Split out of run.nix. The body is emitted verbatim in the same position, so
# the generated script is unchanged -- verified by hashing it before and after.

{ tools
, storeLib
, netFlagsLine
, netGatewayFns
, netGatewayStart
, ociRuntimeFlag
}:

''
  # ----- podman wrapper + container state -----------------------

  pm() {
    podman \
      --root "$PODMAN_ROOT" \
      --runroot "$PODMAN_RUNROOT" \
      ${ociRuntimeFlag} \
      "$@"
  }

  container_exists() { pm container exists "$NAME"; }
  container_running() {
    test -n "$(pm ps --quiet --filter "name=^$NAME$" --filter status=running)"
  }

  # FULL PATH, not a bare `systemctl`: podman exec runs the command directly
  # with the image PATH, where it does not resolve. A bare probe therefore
  # returned 127 every time, the loop never saw "running", and EVERY `up`
  # paid the entire 60-second timeout (plus 120 podman execs) before warning
  # and carrying on anyway.
  # Terminal capabilities of the invoking terminal, as VAR=value lines.
  #
  # `podman exec -t` gives the session a bare TERM=xterm regardless of what
  # the real terminal is, so full-screen TUIs (Claude Code among them) drop
  # to their reduced mode - 16 colours, no truecolor - even on a capable
  # terminal. Forward what the host advertises, the way ssh does.
  #
  # Terminal only, deliberately not LANG/LC_*: the container carries its own
  # locale archive, and a host locale it lacks (en_GB.UTF-8 against a
  # container built with en_US.UTF-8) would just make every program warn.
  # The container default is UTF-8 already, which is what TUI drawing needs.
  # Put the terminal back the way we found it when a session ends.
  #
  # A TUI in the session drives the HOST terminal - podman only proxies the
  # pty - so mouse tracking, the alternate screen and alternate scroll are
  # set on the real terminal. An app that exits abnormally (killed, or the
  # exec torn down under it) never sends its restore sequences, and the
  # terminal is left in that mode AFTER the session is gone: the wheel keeps
  # sending arrow keys, so scrolling walks shell history instead of the
  # scrollback. Undo the modes a session can plausibly have set.
  restore_term() {
    [ -t 1 ] || return 0
    # alt screen, the mouse reporting modes, alternate scroll, bracketed
    # paste, cursor visibility, attributes.
    printf '\033[?1049l\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1015l\033[?1007l\033[?2004l\033[?25h\033[0m'
  }

  term_env() {
    if [ -n "''${TERM:-}" ]; then printf 'TERM=%s\n' "$TERM"; fi
    if [ -n "''${COLORTERM:-}" ]; then printf 'COLORTERM=%s\n' "$COLORTERM"; fi
    if [ -n "''${TERM_PROGRAM:-}" ]; then printf 'TERM_PROGRAM=%s\n' "$TERM_PROGRAM"; fi
    if [ -n "''${TERM_PROGRAM_VERSION:-}" ]; then
      printf 'TERM_PROGRAM_VERSION=%s\n' "$TERM_PROGRAM_VERSION"
    fi
    return 0
  }

  wait_for_systemd() {
    local _i state
    for _i in $(seq 1 120); do
      state=$(pm exec "$NAME" \
        /run/current-system/sw/bin/systemctl is-system-running 2>/dev/null || true)
      case "$state" in
        running|degraded) return 0 ;;
      esac
      sleep 0.5
    done
    echo "warning: systemd did not reach running state" >&2
    pm exec "$NAME" \
      /run/current-system/sw/bin/systemctl --failed --no-legend 2>/dev/null || true
    return 0
  }

  lxcfs_flags() {
    if [ ! -d /var/lib/lxcfs/proc ]; then return 0; fi
    local f
    for f in cpuinfo meminfo stat uptime swaps diskstats loadavg slabinfo; do
      [ -e "/var/lib/lxcfs/proc/$f" ] \
        && printf -- '-v %s:%s:ro\n' "/var/lib/lxcfs/proc/$f" "/proc/$f"
    done
    [ -e /var/lib/lxcfs/sys/devices/system/cpu/online ] \
      && printf -- '-v %s:%s:ro\n' \
           "/var/lib/lxcfs/sys/devices/system/cpu/online" \
           "/sys/devices/system/cpu/online"
  }

  ${netGatewayFns}

  # start_persistent: mount overlays + WORK_SHARED, create+start
  # detached container. Container holds the mount-ns; the
  # `podman unshare bash` exits but the mounts survive.
  start_persistent() {
    ensure_state
    ${netGatewayStart}
    # Mount the squashfs rootfs lower (portable target only) before
    # the `podman unshare` so the resulting fuse mount propagates
    # into the unshare's mount-ns and stays there for the container.
    mount_rootfs_lower
    # Ensure the host watchdog dir exists - it gets bind-mounted
    # into the container so per-session watchdogs (spawned by
    # `develop`) and the in-container watchdogs can rendezvous
    # over `$HOST_WATCHDOG_DIR/<mount_id>/sock`.
    mkdir -p "$HOST_WATCHDOG_DIR"
    # HOST_NIX_STORE: pin the symlink-farm closure in the host store with
    # an indirect GC root for the container's lifetime (no-op otherwise).
    plant_store_gcroot
    migrate_to_keepid
    export USE_KEEP_ID KEEPID_UID KEEPID_GID
    export ROOTFS UPPER WORK MERGED NIX_UPPER NIX_WORK STATE_DIR
    # New /nix provisioning axes (consumed by store.nix mountAll).
    export STORAGE HOST_NIX_STORE HOST_NIX_DAEMON
    export FUSE_BIN REDIRECT_ROOT NIX_STORE_LOWER
    export PODMAN_ROOT PODMAN_RUNROOT NAME WORK_SHARED SOCKET_MOUNTS
    export HOST_WATCHDOG_DIR
    export SESSION_GCROOTS
    export LXCFS_FLAGS
    LXCFS_FLAGS=$(lxcfs_flags)
    # GPU / OpenGL flags from --gpu / --opengl (computed by caller).
    export GPU_FLAGS_STR
    GPU_FLAGS_STR=$(accelerator_flags \
      "''${ENABLE_GPU:-0}" "''${ENABLE_OPENGL:-0}")
    # Host UID/GID kept for any future per-volume idmap.
    HOST_UID=$(id -u)
    HOST_GID=$(id -g)
    export HOST_UID HOST_GID

    podman unshare "${tools.bash}" <<'INNER'
  set -euo pipefail

  # Mount the rootfs base + provision /nix (per the storage/host-nix
  # axes; see nix/scripts/lib/store.nix).
  ${storeLib.mountAll}

  # WORK_SHARED and SOCKET_MOUNTS must be shared mounts so
  # host-side bind-mounts under them propagate into the
  # container's view.
  if ! mountpoint -q "$WORK_SHARED"; then
    mount --bind "$WORK_SHARED" "$WORK_SHARED"
  fi
  mount --make-rshared "$WORK_SHARED"
  if ! mountpoint -q "$SOCKET_MOUNTS"; then
    mount --bind "$SOCKET_MOUNTS" "$SOCKET_MOUNTS"
  fi
  mount --make-rshared "$SOCKET_MOUNTS"

  # HOST_NIX_DAEMON: bind the per-session GC-root dir at the IDENTICAL
  # absolute path in the container, so symlinks created there by the
  # gcroot-keeper resolve the same in both namespaces and the host
  # daemon protects the referenced store paths.
  GCROOTS_BIND=()
  if [ "''${HOST_NIX_DAEMON:-0}" = "1" ]; then
    GCROOTS_BIND=(-v "$SESSION_GCROOTS:$SESSION_GCROOTS")
  fi

  # /hostmnts is the bind target for host paths added via the
  # `develop` subcommand. Owned by container root (= host
  # sirati); session users see only their per-session bindfs
  # view at /develop-home/<user>.
  FLAGS=(
    --name "$NAME"
    --systemd=always
    --cgroupns=host
    --cap-add=SYS_ADMIN
    --cap-add=NET_RAW
  )
  # Networking. Without isolateLan the container owns its namespace and
  # gets NET_ADMIN to configure it. With isolateLan it joins the gateway
  # container namespace instead and NET_ADMIN is withheld: the capability
  # set is decided out here, by the host, and nothing inside can widen it -
  # a process that unshares a fresh user namespace becomes root only over
  # what THAT namespace owns, which is not this network namespace. So the
  # session can use the network and cannot touch the rules filtering it.
  ${netFlagsLine}
  FLAGS+=(
    --device=/dev/fuse
    --security-opt unmask=/sys/fs/cgroup
    # systempaths=unconfined removes the default RO/mask of
    # /proc/sys and friends so systemd-sysctl can apply
    # net.ipv4.ping_group_range and other in-namespace settings.
    # Network sysctls are namespaced (each net-ns has its own),
    # so this can't affect the host. Other parts of /proc/sys
    # are also writable now, but the container is already
    # privileged enough to call any syscall that needs them.
    --security-opt systempaths=unconfined
    --security-opt label=disable
    # Match typical Linux desktop rlimits. Without these,
    # podman defaults can yield EAGAIN when large apps spawn
    # threads (Firefox, ML toolkits). Capped by host's hard
    # limit for the invoking user.
    --ulimit nproc=-1:-1
    # The SOFT limit is what processes actually get, and 1024 is far too
    # low here: a `cargo build -j32` holds well over a thousand files open
    # by itself. Worse, every open through a FUSE mount also consumes a
    # handle inside the FUSE DAEMON, so a 1024-soft bindfs became a ~660
    # file ceiling shared by everything using that project mount - and it
    # failed as EMFILE in whichever build touched it next, which looks
    # like a corrupt dependency rather than a limit.
    #
    # Derived from the host rather than hardcoded: podman cannot exceed the
    # invoking user's hard limit anyway, and this way raising it on the host
    # (systemd DefaultLimitNOFILE / pam limits) lifts the container and its
    # FUSE daemons with it, with no change here.
    --ulimit "nofile=$NOFILE_SOFT:$NOFILE_HARD"
    # podman's own default (--pids-limit=2048) is a SEPARATE
    # cgroup-level ceiling from the ulimits above - it's sized for
    # podman's typical single-process-container use case, not a full
    # systemd system plus whatever heavy multi-process apps (browsers,
    # ML toolkits) run inside a develop session. All of it - systemd,
    # every service, every session - shares ONE pids.max here, so
    # unlimited matches a normal PC's lack of an artificial ceiling.
    --pids-limit=-1
    # podman defaults /dev/shm to 64M, which is a desktop-app
    # footgun in here: Chromium and friends put their shared
    # buffers there and die in confusing ways when it fills.
    --shm-size=1g
    --hostname "$NAME"
    -v "$WORK_SHARED:/hostmnts:rshared"
    -v "$SOCKET_MOUNTS:/var/socket-mounts:rshared"
    -v "$HOST_WATCHDOG_DIR:/var/host-watchdog"
    --rootfs "$MERGED"
  )

  LXCFS=()
  if [ -n "''${LXCFS_FLAGS:-}" ]; then
    # shellcheck disable=SC2206
    LXCFS=($LXCFS_FLAGS)
  fi

  GPU=()
  if [ -n "''${GPU_FLAGS_STR:-}" ]; then
    # shellcheck disable=SC2206
    GPU=($GPU_FLAGS_STR)
  fi

  USERNS=()
  if [ "''${USE_KEEP_ID:-0}" = "1" ]; then
    # --userns=keep-id (without an explicit --user) makes pid 1
    # run as the calling host user's uid, NOT container-root.
    # Force --user 0:0 so systemd starts as container uid 0
    # (= host first subuid under keep-id mapping) and the
    # NixOS activation can chmod/chown the rootfs as root.
    USERNS=(
      --userns=keep-id:uid="$KEEPID_UID",gid="$KEEPID_GID"
      --user=0:0
    )
  fi

  podman --root "$PODMAN_ROOT" --runroot "$PODMAN_RUNROOT" \
    ${ociRuntimeFlag} run -d \
    "''${LXCFS[@]+''${LXCFS[@]}}" \
    "''${GPU[@]+''${GPU[@]}}" \
    "''${USERNS[@]+''${USERNS[@]}}" \
    "''${GCROOTS_BIND[@]+''${GCROOTS_BIND[@]}}" \
    "''${FLAGS[@]}" \
    /init >/dev/null
  INNER

    wait_for_systemd
  }

  # ensure_running: start_persistent if not already running.
  # Auto-up here never enables GPU - use `up --gpu` explicitly
  # if you need it.
  ensure_running() {
    if container_running; then maybe_start_idle_monitor; return 0; fi
    if container_exists; then pm rm -f "$NAME" >/dev/null; fi
    ENABLE_GPU=0 start_persistent
    maybe_start_idle_monitor
  }

  # maybe_start_idle_monitor: spawn the host-side __idle-monitor loop
  # detached, but only when an idle timeout is configured. The monitor
  # re-execs THIS script and recomputes every path from the prologue;
  # we hand it STATE_DIR/NAME + the resolved /nix axes + the timeout in
  # the env so it lands on the identical paths. setsid + redirections + disown
  # fully detach it from the foreground command; the monitor's own
  # flock keeps a single instance even across repeated calls.
  # mark_activity: bump the idle-monitor's activity marker. Called
  # whenever we ensure the container is running or (re)start a develop
  # session, so the monitor counts develop setup - the window between
  # `ensure_running` and the session-scope actually existing - as
  # activity and never tears the container down mid-setup.
  mark_activity() { touch "$STATE_DIR/.idle-activity" 2>/dev/null || true; }

  maybe_start_idle_monitor() {
    [ "''${IDLE_TIMEOUT:-0}" -gt 0 ] || return 0
    mark_activity
    STATE_DIR="$STATE_DIR" NAME="$NAME" \
      STORAGE="$STORAGE" HOST_NIX_STORE="$HOST_NIX_STORE" \
      HOST_NIX_DAEMON="$HOST_NIX_DAEMON" \
      FUSE_BIN="$FUSE_BIN" REDIRECT_ROOT="$REDIRECT_ROOT" \
      NIX_STORE_LOWER="$NIX_STORE_LOWER" \
      NIXCT_IDLE_TIMEOUT="$IDLE_TIMEOUT" \
      setsid "$0" __idle-monitor </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  }
''
