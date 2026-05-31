# Main nix-dev-container dispatcher, factored out of flake.nix so the
# same text can drive (a) the NixOS-host writeShellApplication build and
# (b) the portable-tarball build.
#
# Tool resolution comes through the `tools` attrset (see
# nix/scripts/tools.nix): every reference to a named binary like bash,
# crun, podman, socat is `${tools.X}` so the value is baked at Nix
# eval time — full /nix/store path on NixOS, bare command name on
# portable. Bare unqualified commands (mkdir, mount, find, ...) keep
# their PATH-resolution behavior because they're either supplied via
# writeShellApplication's runtimeInputs (NixOS) or by the host's
# /usr/bin (portable, with a sane PATH set at script entry).
#
# The script body is assembled from cohesive bash fragments under
# nix/scripts/lib/ (store, gpu, forwarding, watchdog) plus the container
# lifecycle + dispatch kept here. Splitting keeps each concern editable
# in isolation; everything is still emitted as one self-contained script.

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
  # ----- /nix provisioning policy (ORTHOGONAL build-time axes) ---
  # storage       : rootfs-base storage profile. One of:
  #                   ephemeral  - overlay upper/work on tmpfs (gone on stop)
  #                   overlay    - overlay upper/work on disk (persists)
  #                   directory  - no overlay; $MERGED is a materialized
  #                                writable real copy of $ROOTFS.
  #                 Overridable at runtime via the STORAGE env.
  # hostNixStore  : serve the HOST /nix/store into the container via the
  #                 nix-store-shared-fuse symlink farm (RO lower) with a
  #                 writable fuse-overlayfs upper. Overridable via the
  #                 HOST_NIX_STORE env. Ignored when hostNixDaemon.
  # hostNixDaemon : delegate to the HOST nix-daemon: rbind the whole host
  #                 /nix read-only (store + db + socket). COUPLED to the
  #                 NixOS host-daemon module profile baked at build time
  #                 (no in-container daemon / nixbld users), so it CANNOT
  #                 be toggled on/off at runtime.
  # fusePath      : absolute path to the nix-store-shared-fuse binary;
  #                 set when hostNixStore && !hostNixDaemon.
  # redirectRoot  : physical store root the FUSE reads content from
  #                 (default /nix/store; a relocated store overrides it).
  # nixStoreLower : store path of the symlink FARM = the FUSE
  #                 --bind-target AND the host-side GC-root target; set
  #                 when hostNixStore && !hostNixDaemon.
, storage ? "overlay"
, hostNixStore ? false
, hostNixDaemon ? false
, fusePath ? null
, redirectRoot ? "/nix/store"
, nixStoreLower ? null
  # idleTimeout : integer seconds of no active develop session after
  #               which the container is torn down by a host-side idle
  #               monitor. 0 (default) disables the monitor entirely;
  #               a no-op for existing containers. Overridable at
  #               runtime via the NIXCT_IDLE_TIMEOUT env.
, idleTimeout ? 0
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

let
  # Cohesive bash fragments. See the header of each file for its contract.
  storeLib      = import ./lib/store.nix { };
  gpuFns        = import ./lib/gpu.nix { };
  watchdogFns   = import ./lib/watchdog.nix { inherit hostWatchdogPath; };
  forwardingFns = import ./lib/forwarding.nix { inherit tools; };
in

''
  # ----------------------------------------------------------------
  # Design (rootless, persistent):
  #
  #   - All mount setup happens inside `podman unshare bash`,
  #     which enters the rootless user-namespace where we have
  #     CAP_SYS_ADMIN.
  #
  #   - Rootfs base at $MERGED (see nix/scripts/lib/store.nix):
  #       ephemeral/overlay = kernel overlayfs lower=$ROOTFS over a
  #                           writable upper/work (tmpfs vs on-disk).
  #       directory         = no overlay; $MERGED is a materialized
  #                           writable real copy of $ROOTFS.
  #   - /nix provisioning on top of the base (orthogonal axes):
  #       HOST_NIX_DAEMON=1 = rbind whole host /nix ro (store+db+socket)
  #       HOST_NIX_STORE=1  = nix-store-shared-fuse over the symlink farm
  #                           (RO) + writable fuse-overlayfs upper
  #                           (RO bind in directory mode)
  #       neither           = self-contained store baked in $ROOTFS,
  #                           served via fuse-overlayfs (own mount)
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

  # ----- /nix provisioning axes (build-time defaults; env overrides) ----
  # STORAGE and HOST_NIX_STORE are runtime-overridable. HOST_NIX_DAEMON
  # is coupled to NixOS-module config baked at build time (no in-container
  # daemon / nixbld users, store = daemon), so it CANNOT be toggled at
  # runtime - only the build-time default is honored.
  STORAGE=''${STORAGE:-${storage}}
  BUILT_HOST_NIX_STORE=${if hostNixStore then "1" else "0"}
  HOST_NIX_STORE=''${HOST_NIX_STORE:-$BUILT_HOST_NIX_STORE}
  BUILT_HOST_NIX_DAEMON=${if hostNixDaemon then "1" else "0"}
  HOST_NIX_DAEMON=''${HOST_NIX_DAEMON:-$BUILT_HOST_NIX_DAEMON}
  # FUSE binary + farm path + physical redirect root for HOST_NIX_STORE.
  FUSE_BIN=''${FUSE_BIN:-${if fusePath == null then "" else fusePath}}
  REDIRECT_ROOT=''${REDIRECT_ROOT:-${redirectRoot}}
  # NIX_STORE_LOWER: the symlink-FARM store path (= FUSE --bind-target and
  # the host-side GC-root target). Empty unless hostNixStore. NOTE: this
  # is the symlink farm, NOT the old "host /nix/store source".
  NIX_STORE_LOWER=''${NIX_STORE_LOWER:-${if nixStoreLower == null then "" else nixStoreLower}}

  case "$STORAGE" in
    ephemeral|overlay|directory) ;;
    *) echo "error: bad STORAGE=$STORAGE (want ephemeral|overlay|directory)" >&2; exit 2 ;;
  esac
  # HOST_NIX_DAEMON is build-coupled: refuse a runtime toggle either way.
  if [ "$BUILT_HOST_NIX_DAEMON" != "$HOST_NIX_DAEMON" ]; then
    echo "error: HOST_NIX_DAEMON is fixed at build time (built: $BUILT_HOST_NIX_DAEMON); the NixOS host-daemon profile cannot be toggled at runtime" >&2
    exit 2
  fi
  # In daemon mode the host store axis is meaningless; force it off.
  if [ "$HOST_NIX_DAEMON" = "1" ]; then
    HOST_NIX_STORE=0
  fi
  # host-store needs both the FUSE binary and the symlink-farm path.
  if [ "$HOST_NIX_STORE" = "1" ]; then
    if [ -z "$FUSE_BIN" ] || [ -z "$NIX_STORE_LOWER" ]; then
      echo "error: HOST_NIX_STORE=1 requires FUSE_BIN and NIX_STORE_LOWER to be set" >&2
      exit 2
    fi
  fi

  # Idle-timeout default (seconds; 0 = disabled). Overridable via env.
  BUILT_IDLE_TIMEOUT=${toString idleTimeout}
  IDLE_TIMEOUT=''${NIXCT_IDLE_TIMEOUT:-$BUILT_IDLE_TIMEOUT}
  # Sanitize: a non-integer (e.g. a bad NIXCT_IDLE_TIMEOUT) disables it
  # cleanly instead of tripping `[ -gt ]` integer errors later.
  case "$IDLE_TIMEOUT" in ""|*[!0-9]*) IDLE_TIMEOUT=0 ;; esac

  UPPER="$STATE_DIR/upper"
  WORK="$STATE_DIR/work"
  MERGED="$STATE_DIR/merged"
  NIX_UPPER="$STATE_DIR/nix-store-upper"
  NIX_WORK="$STATE_DIR/nix-store-work"
  PODMAN_ROOT="$STATE_DIR/podman-root"
  PODMAN_RUNROOT="$STATE_DIR/podman-runroot"
  # host-store only: indirect GC root pinning the symlink-farm closure
  # ($NIX_STORE_LOWER) for the container's lifetime, so the host daemon
  # can't collect the store paths the FUSE serves. Planted at up,
  # removed at down/purge.
  NIX_STORE_LOWER_GCROOT="$STATE_DIR/nix-store-lower.gcroot"

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
  # HOST_NIX_DAEMON only: per-session GC-root directory. Bound into the
  # container at the IDENTICAL absolute path so a store-pointing
  # symlink created here resolves the same in both namespaces; the
  # host nix-daemon then protects those paths from
  # nix-collect-garbage for the session lifetime. Each develop
  # session gets a 0700 root-owned subdir $SESSION_GCROOTS/<mount_id>.
  SESSION_GCROOTS="$STATE_DIR/session-gcroots"

  # plant_store_gcroot / drop_store_gcroot: host-side GC-root lifecycle
  # for HOST_NIX_STORE mode. The symlink farm ($NIX_STORE_LOWER) and its
  # closure live in the HOST store; an indirect root keeps the host
  # daemon from collecting them while the container exists. No-op unless
  # HOST_NIX_STORE=1 (self-contained / daemon modes don't need it).
  plant_store_gcroot() {
    [ "$HOST_NIX_STORE" = "1" ] || return 0
    [ -n "$NIX_STORE_LOWER" ] || return 0
    nix-store --realise --add-root "$NIX_STORE_LOWER_GCROOT" \
      "$NIX_STORE_LOWER" >/dev/null 2>&1 || true
  }
  drop_store_gcroot() {
    rm -f -- "$NIX_STORE_LOWER_GCROOT" 2>/dev/null || true
  }
  # store_summary: one-word description of the /nix provisioning for
  # status / up output, derived from the resolved axes.
  store_summary() {
    if [ "$HOST_NIX_DAEMON" = "1" ]; then
      echo "host-daemon"
    elif [ "$HOST_NIX_STORE" = "1" ]; then
      echo "host-store"
    else
      echo "self-contained"
    fi
  }

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

    # HOST_NIX_DAEMON: per-session GC-root parent dir (host side, owned
    # by the calling user = container root under default rootless).
    if [ "$HOST_NIX_DAEMON" = "1" ]; then
      mkdir -p "$SESSION_GCROOTS"
      chmod 0700 -- "$SESSION_GCROOTS"
    fi

    # NIX_UPPER / NIX_WORK back the /nix/store overlay, needed for every
    # combo EXCEPT directory mode (no overlays) and HOST_NIX_DAEMON (whole
    # /nix rbind). Created here; harmless to skip when unused.
    _STORE_OVERLAY=0
    if [ "$STORAGE" != "directory" ] && [ "$HOST_NIX_DAEMON" != "1" ]; then
      _STORE_OVERLAY=1
    fi

    if [ "$STORAGE" = "directory" ]; then
      # No rootfs overlay: materialize $ROOTFS into a writable real copy
      # at $MERGED. Idempotent - skip if already populated (a non-empty
      # $MERGED means a prior run already copied it). cp -a preserves the
      # tree; chmod -R u+w makes the store-derived 0444/0555 files
      # writable so in-container activation can rewrite them. Run inside
      # podman unshare for CAP_DAC_OVERRIDE on subuid-owned files.
      _ROOTFS=$ROOTFS _MERGED=$MERGED \
        podman unshare ${tools.bash} -c '
        set -euo pipefail
        if [ -z "$(ls -A "$_MERGED" 2>/dev/null)" ]; then
          cp -a "$_ROOTFS"/. "$_MERGED"/
          chmod -R u+w "$_MERGED"
        fi
      '
    fi

    # UPPER and NIX_UPPER may already be migrated to host's
    # first subuid (when useKeepId is on), so the calling user
    # can neither traverse them nor chmod them directly. Run
    # the layout/perms setup inside `podman unshare`, which
    # has CAP_FOWNER + CAP_DAC_OVERRIDE for files owned by
    # uids mapped in the rootless user-ns - covers both the
    # pre-migration (sirati-owned) and post-migration (subuid-
    # owned) cases. The UPPER skeleton only backs the rootfs
    # overlay (ephemeral/overlay); directory mode has none.
    _UPPER=$UPPER _NIX_UPPER=$NIX_UPPER _NIX_WORK=$NIX_WORK \
    _STORAGE=$STORAGE _STORE_OVERLAY=$_STORE_OVERLAY \
      podman unshare ${tools.bash} -c '
      set -euo pipefail
      if [ "$_STORE_OVERLAY" = "1" ]; then
        mkdir -p "$_NIX_UPPER" "$_NIX_WORK"
      fi
      [ "$_STORAGE" = "directory" ] && exit 0
      mkdir -p "$_UPPER"
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

  # ----- GPU / OpenGL passthrough -------------------------------
  ${gpuFns}

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
  ${watchdogFns}

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

  # ----- socket / X11 / Wayland forwarding ----------------------
  ${forwardingFns}

  tear_down() {
    if container_running; then pm stop -t 5 "$NAME" >/dev/null || true; fi
    if container_exists; then pm rm -f "$NAME" >/dev/null || true; fi
    stop_all_session_watchdogs
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
      mountpoint -q -- "$_WS" && umount -- "$_WS"
      ${storeLib.unmount}
      exit 0
    ' || true
    # Release the host-store GC root so the closure can be collected
    # again (no-op unless HOST_NIX_STORE planted one).
    drop_store_gcroot
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
      echo "$NAME: up''${tags:+ (''${tags# })} [storage: $STORAGE, nix: $(store_summary)]"
      maybe_start_idle_monitor
      ;;
    down|stop)
      tear_down
      echo "$NAME: down"
      ;;
    __idle-monitor)
      # Hidden: host-side loop that tears the container down after
      # IDLE_TIMEOUT seconds with no active develop session. Spawned
      # detached by maybe_start_idle_monitor. A flock on a per-state
      # lock file makes this single-instance: if another monitor holds
      # it we just exit.
      exec 9>"$STATE_DIR/.idle-monitor.lock" || exit 0
      flock -n 9 || exit 0
      [ "''${IDLE_TIMEOUT:-0}" -gt 0 ] || exit 0
      # Poll often enough to be responsive but never busy-loop: clamp
      # to [3, 30] and never above the timeout itself.
      interval=$IDLE_TIMEOUT
      [ "$interval" -gt 30 ] && interval=30
      [ "$interval" -lt 3 ] && interval=3
      last=$(date +%s)
      while container_running; do
        # An active develop session shows up as a running
        # session-*.scope unit (created only by `develop`). grep -c
        # exits 1 on zero matches, so `|| true` is required here.
        active=$(pm exec "$NAME" \
          /run/current-system/sw/bin/systemctl list-units \
            --type=scope --state=active --no-legend 'session-*.scope' \
          2>/dev/null | grep -c '\.scope' || true)
        now=$(date +%s)
        # Activity = a live session scope OR a recent mark_activity touch
        # (the latter covers develop's setup window, before the scope
        # exists, so a stale monitor can't tear down a starting session).
        amt=$(stat -c %Y "$STATE_DIR/.idle-activity" 2>/dev/null || echo 0)
        if [ "''${active:-0}" -gt 0 ]; then
          last=$now
        else
          [ "''${amt:-0}" -gt "$last" ] && last=$amt
          if [ $((now - last)) -ge "$IDLE_TIMEOUT" ]; then
            tear_down
            break
          fi
        fi
        sleep "$interval"
      done
      exit 0
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
      mount_bashrc=0
      mount_gitconfig=0
      sock_specs=()
      while [ $# -gt 0 ]; do
        case "$1" in
          -A|--forward-agent) forward_agent=1; shift ;;
          --x11)             x11_mode=trusted; shift ;;
          --x11-untrusted)   x11_mode=untrusted; shift ;;
          --wayland)         wayland=1; shift ;;
          --mount-bashrc)    mount_bashrc=1; shift ;;
          --mount-gitconfig) mount_gitconfig=1; shift ;;
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

      # Per-session HOME at /develop-home/<session_user>, with the
      # project bind-mounted ONE LEVEL DOWN at <home>/dev. Keeping the
      # home and the project separate lets us drop home-level files
      # (.bashrc, .nixct, nix profile state) into the session HOME
      # without polluting the user's project tree.
      #   <home>      - real writable dir owned by the session user, 0700.
      #   <home>/dev  - bindfs view of /hostmnts/<id>. --perms="og="
      #                 strips group/other perms so other session users
      #                 can't peek in even if they guess the username.
      # shellcheck disable=SC2016
      pm exec -u root "$NAME" \
        /run/current-system/sw/bin/bash -lc '
          set -e
          home_dir=/develop-home/$1
          proj_dir=$home_dir/dev
          src=/hostmnts/$2
          mkdir -p "$proj_dir"
          chown "$3:$4" "$home_dir"
          chmod 0700 "$home_dir"
          # Framework-managed ~/.bashrc (enables direnv; sources a
          # mounted-in user bashrc if present). Reinstalled every run so
          # it stays current; user customisation goes in ~/.bashrc.user.
          cp /etc/nix-dev-container/bashrc "$home_dir/.bashrc"
          chown "$3:$4" "$home_dir/.bashrc"
          chmod 0644 "$home_dir/.bashrc"
          if ! mountpoint -q "$proj_dir"; then
            bindfs --map=0/$3:@0/@$4 --perms="og=" \
              -o allow_other "$src" "$proj_dir"
          fi
        ' bash "$session_user" "$mount_id" "$uid" "$gid"

      # Opt-in: copy the invoking host user's dotfiles read-only into
      # the session HOME. Each is piped in as container root, chowned
      # to the session user and locked to 0444. The framework ~/.bashrc
      # already sources ~/.bashrc.user. Missing host sources are
      # skipped silently. Use -i (stdin piped), not -it.
      if [ "$mount_bashrc" -eq 1 ] && [ -f "$HOME/.bashrc" ]; then
        # shellcheck disable=SC2016
        pm exec -i -u root "$NAME" /run/current-system/sw/bin/bash -lc '
          set -e; dest="/develop-home/$1/$2"; cat > "$dest"; chown "$3:$4" "$dest"; chmod 0444 "$dest"
        ' bash "$session_user" ".bashrc.user" "$uid" "$gid" < "$HOME/.bashrc"
      fi
      if [ "$mount_gitconfig" -eq 1 ] && [ -f "$HOME/.gitconfig" ]; then
        # shellcheck disable=SC2016
        pm exec -i -u root "$NAME" /run/current-system/sw/bin/bash -lc '
          set -e; dest="/develop-home/$1/$2"; cat > "$dest"; chown "$3:$4" "$dest"; chmod 0444 "$dest"
        ' bash "$session_user" ".gitconfig" "$uid" "$gid" < "$HOME/.gitconfig"
      fi

      home_dir="/develop-home/$session_user"
      proj_dir="$home_dir/dev"
      extra_setenv=()

      # Dev-shell command. In host-daemon mode, build the dev shell
      # through a discoverable profile under the session HOME so the
      # gcroot-keeper can register the resulting store paths as GC
      # roots (protecting them from host nix-collect-garbage for the
      # session lifetime). The --profile build runs as the SESSION
      # user (enforced by systemd-run --uid/--gid below), preserving
      # trust separation. Other modes keep plain `nix develop`.
      develop_cmd='nix develop'
      if [ "$HOST_NIX_DAEMON" = "1" ]; then
        # $HOME expands inside the inner `bash -lc` as the session
        # user, not here - keep it single-quoted.
        # shellcheck disable=SC2016
        develop_cmd='mkdir -p "$HOME/.nixct" && nix develop --profile "$HOME/.nixct/devshell"'
      fi

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

      # HOST_NIX_DAEMON: create the per-session GC-root subdir (as
      # container root, mode 0700 - outside /develop-home so the
      # session user can't reach it) and spawn the gcroot-keeper.
      # The keeper watches the session HOME, registers store-pointing
      # symlinks here, and (because this dir is bound at an identical
      # path host-side) the host nix-daemon protects those paths from
      # nix-collect-garbage for the session lifetime.
      if [ "$HOST_NIX_DAEMON" = "1" ]; then
        pm exec -u root "$NAME" \
          /run/current-system/sw/bin/mkdir -p "$SESSION_GCROOTS/$mount_id"
        pm exec -u root "$NAME" \
          /run/current-system/sw/bin/chmod 0700 "$SESSION_GCROOTS/$mount_id"
        keeper_unit="gcroot-keeper-$mount_id.service"
        if ! pm exec -u root "$NAME" \
            /run/current-system/sw/bin/systemctl is-active --quiet \
            "$keeper_unit" 2>/dev/null; then
          pm exec -u root "$NAME" \
            /run/current-system/sw/bin/systemd-run \
              --unit="$keeper_unit" --collect --quiet \
              /etc/nix-dev-container/gcroot-keeper.sh \
              "$mount_id" "$session_user" "$SESSION_GCROOTS/$mount_id" >/dev/null
        fi
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
      # Final activity bump right before the scope exists, so a tight
      # idle timeout can't fire during the last moments of setup.
      mark_activity
      echo "develop: $hostpath -> $proj_dir (HOME: $home_dir, scope: $scope)"
      pm exec -it -u root "$NAME" \
        /run/current-system/sw/bin/systemd-run \
          --scope --collect --quiet \
          --unit="$scope" \
          --uid="$uid" --gid="$gid" \
          --working-directory="$proj_dir" \
          --setenv="HOME=$home_dir" \
          "''${extra_setenv[@]+''${extra_setenv[@]}}" \
          ${tools.bash} -lc "$develop_cmd"
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
      plant_store_gcroot
      export ENABLE_OPENGL
      GPU_FLAGS_STR=$(accelerator_flags "$ENABLE_GPU" "$ENABLE_OPENGL")
      export GPU_FLAGS_STR
      migrate_to_keepid
      export USE_KEEP_ID KEEPID_UID KEEPID_GID
      export ROOTFS UPPER WORK MERGED NIX_UPPER NIX_WORK STATE_DIR
      export STORAGE HOST_NIX_STORE HOST_NIX_DAEMON
      export FUSE_BIN REDIRECT_ROOT NIX_STORE_LOWER
      export PODMAN_ROOT PODMAN_RUNROOT NAME WORK_SHARED SOCKET_MOUNTS
      export HOST_WATCHDOG_DIR
      podman unshare "${tools.bash}" <<'INNER'
  set -euo pipefail

  # Mount the rootfs base + provision /nix (per the storage/host-nix axes).
  ${storeLib.mountAll}

  # WORK_SHARED + SOCKET_MOUNTS rshared so develop binds propagate.
  if ! mountpoint -q "$WORK_SHARED"; then
    mount --bind "$WORK_SHARED" "$WORK_SHARED"
  fi
  mount --make-rshared "$WORK_SHARED"
  if ! mountpoint -q "$SOCKET_MOUNTS"; then
    mount --bind "$SOCKET_MOUNTS" "$SOCKET_MOUNTS"
  fi
  mount --make-rshared "$SOCKET_MOUNTS"
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
  trap '${storeLib.unmount}' EXIT
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
      echo "storage:    $STORAGE"
      echo "nix store:  $(store_summary)"
      if [ "$HOST_NIX_DAEMON" = "1" ]; then
        echo "  host /nix mounted ro (store + db + daemon socket)"
        if [ -d "$SESSION_GCROOTS" ]; then
          echo "session gcroots:"
          for d in "$SESSION_GCROOTS"/*; do
            [ -d "$d" ] || continue
            # `|| n=0` keeps errexit from aborting status if the count
            # pipeline ever fails (e.g. a torn-down session mid-listing).
            n=$(find "$d" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d '[:space:]') || n=0
            echo "  $(basename "$d") ($n roots)"
          done
        fi
      elif [ "$HOST_NIX_STORE" = "1" ]; then
        echo "  farm:       $NIX_STORE_LOWER"
        echo "  redirect:   $REDIRECT_ROOT"
        echo "  fuse bin:   $FUSE_BIN"
        if [ -e "$NIX_STORE_LOWER_GCROOT" ]; then
          echo "  gc root:    planted ($NIX_STORE_LOWER_GCROOT)"
        else
          echo "  gc root:    absent"
        fi
      fi
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
                                bind-mount <hostpath> at /develop-home/<user>/dev
                                (~/dev) in the running container, exec nix
                                develop there as a per-session user. The
                                session HOME (/develop-home/<user>) is a
                                separate writable dir for home-level files.
                                Re-running on the same hostpath reuses the user.
                                When HOST_NIX_DAEMON the session auto-manages
                                GC roots: host store paths used by the
                                session are protected from
                                nix-collect-garbage for the session
                                lifetime, and a .nixct/ dir is created in
                                the project home for the dev-shell profile.
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

  develop-only flags:
    --mount-bashrc              copy the host \$HOME/.bashrc into the
                                session HOME as ~/.bashrc.user (0444),
                                sourced by the framework ~/.bashrc.
    --mount-gitconfig           copy the host \$HOME/.gitconfig into the
                                session HOME (0444). Both skip silently
                                if the host file is absent.

  env:
    NAME             container name              (default $DEFAULT_NAME)
    STATE_DIR        host state directory        (default \$XDG_STATE_HOME/nix-dev-container/\$NAME)
    The /nix provisioning is driven by three ORTHOGONAL axes. STORAGE and
    HOST_NIX_STORE are runtime-overridable; HOST_NIX_DAEMON is fixed at
    build time (coupled to the NixOS host-daemon profile).
    STORAGE          ephemeral|overlay|directory (build default: $STORAGE)
                       ephemeral - rootfs overlay upper/work on tmpfs
                                   (wiped on stop)
                       overlay   - rootfs overlay upper/work on disk
                                   (persists across stop/start)
                       directory - no overlay; \$MERGED is a materialized
                                   writable real copy of the rootfs
    HOST_NIX_STORE   0|1 (build default: $BUILT_HOST_NIX_STORE). When 1, the
                       host store is served through the nix-store-shared-fuse
                       symlink farm (RO) with a writable fuse-overlayfs upper
                       (RO bind in directory mode). Requires FUSE_BIN +
                       NIX_STORE_LOWER. Ignored when HOST_NIX_DAEMON=1.
    HOST_NIX_DAEMON  0|1 (build default: $BUILT_HOST_NIX_DAEMON, FIXED). When 1,
                       the whole host /nix is rbind-mounted read-only (store +
                       db + daemon socket) and builds delegate to the host
                       daemon. Coupled to the NixOS host-daemon module profile
                       (no in-container daemon / nixbld users); cannot be
                       toggled at runtime.
    FUSE_BIN         absolute path to nix-store-shared-fuse (HOST_NIX_STORE).
    REDIRECT_ROOT    physical store root the FUSE reads from (default $REDIRECT_ROOT).
    NIX_STORE_LOWER  symlink-farm store path = FUSE bind_target and GC-root
                       target (HOST_NIX_STORE; empty otherwise).
    NIXCT_IDLE_TIMEOUT idle-stop timeout in seconds (build default: $BUILT_IDLE_TIMEOUT,
                       0 = disabled). When > 0 the container auto-stops
                       after that many seconds with no active develop session.
  EOF
      exit 2
      ;;
  esac
''
