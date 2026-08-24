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

{ lib
, tools
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
  # The namespace owner's pause binary on the host, bind-mounted onto /pause
  # inside it. See nix/net-owner.nix: a statically linked catatonit, so that
  # container needs no store, no libc and no coreutils.
, netOwnerBinary ? null
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
  netOwnerBinaryLine = if netOwnerBinary == null then "" else toString netOwnerBinary;
  # gitServeHooks is optional -- the portable tarball does not pass it -- so
  # it needs the same treatment as every other optional store path here.
  # Interpolating it raw made the whole portable build fail with "cannot
  # coerce null to a string" before the script was ever produced.
  gitServeHooksLine = if gitServeHooks == null then "" else toString gitServeHooks;

  # Chosen here rather than tested in the script: with hooks configured the
  # operand would be a literal store path, which is always non-empty, and
  # shellcheck is right to call that a mistake (SC2157). Same reasoning as
  # netFlagsLine above.
  gitServeGuard =
    if gitServeHooks != null then ""
    else ''
      echo "git serving: not implemented in this build" >&2
      return 1
    '';

  podman = import ../podman.nix { inherit lib; };

  # The namespace owner's invocation, assembled by the validated model rather
  # than written out here. `rt "gw"` is the shell variable holding the
  # container name, the one value not known at evaluation time.
  #
  # `pm` is a shell function that already supplies --runtime, so the model is
  # told there is none. The pause binary's mount is explicitly NOT noexec:
  # it is the one thing in that container that has to be executable, and the
  # model defaults mounts to noexec precisely so that saying otherwise is
  # deliberate.
  netOwnerRunLine =
    if !isolateLan then "" else
    podman.renderRunShell "pm" {
      name = podman.rt "gw";
      rootfs = gatewayRootfsLine;
      command = [ "/pause" "-P" ];
      detach = true;
      remove = false;
      readOnly = true;
      runtime = null;
      network = { mode = "pasta"; };
      mounts = [{
        type = "bind";
        source = netOwnerBinaryLine;
        destination = "/pause";
        readOnly = true;
        noexec = false;
      }];
    };
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
        ${netOwnerRunLine} >/dev/null
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

  # Environment and provisioning axes: where Nix values become shell defaults.
  envBody = import ./run/env.nix {
    inherit name shellUser storage redirectRoot rootfsLine stateDirLine
      fusePath hostHasNvidiaContainerToolkit hostNixDaemon hostNixStore
      idleTimeout keepIdGid keepIdUid nixStoreLower useKeepId;
  };

  # State: shared host dirs, store GC roots, state layout, rootfs lower.
  stateBody = import ./run/state.nix { inherit tools mountLowerBody; };

  # Container lifecycle: podman wrapper, state, and the start invocation.
  containerBody = import ./run/container.nix {
    inherit tools storeLib netFlagsLine netGatewayFns netGatewayStart
      ociRuntimeFlag;
  };

  # Develop sessions: identities, native mounts, git server, agent, ports.
  sessionBody = import ./run/session.nix {
    inherit tools storeLib netGatewayStop;
    gitServeHooks = gitServeHooksLine;
    inherit gitServeGuard;
  };

  # Subcommand dispatch: ~1500 lines, half of what this file used to be.
  dispatchBody = import ./run/dispatch.nix {
    inherit tools storeLib checkHostCompatPath toplevel ociRuntimeFlag
      developArgLines sessionEnvLines sessionFlagLine sessionShareLines
      sessionTemplateLines;
  };
in

''
  ${envBody}
  ${stateBody}
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

  ${containerBody}
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
