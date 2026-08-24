# Environment and the provisioning axes: every shell variable the rest of the
# script reads, given its default here.
#
# This is where a Nix value becomes a shell variable. A value fixed at
# evaluation time is interpolated straight in; a value that genuinely varies
# at runtime gets its default here and is overridable by the environment. The
# distinction matters: a shell variable that could have been a Nix value is a
# check the type system was not allowed to make.
#
# Split out of run.nix. The body is emitted verbatim in the same position, so
# the generated script is unchanged -- verified by hashing it before and after.

{ name
, shellUser
, storage
, redirectRoot
, rootfsLine
, stateDirLine
, fusePath
, hostHasNvidiaContainerToolkit
, hostNixDaemon
, hostNixStore
, idleTimeout
, keepIdGid
, keepIdUid
, nixStoreLower
, useKeepId
}:

''
  # Rootless podman shells out to the SETUID newuidmap/newgidmap to apply a
  # multi-id mapping. On NixOS those live in /run/wrappers/bin, which is not
  # on the PATH of a systemd unit - so running this from a service (e.g. the
  # `programs.nixct` user service) fails at `up` with
  #   Error: command required for rootless mode with multiple IDs:
  #          exec: "newuidmap": executable file not found in $PATH
  # and the container never starts. They cannot come from runtimeInputs
  # either, since a store copy would lose the setuid bit.
  #
  # It has to come FIRST, not merely be present. NixOS also ships an ordinary
  # newuidmap in /run/current-system/sw/bin, without the setuid bit, and
  # podman runs whichever one the PATH finds first; with that one `up` fails
  # as
  #   newuidmap: write to uid_map failed: Operation not permitted
  #   Error: cannot set up namespace using ".../newuidmap": should have
  #          setuid or have filecaps setuid
  # which reads like a kernel or subuid misconfiguration and is neither. Any
  # caller whose PATH puts the system profile ahead of the wrappers hits it.
  if [ -d /run/wrappers/bin ]; then
    case "$PATH" in
      /run/wrappers/bin|/run/wrappers/bin:*) ;;
      *) PATH="/run/wrappers/bin:$PATH" ;;
    esac
  fi

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
  # NAME feeds directly into $STATE_DIR (a path `purge` rm -rf's) as a
  # bare string-concatenated segment, not a shell token - a NAME
  # containing `/` (e.g. "../../../../tmp/evil") would let $STATE_DIR
  # resolve outside the nix-dev-container state tree entirely. NAME is
  # runtime-overridable via the NAME env var, so this can't be caught
  # at Nix eval time; reject it here before it touches any path.
  case "$NAME" in
    */*|"") echo "error: NAME must not be empty or contain '/' (got: '$NAME')" >&2; exit 1 ;;
  esac
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
  # NIX_STORE_LOWER: the nix-store-lower STORE PATH (the host-side GC-root
  # target). Its /nix/store/ subdir is the symlink farm the FUSE serves as
  # --bind-target (store.nix appends it). Empty unless hostNixStore. NOTE:
  # this is the nix-store-lower layer, NOT the old "host /nix/store source".
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
  # pid files of the host-side `--host-port` bridges
  HOST_PORT_DIR="$STATE_DIR/host-ports"

  # File-descriptor limits for the container, derived from the host's own
  # hard limit rather than hardcoded: podman cannot exceed the invoking
  # user's hard limit anyway, so this way raising it on the host (systemd
  # DefaultLimitNOFILE, pam limits) lifts the container and its FUSE daemons
  # with it and nothing here needs to change. NOFILE_SOFT is what every
  # process starts with; the FUSE daemons raise themselves to the hard limit
  # on top, since their handle pool is shared by everything using the mount.
  NOFILE_HARD=$(ulimit -Hn 2>/dev/null || echo 524288)
  case "$NOFILE_HARD" in
    unlimited|"") NOFILE_HARD=1048576 ;;
  esac
  NOFILE_SOFT=262144
  if [ "$NOFILE_HARD" -lt "$NOFILE_SOFT" ] 2>/dev/null; then
    NOFILE_SOFT=$NOFILE_HARD
  fi
  # The podman run invocation lives inside a quoted `podman unshare` heredoc,
  # which sees only exported variables.
  export NOFILE_SOFT NOFILE_HARD
''
