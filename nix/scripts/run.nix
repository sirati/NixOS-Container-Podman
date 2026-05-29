# Main nix-dev-container dispatcher. ~1340 lines of bash, factored
# out of flake.nix so the same text can drive (a) the NixOS-host
# writeShellApplication build and (b) the portable-tarball build.
#
# Tool resolution comes through the `tools` attrset (see
# nix/scripts/tools.nix): every reference to a named binary like bash,
# crun, podman, socat is `${tools.X}` so the value is baked at Nix
# eval time — full /nix/store path on NixOS, bare command name on
# portable. Bare unqualified commands (mkdir, mount, find, ...) keep
# their PATH-resolution behavior because they're either supplied via
# writeShellApplication's runtimeInputs (NixOS) or by the host's
# /usr/bin (portable, with a sane PATH set at script entry).

{ tools
, rootfs ? null
, shellUser
, name
, hostHasNvidiaContainerToolkit ? false
, useKeepId ? false
, keepIdUid ? 1000
, keepIdGid ? 100
, hostWatchdogPath
, checkHostCompatPath  # absolute path to check-host-compat executable
  # OCI-runtime flag passed to podman (in pm() + direct podman runs).
  # NixOS: full /nix/store path to crun, pinned at build time. Portable:
  # empty so podman uses whatever it's configured for (typically runc
  # or crun via /etc/containers/containers.conf on Debian/Fedora/Arch).
, ociRuntimeFlag ? "--runtime ${tools.crun}"
  # Mode-conditional snippets. Defaults are the NixOS-host behavior;
  # the portable-tarball target overrides these.
  #
  # rootfsLine    : bash line(s) at script entry that set $ROOTFS.
  # stateDirLine  : bash line that sets $STATE_DIR.
  # mountLowerBody: body of mount_rootfs_lower(); called before each
  #                 kernel-overlayfs mount. NixOS no-op; portable mounts
  #                 squashfuse on $STATE_DIR/lower-mount and sets $ROOTFS.
, rootfsLine ?
    (if rootfs == null
     then throw "run.nix: rootfsLine must be passed when rootfs is null"
     else "ROOTFS=${rootfs}")
, stateDirLine ?
    "STATE_DIR=\${STATE_DIR:-\${XDG_STATE_HOME:-$HOME/.local/state}/nix-dev-container/$NAME}"
, mountLowerBody ? ":  # NixOS: rootfs is a static /nix/store path; nothing to mount."
}:

''
  # ----------------------------------------------------------------
  # Design (rootless, persistent):
  #
  #   - All mount setup happens inside `podman unshare bash`,
  #     which enters the rootless user-namespace where we have
  #     CAP_SYS_ADMIN.
  #
  #   - Two overlays:
  #       Rootfs overlay (kernel overlayfs, userxattr):
  #         lower = $ROOTFS (Nix store path)
  #         upper = $STATE_DIR/upper
  #         work  = $STATE_DIR/work
  #         merged= $STATE_DIR/merged
  #       Nix-store overlay (fuse-overlayfs - native overlay's
  #         user-ns chmod restrictions break nix's fchmodat2):
  #         lower = /nix/store (host store, RO)
  #         upper = $STATE_DIR/nix-store-upper
  #         work  = $STATE_DIR/nix-store-work
  #         merged= $STATE_DIR/merged/nix/store
  #
  #   - At up time we ALSO bind-mount $STATE_DIR/work-shared to
  #     itself and make it rshared, so the container's /work can
  #     receive host-side bind-mount changes (used by `develop`).
  #
  #   - `podman run -d --rootfs $MERGED --userns=keep-id ...`
  #     forks the container's mount namespace from podman
  #     unshare's. The container holds the overlays alive as
  #     long as it runs. The `podman unshare bash` then exits;
  #     subsequent `podman exec` invocations join the container's
  #     existing mount-ns without any new mount work.
  #
  #   - State that survives invocations:
  #       $STATE_DIR/upper            (rootfs writable layer)
  #       $STATE_DIR/work
  #       $STATE_DIR/nix-store-upper  (/nix/store writable layer)
  #       $STATE_DIR/nix-store-work
  #       $STATE_DIR/work-shared      (current /work bind target)
  #       $STATE_DIR/podman-{root,runroot}  (podman storage)
  #
  #   - `down` stops + removes the container; the overlays
  #     auto-unmount when the container's mount-ns dies. Upper
  #     dirs stay on disk. `purge` wipes everything.
  # ----------------------------------------------------------------

  # Build-time defaults (overridable via env).
  ${rootfsLine}
  SHELL_USER=${shellUser}
  DEFAULT_NAME=${name}
  HOST_HAS_NVCT=${if hostHasNvidiaContainerToolkit then "1" else "0"}
  USE_KEEP_ID=${if useKeepId then "1" else "0"}
  KEEPID_UID=${toString keepIdUid}
  KEEPID_GID=${toString keepIdGid}

  NAME=''${NAME:-$DEFAULT_NAME}
  ${stateDirLine}
  NIX_STORE_MODE=''${NIX_STORE_MODE:-overlay}

  # Lowerdir for the /nix/store fuse-overlayfs. NixOS-host: the host's
  # real /nix/store. Portable: the rootfs-embedded /nix/store (set by
  # mount_rootfs_lower). The :=-assignment leaves a portable override
  # untouched.
  : "''${NIX_STORE_LOWER:=/nix/store}"

  UPPER="$STATE_DIR/upper"
  WORK="$STATE_DIR/work"
  MERGED="$STATE_DIR/merged"
  NIX_UPPER="$STATE_DIR/nix-store-upper"
  NIX_WORK="$STATE_DIR/nix-store-work"
  PODMAN_ROOT="$STATE_DIR/podman-root"
  PODMAN_RUNROOT="$STATE_DIR/podman-runroot"

  # ----- helpers -------------------------------------------------

  # Host-side dir bound into the container as /hostmnts. Each
  # `develop <hostpath>` adds a sub-bind here; the container sees
  # the change via rshared propagation. Mode 0700 so that only
  # container-root (= host sirati) can enumerate it - session
  # users in the container never see /hostmnts directly.
  WORK_SHARED="$STATE_DIR/work-shared"
  # Parallel dir for RAW unix-socket binds (Wayland, X11, …)
  # that need full fd-passing (SCM_RIGHTS). socat can't proxy
  # SCM_RIGHTS, so these have to be bind-mounted directly at a
  # path the session user can traverse. Mode 0711: world can
  # cross but only root can list. The socket files inside
  # inherit their source's perms (typically 0755 for Wayland,
  # 0777 for X11), which is what gates actual access.
  SOCKET_MOUNTS="$STATE_DIR/socket-mounts"

  # Idempotent: create $STATE_DIR layout, pre-populate UPPER with
  # writable copies of every directory NixOS activation chmods or
  # writes into.
  ensure_state() {
    # Host-side dirs that the calling user owns natively: safe
    # to mkdir/chmod directly.
    mkdir -p \
      "$PODMAN_ROOT" "$PODMAN_RUNROOT" \
      "$WORK" "$MERGED" \
      "$WORK_SHARED" "$SOCKET_MOUNTS"
    chmod 0700 -- "$WORK_SHARED"
    chmod 0711 -- "$SOCKET_MOUNTS"

    # UPPER and NIX_UPPER may already be migrated to host's
    # first subuid (when useKeepId is on), so the calling user
    # can neither traverse them nor chmod them directly. Run
    # the layout/perms setup inside `podman unshare`, which
    # has CAP_FOWNER + CAP_DAC_OVERRIDE for files owned by
    # uids mapped in the rootless user-ns - covers both the
    # pre-migration (sirati-owned) and post-migration (subuid-
    # owned) cases.
    _UPPER=$UPPER _NIX_UPPER=$NIX_UPPER _NIX_WORK=$NIX_WORK \
      podman unshare ${tools.bash} -c '
      set -euo pipefail
      mkdir -p "$_UPPER" "$_NIX_UPPER" "$_NIX_WORK"
      mkdir -p \
        "$_UPPER"/bin "$_UPPER"/sbin \
        "$_UPPER"/etc "$_UPPER"/home "$_UPPER"/root \
        "$_UPPER"/usr "$_UPPER"/opt "$_UPPER"/boot "$_UPPER"/mnt \
        "$_UPPER"/srv "$_UPPER"/run "$_UPPER"/run/secrets \
        "$_UPPER"/run/wrappers \
        "$_UPPER"/var "$_UPPER"/var/lib "$_UPPER"/var/log \
        "$_UPPER"/var/cache "$_UPPER"/var/spool "$_UPPER"/var/empty \
        "$_UPPER"/var/tmp "$_UPPER"/tmp \
        "$_UPPER"/work
      # Nix DB / daemon-socket location.
      mkdir -p \
        "$_UPPER"/nix/var/nix/db \
        "$_UPPER"/nix/var/nix/profiles \
        "$_UPPER"/nix/var/nix/gcroots \
        "$_UPPER"/nix/var/nix/temproots \
        "$_UPPER"/nix/var/nix/userpool \
        "$_UPPER"/nix/var/nix/daemon-socket
      chmod 1777 "$_UPPER"/tmp "$_UPPER"/var/tmp
      : > "$_UPPER"/etc/hostname
      : > "$_UPPER"/etc/hosts
      : > "$_UPPER"/etc/resolv.conf
      : > "$_UPPER"/run/.containerenv
    '
  }

  # mount_rootfs_lower: set up $ROOTFS as a usable lowerdir for the
  # kernel-overlayfs mount in start_persistent / boot. NixOS-host: a
  # no-op (ROOTFS is already a /nix/store path). Portable: mount the
  # squashfs blob via squashfuse and point $ROOTFS at the mount.
  # Called BEFORE `podman unshare`, in the host's normal mount-ns, so
  # the unshare inherits the mount.
  mount_rootfs_lower() {
    ${mountLowerBody}
  }

  # Print one token per line for the /nix/store volume mount.
  nix_store_mount_args() {
    case "$NIX_STORE_MODE" in
      overlay)
        echo -v
        echo "/nix/store:/nix/store:O,upperdir=$NIX_UPPER,workdir=$NIX_WORK"
        ;;
      passthrough)
        echo -v
        echo "/nix/store:/nix/store:rw"
        ;;
      ro)
        echo -v
        echo "/nix/store:/nix/store:ro"
        ;;
      *)
        echo "unknown NIX_STORE_MODE: $NIX_STORE_MODE" >&2
        exit 2
        ;;
    esac
  }

  # One token per line for any lxcfs proc/sys files that exist.
  lxcfs_mount_args() {
    if [ ! -d /var/lib/lxcfs/proc ]; then
      return 0
    fi
    local f
    for f in cpuinfo meminfo stat uptime swaps diskstats loadavg slabinfo; do
      if [ -e "/var/lib/lxcfs/proc/$f" ]; then
        echo -v
        echo "/var/lib/lxcfs/proc/$f:/proc/$f:ro"
      fi
    done
    if [ -e /var/lib/lxcfs/sys/devices/system/cpu/online ]; then
      echo -v
      echo "/var/lib/lxcfs/sys/devices/system/cpu/online:/sys/devices/system/cpu/online:ro"
    fi
  }

  # ----- GPU / OpenGL passthrough -------------------------------

  # accelerator_flags <need_cuda> <need_opengl>: print podman
  # flags for nvidia GPU and/or OpenGL passthrough, one token
  # per line. Handles four combinations:
  #
  # CUDA via nvidia-container-toolkit (HOST_HAS_NVCT=1):
  #   `--device nvidia.com/gpu=all`. The toolkit injects all
  #   /dev/nvidia* nodes and the matching libcuda.so userland.
  #   Cross-distro and recommended; works on Debian, Fedora,
  #   Arch, openSUSE, NixOS, etc.
  #
  # CUDA without toolkit:
  #   Bind every /dev/nvidia* node, plus the host directory
  #   containing libcuda.so*. Probed in order:
  #     /run/opengl-driver/lib     - NixOS convention
  #     /usr/lib/x86_64-linux-gnu  - Debian/Ubuntu
  #     /usr/lib64                 - Fedora/RHEL/openSUSE
  #     /usr/lib                   - Arch and others
  #
  # OpenGL:
  #   Bind every /dev/dri/* node (works for Intel / AMD / Mesa
  #   as well as nvidia's GL). Plus the host directory with
  #   libGL.so*, probed the same way.
  #
  # libcuda and libGL live in the same directory on every
  # distro I know of, so when both are requested we bind that
  # dir once. NixOS: /run/opengl-driver gets bound at the same
  # path. Other distros: bound at /opt/host-graphics-libs;
  # the container's shellInit adds it to LD_LIBRARY_PATH.
  accelerator_flags() {
    local need_cuda=$1 need_opengl=$2
    [ "$need_cuda" = "1" ] || [ "$need_opengl" = "1" ] || return 0

    local found=0

    # CUDA via CDI - injects libcuda + /dev/nvidia* itself.
    if [ "$need_cuda" = "1" ] && [ "$HOST_HAS_NVCT" = "1" ]; then
      echo --device
      echo nvidia.com/gpu=all
      found=1
      # CDI doesn't help with OpenGL / Mesa; fall through to
      # the OpenGL section below if also asked.
    fi

    # CUDA without toolkit: manual /dev/nvidia* binds.
    if [ "$need_cuda" = "1" ] && [ "$HOST_HAS_NVCT" != "1" ]; then
      local d
      for d in /dev/nvidia0 /dev/nvidia1 /dev/nvidia2 /dev/nvidia3 \
               /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools \
               /dev/nvidia-modeset; do
        if [ -e "$d" ]; then
          echo --device
          echo "$d"
          found=1
        fi
      done
    fi

    # OpenGL: /dev/dri/* binds.
    if [ "$need_opengl" = "1" ]; then
      local d
      for d in /dev/dri/card0 /dev/dri/card1 /dev/dri/card2 \
               /dev/dri/renderD128 /dev/dri/renderD129 \
               /dev/dri/renderD130; do
        if [ -e "$d" ]; then
          echo --device
          echo "$d"
          found=1
        fi
      done
    fi

    # Find userland libs we still need to provide:
    #   - libcuda.so* if need_cuda and not using toolkit
    #   - libGL.so* if need_opengl (toolkit doesn't ship GL libs)
    local need_libdir=0
    [ "$need_cuda" = "1" ] && [ "$HOST_HAS_NVCT" != "1" ] && need_libdir=1
    [ "$need_opengl" = "1" ] && need_libdir=1
    if [ "$need_libdir" = "0" ]; then return 0; fi

    local lib_dir="" d
    for d in /run/opengl-driver/lib \
             /usr/lib/x86_64-linux-gnu \
             /usr/lib64 \
             /usr/lib; do
      [ -d "$d" ] || continue
      if   [ "$need_cuda" = "1" ] && [ "$HOST_HAS_NVCT" != "1" ] \
           && ls -- "$d"/libcuda.so* >/dev/null 2>&1; then
        lib_dir=$d; break
      elif [ "$need_opengl" = "1" ] \
           && ls -- "$d"/libGL.so* >/dev/null 2>&1; then
        lib_dir=$d; break
      fi
    done
    if [ -n "$lib_dir" ]; then
      case "$lib_dir" in
        /run/opengl-driver/lib)
          echo -v
          echo "/run/opengl-driver:/run/opengl-driver:ro"
          ;;
        *)
          echo -v
          echo "$lib_dir:/opt/host-graphics-libs:ro"
          ;;
      esac
    fi
    # found stays informational; the dev shell still works
    # without these libs if e.g. only /dev/dri was requested
    # and you only need a software renderer.
    : "$found"
  }

  # Back-compat shim: gpu_flags / opengl_flags wrap the combined
  # helper above. ENABLE_GPU / ENABLE_OPENGL are exported by
  # the up/boot dispatch.
  gpu_flags() {
    accelerator_flags "$1" "''${ENABLE_OPENGL:-0}"
  }

  # ----- keep-id ownership migration ----------------------------

  # Default rootless: container uid 0 -> host UID; container
  # UID -> host first subuid+999. keep-id flips the mapping:
  # container UID becomes host UID, container 0 becomes host
  # first subuid. So the rootfs upper (and nix-store upper)
  # currently owned by `host UID` (= container root pre-
  # keep-id) needs to migrate to `host first subuid` so it
  # appears as container root post-keep-id. Conversely for
  # container UID (dev). Other uids (nixbld...) sit in the
  # subuid range and don't need moving.
  #
  # In podman unshare (the default rootless user-ns), the
  # visible mapping is uid 0 = host UID, uid 1 = host first
  # subuid, uid UID = host (subuid+UID-1). So:
  #   chown 0 -> host UID         (= container UID under keep-id)
  #   chown 1 -> host first subuid (= container 0 under keep-id)
  migrate_to_keepid() {
    if [ "$USE_KEEP_ID" != "1" ]; then return 0; fi
    local marker="$STATE_DIR/.keepid-migrated"
    [ -e "$marker" ] && return 0
    echo "keep-id: migrating $STATE_DIR ownership ..."
    _UPPER=$UPPER _NIX_UPPER=$NIX_UPPER \
    _UID=$KEEPID_UID \
      podman unshare ${tools.bash} -c '
      set +e
      # Root files: container uid 0 (= host UID in default
      # rootless) -> uid 1 (= host first subuid = container 0
      # under keep-id).
      find "$_UPPER" "$_NIX_UPPER" -uid 0 -print0 2>/dev/null \
        | xargs -0r chown 1:1
      # Dev files: container uid $UID -> uid 0 (= host UID =
      # container $UID under keep-id).
      find "$_UPPER" "$_NIX_UPPER" -uid "$_UID" -print0 2>/dev/null \
        | xargs -0r chown 0:0
    ' >/dev/null 2>&1 || true
    touch "$marker"
    echo "keep-id: migration done"
  }

  # ----- host watchdog -------------------------------------------

  HOST_WATCHDOG_DIR="$STATE_DIR/host-watchdog"

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

  wait_for_systemd() {
    local _i state
    for _i in $(seq 1 120); do
      state=$(pm exec "$NAME" systemctl is-system-running 2>/dev/null || true)
      case "$state" in
        running|degraded) return 0 ;;
      esac
      sleep 0.5
    done
    echo "warning: systemd did not reach running state" >&2
    pm exec "$NAME" systemctl --failed --no-legend 2>/dev/null || true
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

  # start_persistent: mount overlays + WORK_SHARED, create+start
  # detached container. Container holds the mount-ns; the
  # `podman unshare bash` exits but the mounts survive.
  start_persistent() {
    ensure_state
    # Mount the squashfs rootfs lower (portable target only) before
    # the `podman unshare` so the resulting fuse mount propagates
    # into the unshare's mount-ns and stays there for the container.
    mount_rootfs_lower
    # Ensure the host watchdog dir exists - it gets bind-mounted
    # into the container so per-session watchdogs (spawned by
    # `develop`) and the in-container watchdogs can rendezvous
    # over `$HOST_WATCHDOG_DIR/<mount_id>/sock`.
    mkdir -p "$HOST_WATCHDOG_DIR"
    migrate_to_keepid
    export USE_KEEP_ID KEEPID_UID KEEPID_GID
    export ROOTFS UPPER WORK MERGED NIX_UPPER NIX_WORK NIX_STORE_LOWER
    export PODMAN_ROOT PODMAN_RUNROOT NAME WORK_SHARED SOCKET_MOUNTS
    export HOST_WATCHDOG_DIR
    export LXCFS_FLAGS
    LXCFS_FLAGS=$(lxcfs_flags)
    export NIX_STORE_MODE
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

  # Re-mount overlays (idempotent: unmount any stale ones first).
  fusermount3 -u "$MERGED/nix/store" 2>/dev/null || umount "$MERGED/nix/store" 2>/dev/null || true
  umount "$MERGED" 2>/dev/null || true

  mount -t overlay overlay \
    -o "lowerdir=$ROOTFS,upperdir=$UPPER,workdir=$WORK,userxattr" \
    "$MERGED"

  case "$NIX_STORE_MODE" in
    overlay)
      fuse-overlayfs \
        -o "lowerdir=$NIX_STORE_LOWER,upperdir=$NIX_UPPER,workdir=$NIX_WORK" \
        "$MERGED/nix/store"
      ;;
    passthrough) mount --bind "$NIX_STORE_LOWER" "$MERGED/nix/store" ;;
    ro)          mount --bind -o ro "$NIX_STORE_LOWER" "$MERGED/nix/store" ;;
    *) echo "bad NIX_STORE_MODE: $NIX_STORE_MODE" >&2; exit 2 ;;
  esac

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
    --cap-add=NET_ADMIN
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
    --ulimit nproc=65535
    --ulimit nofile=1024:524288
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
    "''${FLAGS[@]}" \
    /init >/dev/null
  INNER

    wait_for_systemd
  }

  # ensure_running: start_persistent if not already running.
  # Auto-up here never enables GPU - use `up --gpu` explicitly
  # if you need it.
  ensure_running() {
    if container_running; then return 0; fi
    if container_exists; then pm rm -f "$NAME" >/dev/null; fi
    ENABLE_GPU=0 start_persistent
  }

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

  tear_down() {
    if container_running; then pm stop -t 5 "$NAME" >/dev/null || true; fi
    if container_exists; then pm rm -f "$NAME" >/dev/null || true; fi
    stop_all_session_watchdogs
    # Container's mount-ns dying releases the overlays. Clean up
    # any per-session $WORK_SHARED binds and the rshared self-bind.
    _WS=$WORK_SHARED _MG=$MERGED _SM=$SOCKET_MOUNTS \
      podman unshare "${tools.bash}" -c '
      set +e
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
      mountpoint -q -- "$_WS" && umount -- "$_WS"
      fusermount3 -u -- "$_MG/nix/store" 2>/dev/null \
        || umount -- "$_MG/nix/store" 2>/dev/null
      umount -- "$_MG" 2>/dev/null
      exit 0
    ' || true
  }

  # ----- subcommand dispatch ------------------------------------

  cmd=''${1:-enter}
  if [ $# -gt 0 ]; then shift; fi

  case "$cmd" in
    up)
      ENABLE_GPU=0
      ENABLE_OPENGL=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --gpu)    ENABLE_GPU=1; shift ;;
          --opengl) ENABLE_OPENGL=1; shift ;;
          --) shift; break ;;
          -*) echo "up: unknown flag $1" >&2; exit 2 ;;
          *)  break ;;
        esac
      done
      export ENABLE_GPU ENABLE_OPENGL
      if container_running; then
        echo "$NAME: already running"; exit 0
      fi
      if container_exists; then pm rm -f "$NAME" >/dev/null; fi
      start_persistent
      tags=""
      [ "$ENABLE_GPU"    = "1" ] && tags="$tags gpu"
      [ "$ENABLE_OPENGL" = "1" ] && tags="$tags opengl"
      echo "$NAME: up''${tags:+ (''${tags# })}"
      ;;
    down|stop)
      tear_down
      echo "$NAME: down"
      ;;
    enter|shell)
      forward_agent=0
      x11_mode=""
      wayland=0
      sock_specs=()
      while [ $# -gt 0 ]; do
        case "$1" in
          -A|--forward-agent) forward_agent=1; shift ;;
          --x11)             x11_mode=trusted; shift ;;
          --x11-untrusted)   x11_mode=untrusted; shift ;;
          --wayland)         wayland=1; shift ;;
          -S|--socket)
            if [ -z "''${2:-}" ]; then
              echo "enter: -S requires name=path" >&2; exit 2
            fi
            sock_specs+=("$2"); shift 2 ;;
          --) shift; break ;;
          -*) echo "enter: unknown flag $1" >&2; exit 2 ;;
          *)  break ;;
        esac
      done

      ensure_running
      ns=dev
      # dev's uid/gid are fixed by configuration.nix (1000/100).
      dev_uid=1000
      dev_gid=100

      exec_env=()

      if [ "$forward_agent" -eq 1 ]; then
        if [ -z "''${SSH_AUTH_SOCK:-}" ] || [ ! -S "$SSH_AUTH_SOCK" ]; then
          echo "enter: -A given but SSH_AUTH_SOCK is unset/invalid" >&2
          exit 2
        fi
        bind_socket "$ns" "ssh-agent" "$SSH_AUTH_SOCK"
        spawn_socket_proxy "$ns" "ssh-agent" "$dev_uid" "$dev_gid"
        exec_env+=(--env "SSH_AUTH_SOCK=/run/sockets/$ns/ssh-agent")
      fi

      for spec in "''${sock_specs[@]+''${sock_specs[@]}}"; do
        parsed=$(parse_socket_spec "$spec") || exit 2
        sock_name=$(printf '%s' "$parsed" | sed -n '1p')
        sock_host=$(printf '%s' "$parsed" | sed -n '2p')
        bind_socket "$ns" "$sock_name" "$sock_host"
        spawn_socket_proxy "$ns" "$sock_name" "$dev_uid" "$dev_gid"
        echo "forward: $sock_host -> /run/sockets/$ns/$sock_name"
      done

      if [ -n "$x11_mode" ]; then
        x11_out=$(setup_x11 "$x11_mode" "$ns" "$dev_uid" "$dev_gid") || exit 2
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          exec_env+=(--env "$line")
        done <<<"$x11_out"
        echo "forward: X11 ($x11_mode)"
      fi

      if [ "$wayland" -eq 1 ]; then
        wl_out=$(setup_wayland "$ns" "$dev_uid" "$dev_gid") || exit 2
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          exec_env+=(--env "$line")
        done <<<"$wl_out"
        echo "forward: Wayland"
      fi

      pm exec -it -u "$SHELL_USER" \
        "''${exec_env[@]+''${exec_env[@]}}" \
        "$NAME" \
        ${tools.bash} -l
      ;;
    exec)
      if [ "''${1:-}" = "--" ]; then shift; fi
      ensure_running
      pm exec -it -u "$SHELL_USER" "$NAME" "$@"
      ;;
    develop)
      forward_agent=0
      x11_mode=""
      wayland=0
      sock_specs=()
      while [ $# -gt 0 ]; do
        case "$1" in
          -A|--forward-agent) forward_agent=1; shift ;;
          --x11)             x11_mode=trusted; shift ;;
          --x11-untrusted)   x11_mode=untrusted; shift ;;
          --wayland)         wayland=1; shift ;;
          -S|--socket)
            if [ -z "''${2:-}" ]; then
              echo "develop: -S requires name=path" >&2; exit 2
            fi
            sock_specs+=("$2"); shift 2 ;;
          --) shift; break ;;
          -*) echo "develop: unknown flag $1" >&2; exit 2 ;;
          *)  break ;;
        esac
      done
      if [ -z "''${1:-}" ]; then
        echo "usage: $(basename "$0") develop [-A] <host-path>" >&2
        exit 2
      fi
      if ! hostpath=$(realpath -- "$1" 2>/dev/null); then
        echo "develop: cannot resolve $1" >&2; exit 2
      fi
      if [ ! -d "$hostpath" ]; then
        echo "develop: not a directory: $hostpath" >&2; exit 2
      fi

      ensure_running

      # mount_id: sanitised basename + short hash. The sanitiser
      # strips anything outside [A-Za-z0-9._-] and forbids
      # leading `-` or `.`, so the id cannot smuggle shell
      # metacharacters or option prefixes into useradd, mount,
      # bindfs, or similar calls.
      base=$(basename -- "$hostpath" | sed 's/[^A-Za-z0-9._-]/_/g; s/^[-.]/_/')
      if [ -z "$base" ]; then base=project; fi
      hash=$(printf '%s' "$hostpath" | sha256sum | cut -c1-8)
      mount_id="''${base}-''${hash}"
      case "$mount_id" in -*) mount_id="_$mount_id" ;; esac

      bind_workdir "$hostpath" "$mount_id"

      # Session user (unique uid, NOT in wheel). Each develop
      # invocation allocates a fresh uid via useradd's auto
      # selection; reused across develop calls on the same path.
      # `--` terminates option parsing in useradd.
      # Session user (unique uid via auto-assignment, NOT in
      # wheel). useradd is idempotent via the existence check, so
      # running develop twice on the same hostpath reuses the
      # same user.
      session_user="dev-$mount_id"
      # shellcheck disable=SC2016
      pm exec -u root "$NAME" \
        /run/current-system/sw/bin/bash -lc '
          set -e
          if ! id -u "$1" >/dev/null 2>&1; then
            useradd \
              --no-create-home \
              --user-group \
              --home-dir "/develop-home/$1" \
              --shell /run/current-system/sw/bin/bash \
              -- "$1"
          fi
        ' bash "$session_user" >/dev/null

      uid=$(pm exec -u root "$NAME" /run/current-system/sw/bin/id -u -- "$session_user" | tr -d '[:space:]')
      gid=$(pm exec -u root "$NAME" /run/current-system/sw/bin/id -g -- "$session_user" | tr -d '[:space:]')

      # Per-session bindfs at /develop-home/<session_user>.
      # --perms="og=" strips group/other perms in the mounted
      # view so other session users in the same container can't
      # peek into this project even if they guess the username.
      # shellcheck disable=SC2016
      pm exec -u root "$NAME" \
        /run/current-system/sw/bin/bash -lc '
          set -e
          home_dir=/develop-home/$1
          src=/hostmnts/$2
          mkdir -p "$home_dir"
          if ! mountpoint -q "$home_dir"; then
            bindfs --map=0/$3:@0/@$4 --perms="og=" \
              -o allow_other "$src" "$home_dir"
          fi
        ' bash "$session_user" "$mount_id" "$uid" "$gid"

      home_dir="/develop-home/$session_user"
      extra_setenv=()

      scope="session-$mount_id.scope"

      if [ "$forward_agent" -eq 1 ]; then
        if [ -z "''${SSH_AUTH_SOCK:-}" ] || [ ! -S "$SSH_AUTH_SOCK" ]; then
          echo "develop: -A given but SSH_AUTH_SOCK is unset/invalid" >&2
          exit 2
        fi
        bind_socket "$mount_id" "ssh-agent" "$SSH_AUTH_SOCK"
        spawn_socket_proxy "$mount_id" "ssh-agent" \
          "$uid" "$gid" "$scope"
        extra_setenv+=(--setenv="SSH_AUTH_SOCK=/run/sockets/$mount_id/ssh-agent")
      fi

      # Generic -S socket forwarding. Each forwarded socket gets
      # a socat proxy in the container BoundTo this session's
      # scope, so it goes away when the scope dies.
      for spec in "''${sock_specs[@]+''${sock_specs[@]}}"; do
        parsed=$(parse_socket_spec "$spec") || exit 2
        sock_name=$(printf '%s' "$parsed" | sed -n '1p')
        sock_host=$(printf '%s' "$parsed" | sed -n '2p')
        bind_socket "$mount_id" "$sock_name" "$sock_host"
        spawn_socket_proxy "$mount_id" "$sock_name" \
          "$uid" "$gid" "$scope"
        echo "forward: $sock_host -> /run/sockets/$mount_id/$sock_name"
      done

      if [ -n "$x11_mode" ]; then
        x11_out=$(setup_x11 "$x11_mode" "$mount_id" "$uid" "$gid" "$scope") || exit 2
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          extra_setenv+=(--setenv="$line")
        done <<<"$x11_out"
        echo "forward: X11 ($x11_mode)"
      fi

      if [ "$wayland" -eq 1 ]; then
        wl_out=$(setup_wayland "$mount_id" "$uid" "$gid" "$scope") || exit 2
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          extra_setenv+=(--setenv="$line")
        done <<<"$wl_out"
        echo "forward: Wayland"
      fi

      # Spawn the per-session HOST watchdog (waits on a socket
      # uniquely named for this mount_id; tears down host-side
      # binds on receipt of any connection).
      start_session_watchdog "$mount_id"

      # Spawn the per-session IN-CONTAINER watchdog (blocks on
      # session-<id>.scope; when the LAST process in the scope
      # exits - including reparented daemons - it unmounts the
      # in-container bindfs mounts, userdels, and dials the
      # host watchdog so the host side gets dropped too). Both
      # watchdogs are one-shot per session and idempotent.
      scope="session-$mount_id.scope"
      watchdog_unit="watchdog-$mount_id.service"
      if ! pm exec -u root "$NAME" \
          /run/current-system/sw/bin/systemctl is-active --quiet \
          "$watchdog_unit" 2>/dev/null; then
        pm exec -u root "$NAME" \
          /run/current-system/sw/bin/systemd-run \
            --unit="$watchdog_unit" \
            --collect --quiet \
            /etc/nix-dev-container/inner-watchdog.sh \
            "$mount_id" "$session_user" >/dev/null
      fi

      # Wrap the user's shell in a transient .scope unit.
      # --collect: the scope unit is auto-removed when it goes
      #            inactive (after last member exits).
      # --scope:   the spawned process is placed in a new scope,
      #            and any descendants stay in it (so daemons
      #            keep the scope alive after the foreground
      #            shell exits, until they too exit).
      # --uid/--gid + --setenv=HOME=...: shell runs as session
      #            user with the project as HOME.
      echo "develop: $hostpath -> $home_dir (scope: $scope)"
      pm exec -it -u root "$NAME" \
        /run/current-system/sw/bin/systemd-run \
          --scope --collect --quiet \
          --unit="$scope" \
          --uid="$uid" --gid="$gid" \
          --working-directory="$home_dir" \
          --setenv="HOME=$home_dir" \
          "''${extra_setenv[@]+''${extra_setenv[@]}}" \
          ${tools.bash} -lc "nix develop"
      ;;
    boot)
      # ephemeral foreground systemd boot, for debugging the
      # boot sequence. Wipes any persistent container first.
      ENABLE_GPU=0
      ENABLE_OPENGL=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --gpu)    ENABLE_GPU=1; shift ;;
          --opengl) ENABLE_OPENGL=1; shift ;;
          --) shift; break ;;
          -*) echo "boot: unknown flag $1" >&2; exit 2 ;;
          *)  break ;;
        esac
      done
      if container_exists; then pm rm -f "$NAME" >/dev/null; fi
      ensure_state
      mount_rootfs_lower
      mkdir -p "$HOST_WATCHDOG_DIR"
      export ENABLE_OPENGL
      GPU_FLAGS_STR=$(accelerator_flags "$ENABLE_GPU" "$ENABLE_OPENGL")
      export GPU_FLAGS_STR
      migrate_to_keepid
      export USE_KEEP_ID KEEPID_UID KEEPID_GID
      export ROOTFS UPPER WORK MERGED NIX_UPPER NIX_WORK NIX_STORE_LOWER
      export PODMAN_ROOT PODMAN_RUNROOT NAME WORK_SHARED NIX_STORE_MODE
      export HOST_WATCHDOG_DIR
      podman unshare "${tools.bash}" <<'INNER'
  set -euo pipefail
  umount "$MERGED" 2>/dev/null || true
  mount -t overlay overlay \
    -o "lowerdir=$ROOTFS,upperdir=$UPPER,workdir=$WORK,userxattr" \
    "$MERGED"
  fuse-overlayfs \
    -o "lowerdir=$NIX_STORE_LOWER,upperdir=$NIX_UPPER,workdir=$NIX_WORK" \
    "$MERGED/nix/store"
  if ! mountpoint -q "$WORK_SHARED"; then
    mount --bind "$WORK_SHARED" "$WORK_SHARED"
  fi
  mount --make-rshared "$WORK_SHARED"
  GPU=()
  if [ -n "''${GPU_FLAGS_STR:-}" ]; then
    # shellcheck disable=SC2206
    GPU=($GPU_FLAGS_STR)
  fi
  USERNS=()
  if [ "''${USE_KEEP_ID:-0}" = "1" ]; then
    USERNS=(
      --userns=keep-id:uid="$KEEPID_UID",gid="$KEEPID_GID"
      --user=0:0
    )
  fi
  trap 'fusermount3 -u "$MERGED/nix/store" 2>/dev/null; umount "$MERGED" 2>/dev/null' EXIT
  exec podman --root "$PODMAN_ROOT" --runroot "$PODMAN_RUNROOT" \
    ${ociRuntimeFlag} run --rm -it \
    "''${USERNS[@]+''${USERNS[@]}}" \
    --name "$NAME" \
    --systemd=always \
    --cgroupns=host \
    --cap-add=SYS_ADMIN \
    --cap-add=NET_RAW \
    --cap-add=NET_ADMIN \
    --device=/dev/fuse \
    --security-opt unmask=/sys/fs/cgroup \
    --security-opt systempaths=unconfined \
    --security-opt label=disable \
    --hostname "$NAME" \
    -v "$WORK_SHARED:/hostmnts:rshared" \
    -v "$SOCKET_MOUNTS:/var/socket-mounts:rshared" \
    -v "$HOST_WATCHDOG_DIR:/var/host-watchdog" \
    "''${GPU[@]+''${GPU[@]}}" \
    --rootfs "$MERGED" \
    /init
  INNER
      ;;
    purge)
      tear_down
      podman unshare ${tools.bash} -c "
        rm -rf -- '$STATE_DIR'
      " || rm -rf -- "$STATE_DIR"
      ;;
    status)
      if container_running; then
        echo "$NAME: running"
      elif container_exists; then
        echo "$NAME: stopped (mount-ns gone)"
      else
        echo "$NAME: not created"
      fi
      echo "shell user: $SHELL_USER"
      echo "rootfs:     $ROOTFS"
      echo "state dir:  $STATE_DIR"
      if [ -d "$WORK_SHARED" ]; then
        echo "develop binds:"
        podman unshare ${tools.bash} -c "
          for d in '$WORK_SHARED'/*; do
            [ -d \"\$d\" ] && mountpoint -q \"\$d\" && \
              echo '  /work/'\$(basename \"\$d\")
          done
        " 2>/dev/null || true
      fi
      if [ -d "$STATE_DIR" ]; then
        du -sh "$UPPER" "$NIX_UPPER" 2>/dev/null || true
      fi
      ;;
    logs)
      pm logs -f "$NAME"
      ;;
    check-host-compat)
      # Probe whether this host is ready to run the container. Useful
      # before `up` on a fresh / unfamiliar machine. The probe script
      # itself is self-contained — no container is touched.
      exec ${checkHostCompatPath} "$@"
      ;;
    *)
      cat >&2 <<EOF
  usage: $(basename "$0") {up|down|enter|develop|exec|boot|status|logs|purge} [args]

  subcommands:
    up [--gpu] [--opengl]       start the persistent container (idempotent).
                                --gpu     nvidia/CUDA passthrough (CDI via
                                          host's nvidia-container-toolkit if
                                          mkContainer was set with
                                          hostHasNvidiaContainerToolkit = true,
                                          else manual /dev/nvidia* + host
                                          lib bind).
                                --opengl  OpenGL / DRI passthrough (works for
                                          Intel/AMD/Mesa and nvidia-GL alike):
                                          binds /dev/dri/* and the host's
                                          libGL.so* directory.
                                Both must be set at up time; auto-up from
                                enter/develop never enables either.
    down/stop                   stop + remove container; state in $STATE_DIR persists.
    enter [-A] [-S name=path]   open a login shell as $SHELL_USER;
                                auto-runs up if not running.
      shell                     alias for enter.
    develop [-A] [-S name=path] <hostpath>
                                bind-mount <hostpath> at /develop-home/<user>
                                in the running container, exec nix develop
                                there as a per-session user. Re-running on
                                the same hostpath reuses the user.
    exec -- CMD...              run CMD inside the container as $SHELL_USER.
    boot                        ephemeral foreground systemd (debugging);
                                wipes any existing persistent container first.
    status                      show container state and disk usage.
    logs                        tail container logs.
    purge                       down + wipe \$STATE_DIR.
    check-host-compat           probe host for required binaries,
                                kernel features, fuse, rootless setup.

  forwarding flags (enter and develop):
    -A, --forward-agent         forward the host \$SSH_AUTH_SOCK.
                                Sets SSH_AUTH_SOCK in the session env.
    --x11                       trusted X11 forwarding (ssh -Y style):
                                forwards the socket for \$DISPLAY and
                                injects the host's cookie. Sets DISPLAY
                                and XCOOKIE; the container's shell-init
                                registers the cookie under DISPLAY.
    --x11-untrusted             untrusted X11 forwarding (ssh -X style):
                                generates a fresh SECURITY-extension
                                cookie on the host (requires the host
                                X server to support SECURITY).
    --wayland                   forward \$WAYLAND_DISPLAY (\$XDG_RUNTIME_DIR/
                                wayland-0 by default). Sets WAYLAND_DISPLAY
                                to the in-container proxied path.
    -S, --socket name=hostpath  generic socket forward. Container side
                                path is /run/sockets/<ns>/<name>; no
                                env is auto-set (do it in your shell).

  env:
    NAME             container name              (default $DEFAULT_NAME)
    STATE_DIR        host state directory        (default \$XDG_STATE_HOME/nix-dev-container/\$NAME)
    NIX_STORE_MODE   overlay|passthrough|ro      (default overlay)
                       overlay     - host store stays untouched
                       passthrough - container writes land in host store
                       ro          - no installs from inside
  EOF
      exit 2
      ;;
  esac
''
