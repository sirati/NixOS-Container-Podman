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
# CARE: much of this script passes shell snippets to the container inside
# SINGLE-QUOTED strings (`bash -lc '...'`). An apostrophe anywhere in such a
# snippet - including in a comment, e.g. "cannot" written as a contraction -
# closes that string early and the result is a confusing syntax error far
# below. Keep those snippets apostrophe-free. Same rule for `''` inside the
# surrounding Nix '' string, which ends the Nix string instead.
#
# The script body is assembled from cohesive bash fragments under
# nix/scripts/lib/ (store, gpu, forwarding, watchdog) plus the container
# lifecycle + dispatch kept here. Splitting keeps each concern editable
# in isolation; everything is still emitted as one self-contained script.

{ tools
, rootfs ? null
  # The container's system toplevel. Only meaningful with hostNixDaemon,
  # where the container sees the host store and can therefore activate a
  # system that was just built outside it - see the `switch` subcommand.
, toplevel ? null
, shellUser
, name
  # Host directories every develop session of this container gets as a
  # TEMPLATE (frozen lower + per-session overlay upper), as a list of
  # { host, name }. `host` is a shell string expanded at run time (so
  # "''${XDG_STATE_HOME:-$HOME/.local/state}/foo" works) and is created if
  # missing. See the `--template` flag for the runtime version.
, sessionTemplates ? [ ]
  # Host directories every develop session gets SHARED into its HOME, as a
  # list of { host, name, mode ? "rw" }. Unlike a template these are the
  # real directory - writes go through to the host and outlive the session.
  # `host` is a shell string expanded at run time and created if missing.
  # See the `--share` flag for the runtime version.
, sessionShares ? [ ]
  # Extra arguments appended to the `nix develop` the session starts with,
  # e.g. [ "--impure" ]. See `--develop-arg` for the runtime version.
, developArgs ? [ ]
  # Default flags for the `develop` subcommand itself, e.g.
  # [ "--agent" "$HOME/.1password/agent.sock" "--mount-gitconfig" ]. They are
  # prepended to the command line (and shell-expanded), so every session gets
  # them without typing them. NOT the same as developArgs, which go to the
  # `nix develop` inside the session.
, sessionFlags ? [ ]
  # Environment for every develop session, as a list of "KEY=VALUE". $HOME
  # in a value expands to the session HOME. See `--env` for the runtime
  # version.
, sessionEnv ? [ ]
, hostHasNvidiaContainerToolkit ? false
, useKeepId ? false
, keepIdUid ? 1000
, keepIdGid ? 100
, hostWatchdogPath
, checkHostCompatPath  # absolute path to check-host-compat executable
  # gitServeHooks: store path of the hook dir for `develop --git-serve`.
, gitServeHooks ? null
  # lanRuleset/netGatewayRootfs: set together when isolateLan is on. The
  # ruleset is loaded by the HOST into the gateway container namespace; the
  # dev container joins that namespace and has NET_ADMIN dropped, so it can
  # use the network but cannot reconfigure it.
, lanRuleset ? null
, netGatewayRootfs ? null
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
  # Empty unless isolateLan is on; used as the build-time switch for the
  # gateway-container networking below.
  lanRulesetLine = if lanRuleset == null then "" else toString lanRuleset;
  gatewayRootfsLine = if netGatewayRootfs == null then "" else toString netGatewayRootfs;
  isolateLan = lanRuleset != null;
  # Chosen HERE rather than tested in the script: with isolateLan the
  # operand would be a literal store path, which is always non-empty, and
  # shellcheck is right to call that a mistake.
  netFlagsLine =
    if isolateLan
    then "FLAGS+=(--network=\"container:\${NAME}-net\")"
    else "FLAGS+=(--cap-add=NET_ADMIN)";
  # Same reason: a runtime test on a build-time constant.
  netGatewayStart =
    if isolateLan
    then "# Before the container, because the container joins ITS namespace.\n    ensure_net_gateway || exit 1"
    else "";
  netGatewayStop =
    if isolateLan
    then "# After the container: its network namespace lives in the gateway.\n    stop_net_gateway"
    else "";
  # The gateway container owns the network namespace the dev container
  # joins. Defined only when isolateLan is on: with it off there is no
  # gateway, and a body that begins by returning would just be a pile of
  # unreachable code.
  netGatewayFns = if !isolateLan then (
    ""
  ) else ''
    # ensure_net_gateway: bring up the container that owns the network
    # namespace, and load the filter into it.
    #
    # The filtering does not happen inside the dev container, and it does not
    # happen inside this one either: the ruleset is a store file, and the HOST
    # loads it through nsenter into the namespace before anything joins. The
    # gateway itself runs one `sleep` and holds no capability to change what
    # was loaded. Both containers are on the wrong side of the boundary to
    # alter it, which is the whole point of a separate namespace owner.
    ensure_net_gateway() {
      local gw="''${NAME}-net"
      if ! pm container exists "$gw" 2>/dev/null; then
        pm run -d --name "$gw" \
          --network=pasta \
          -v /nix/store:/nix/store:ro \
          --rootfs "${gatewayRootfsLine}:O" \
          ${tools.coreutils}/sleep infinity >/dev/null
      elif [ "$(pm inspect "$gw" --format '{{.State.Status}}' 2>/dev/null)" != running ]; then
        pm start "$gw" >/dev/null
      fi
      local gpid
      gpid=$(pm inspect "$gw" --format '{{.State.Pid}}' 2>/dev/null | tr -d '[:space:]')
      if [ -z "$gpid" ] || [ "$gpid" = 0 ]; then
        echo "$NAME: network gateway did not start" >&2
        return 1
      fi
      # Loaded from the host: podman unshare puts us in the rootless user
      # namespace that OWNS this network namespace, which is where the
      # capability to write a ruleset into it lives.
      _G="$gpid" _R="${lanRulesetLine}" podman unshare "${tools.bash}" -c '
        set -eu
        ${tools.utilLinux}/nsenter --net=/proc/$_G/ns/net ${tools.nft} -f "$_R"
      ' || {
        echo "$NAME: could not load the LAN filter into the gateway" >&2
        return 1
      }
      return 0
    }
  
    # stop_net_gateway: after the dev container, never before - its network
    # namespace lives in here.
    stop_net_gateway() {
      local gw="''${NAME}-net"
      if pm container exists "$gw" 2>/dev/null; then
        pm rm -f "$gw" >/dev/null 2>&1 || true
      fi
    }
  
  '';
  storeLib      = import ./lib/store.nix { };
  gpuFns        = import ./lib/gpu.nix { };
  watchdogFns   = import ./lib/watchdog.nix { inherit hostWatchdogPath; };
  forwardingFns = import ./lib/forwarding.nix { inherit tools; };
  wprsFns       = import ./lib/wprs.nix { inherit tools; };
  dbusFns       = import ./lib/dbus.nix { inherit tools; };

  # Container-declared templates, emitted as shell that seeds the same
  # array `--template` appends to. The host path stays unquoted-expandable
  # so entries can be written relative to $HOME / $XDG_STATE_HOME.
  sessionTemplateLines =
    builtins.concatStringsSep "" (map (t: ''
      _t="${t.host}"
      mkdir -p -- "$_t" 2>/dev/null || true
      template_specs+=("$_t:${t.name}")
    '') sessionTemplates);

  # Same shape for container-declared shares, plus the ro/rw mode.
  sessionShareLines =
    builtins.concatStringsSep "" (map (s: ''
      _s="${s.host}"
      mkdir -p -- "$_s" 2>/dev/null || true
      share_specs+=("$_s:${s.name}:${s.mode or "rw"}")
    '') sessionShares);

  # Container-declared session environment, one KEY=VALUE per entry.
  # $HOME in a value is expanded to the session HOME at run time, which
  # is the only way to name it: the session user is derived from the
  # project path, so its home is not known when this is written.
  # SC2016 is disabled per line on purpose: a `$HOME` in a value must reach
  # the runtime unexpanded, because it names the SESSION home, which does
  # not exist yet and is nothing like the one this script would expand to.
  sessionEnvLines =
    builtins.concatStringsSep "" (map (e:
      "# shellcheck disable=SC2016\n      env_specs+=("
      + shellQuote e + ")\n      ") sessionEnv);

  # Container-declared default flags for `develop`, prepended to the command
  # line. Double-quoted so paths can be written relative to $HOME.
  sessionFlagLine =
    if sessionFlags == [ ] then ""
    else "set -- "
         + builtins.concatStringsSep " " (map (f: "\"" + f + "\"") sessionFlags)
         + " \"$@\"";

  # Single-quote a string for the shell (run.nix takes no `lib`).
  shellQuote = a:
    "'" + builtins.replaceStrings [ "'" ] [ "'\\''" ] a + "'";

  # Container-declared `nix develop` arguments, one array element each so
  # arguments with spaces survive.
  developArgLines =
    builtins.concatStringsSep "" (map (a: ''
      develop_args+=(${shellQuote a})
    '') developArgs);

  # Develop sessions: identities, native mounts, git server, agent, ports.
  sessionBody = import ./run/session.nix {
    inherit tools storeLib gitServeHooks netGatewayStop;
  };

  # Subcommand dispatch: ~1500 lines, half of what this file used to be.
  dispatchBody = import ./run/dispatch.nix {
    inherit tools storeLib checkHostCompatPath toplevel ociRuntimeFlag
      developArgLines sessionEnvLines sessionFlagLine sessionShareLines
      sessionTemplateLines;
  };
in

''
  # Rootless podman shells out to the SETUID newuidmap/newgidmap to apply a
  # multi-id mapping. On NixOS those live in /run/wrappers/bin, which is not
  # on the PATH of a systemd unit - so running this from a service (e.g. the
  # `programs.nixct` user service) fails at `up` with
  #   Error: command required for rootless mode with multiple IDs:
  #          exec: "newuidmap": executable file not found in $PATH
  # and the container never starts. They cannot come from runtimeInputs
  # either, since a store copy would lose the setuid bit.
  if [ -d /run/wrappers/bin ]; then
    case ":$PATH:" in
      *:/run/wrappers/bin:*) ;;
      *) PATH="$PATH:/run/wrappers/bin" ;;
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
    _ROOTFS=$ROOTFS _HOST_NIX_DAEMON=$HOST_NIX_DAEMON \
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
      # Nix DB / daemon-socket location. The profiles/per-user and
      # gcroots/per-user dirs are pre-created in the WRITABLE upper so they
      # mask the read-only, host-root-owned copies baked into the
      # system-lower /nix/var: an in-container nix-daemon (self-contained or
      # host-store modes) chmods these to 1777 on connect, which EPERMs
      # against the baked dirs (owned by a uid unmapped in the rootless
      # user-ns). The upper copies are owned by container root, so the chmod
      # succeeds.
      mkdir -p \
        "$_UPPER"/nix/var/nix/db \
        "$_UPPER"/nix/var/nix/profiles/per-user \
        "$_UPPER"/nix/var/nix/gcroots/per-user \
        "$_UPPER"/nix/var/nix/temproots \
        "$_UPPER"/nix/var/nix/userpool \
        "$_UPPER"/nix/var/nix/daemon-socket
      chmod 1777 "$_UPPER"/tmp "$_UPPER"/var/tmp \
        "$_UPPER"/nix/var/nix/profiles/per-user \
        "$_UPPER"/nix/var/nix/gcroots/per-user
      # Stage a WRITABLE, container-root-owned copy of the baked nix db into
      # the upper. The db baked into the system-lower /nix/var is read-only
      # (0444) and owned by an unmapped (host-root) uid; an overlay copy-up
      # on the first daemon write would inherit those attrs, so the
      # in-container daemon could not write it ("attempt to write a readonly
      # database"). A plain cp (not -a) makes a container-root-owned copy
      # that masks the baked one; chmod makes it writable. Skip in daemon
      # mode (the host db is authoritative) and never clobber a db the
      # daemon has already been writing across restarts.
      if [ "$_HOST_NIX_DAEMON" != "1" ] \
         && [ -f "$_ROOTFS/nix/var/nix/db/db.sqlite" ] \
         && [ ! -f "$_UPPER/nix/var/nix/db/db.sqlite" ]; then
        cp "$_ROOTFS"/nix/var/nix/db/db.sqlite "$_UPPER"/nix/var/nix/db/db.sqlite
        chmod 0644 "$_UPPER"/nix/var/nix/db/db.sqlite
        if [ -f "$_ROOTFS/nix/var/nix/db/schema" ]; then
          cp "$_ROOTFS"/nix/var/nix/db/schema "$_UPPER"/nix/var/nix/db/schema
          chmod 0644 "$_UPPER"/nix/var/nix/db/schema
        fi
      fi
      : > "$_UPPER"/etc/hostname
      : > "$_UPPER"/etc/hosts
      : > "$_UPPER"/etc/resolv.conf
      : > "$_UPPER"/run/.containerenv
      # Stage a real, persistent /etc/machine-id into the upper. The
      # rootfs lower ships it empty (normal for a NixOS image), so
      # without this systemd finds it empty at every boot and falls
      # back to its container-transient-ID path: a read-only tmpfs
      # over /etc/machine-id plus systemd-machine-id-commit.service to
      # persist it later. That commit step relies on container-runtime
      # integration podman does not provide, so it always fails
      # (degraded, not running). Pre-seeding a non-empty ID here means
      # systemd never creates the transient mount, so the commit unit
      # condition (ConditionPathIsMountPoint=/etc/machine-id) is false
      # and it is skipped instead of run. Generated once and kept
      # stable across restarts (not regenerated if already present).
      if [ ! -s "$_UPPER"/etc/machine-id ]; then
        { head -c 16 /dev/urandom | od -An -tx1 | tr -d " \n"; echo; } \
          > "$_UPPER"/etc/machine-id
        chmod 0444 "$_UPPER"/etc/machine-id
      fi
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

  # ----- socket / X11 / Wayland forwarding ----------------------
  ${forwardingFns}

  # ----- optional wprs (proxied Wayland) integration -------------
  ${wprsFns}

  # ----- optional per-session D-Bus session bus -------------------
  ${dbusFns}

  # compute_mount_id <hostpath>: the path itself, encoded. Shared by
  # `develop` and the wayland-attach/wayland-detach subcommands so they
  # agree on which session a hostpath maps to.
  #
  # The id is what you read on the session user, its HOME and its scope
  # name, so it spells the project out rather than hashing it. `/` becomes
  # `-` and a real `-` doubles, which is reversible: a dash that came from
  # the path can never be mistaken for a separator, so two different paths
  # cannot land on one id.
  #
  # A hash comes back only where the encoding cannot carry the path by
  # itself:
  #   - a character outside [A-Za-z0-9._-], which has to be folded to `_`
  #     (that fold is lossy, so `/a b` and `/a_b` would otherwise collide);
  #   - a path too long to survive as a user name, which useradd caps at
  #     255 - minus `dev-` and the `.<share>` suffix the share mounts add.
  # Both are rare enough that ordinary paths keep a clean id.
  #
  # Anything outside [A-Za-z0-9._-] is folded and a leading `-` or `.` is
  # prefixed away, so the id cannot smuggle shell metacharacters or option
  # prefixes into useradd, mount, bindfs, or similar calls.
  compute_mount_id() {
    local hostpath=$1 enc safe mount_id
    # Drop the leading slash; it would only make every id start with a dash.
    enc=''${hostpath#/}
    # Order matters: double the real dashes BEFORE separators become dashes.
    enc=''${enc//-/--}
    enc=''${enc//\//-}
    safe=$(printf '%s' "$enc" | sed 's/[^A-Za-z0-9._-]/_/g')
    mount_id=$safe
    if [ "$safe" != "$enc" ] || [ ''${#safe} -gt 180 ]; then
  ${sessionBody}
      ${storeLib.unmount}
      exit 0
    ' || true
    # Release the host-store GC root so the closure can be collected
    # again (no-op unless HOST_NIX_STORE planted one).
    drop_store_gcroot
  }

  ${dispatchBody}
''
