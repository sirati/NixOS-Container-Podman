# Build a self-contained tarball that runs the same container stack on
# any Linux host (Debian/Fedora/Arch/...) with rootless podman +
# fuse-overlayfs installed via the host's package manager. No Nix
# required.
#
# Layout (after extraction):
#
#   <name>-portable/
#     ├── bin/
#     │   └── nixct                     # single entry point; dispatches by $1
#     ├── lib/
#     │   ├── host-watchdog             # called internally by nixct
#     │   └── check-host-compat         # invoked via `nixct check-host-compat`
#     ├── share/
#     │   └── bash-completion/completions/nixct
#     ├── data/
#     │   ├── (lower.squash + .sha256)  # format = squashfs / both
#     │   ├── (lower/)                  # format = folder / both
#     │   ├── upper/                    # rootfs overlay upper (rw)
#     │   └── work/                     # rootfs overlay work
#     ├── README.md
#     └── VERSION
#
# Add `<extracted-dir>/bin` to your $PATH and run `nixct up`,
# `nixct enter`, etc. Source share/bash-completion/completions/nixct
# from your ~/.bashrc for tab completion.
#
# Three rootfs formats (selected by `format` parameter):
#
#   "squashfs" (default): single zstd-19 blob, mounted via squashfuse.
#                         Smallest tarball, requires squashfuse on host.
#   "folder"            : rootfs as real files; no squashfuse needed.
#                         xz-tarred to keep the closure compressed.
#   "both"              : ships both; run script prefers squashfs when
#                         squashfuse is available, falls back to folder.

{ pkgs
, name
, shellUser
, rootfsFolder
, rootfsSquashfs
, hostHasNvidiaContainerToolkit ? false
, useKeepId ? false
, keepIdUid ? 1000
, keepIdGid ? 100
  # A portable tarball is ALWAYS self-contained: it ships its own
  # /nix/store baked into the rootfs lower (the flake builds the
  # rootfsFolder/rootfsSquashfs payload with includeStore = true) and
  # the target host has neither the build host's /nix/store nor a
  # nix-daemon. Both of these therefore MUST be false; they exist only
  # so the assertion below can reject a misconfiguration explicitly.
, hostNixStore ? false
, hostNixDaemon ? false
, version ? "0.0.0"
, format ? "squashfs"
}:

assert pkgs.lib.elem format [ "squashfs" "folder" "both" ];
assert (!hostNixStore && !hostNixDaemon)
  || throw "portable tarball must be self-contained: hostNixStore/hostNixDaemon are not supported on a portable target (the target host has no shared /nix/store or nix-daemon)";

let
  toolsLib = import ./scripts/tools.nix;
  tools = toolsLib.mkPortableTools;

  includeSquashfs = format == "squashfs" || format == "both";
  includeFolder   = format == "folder"   || format == "both";

  # Tar compression: squashfs blob is already zstd-compressed so extra
  # tar compression buys little; folder/closure compresses well under
  # xz (xz ratio ~80% on a typical NixOS closure).
  tarCompression =
    if format == "squashfs" then "gzip" else "xz";
  tarSuffix =
    if tarCompression == "gzip" then "tar.gz" else "tar.xz";
  tarFlag =
    if tarCompression == "gzip" then "z" else "J";

  # rootfsLine: emitted at the top of the run script. Resolves the
  # extracted-dir location and exposes ROOTFS_BLOB / ROOTFS_DIR.
  # ROOTFS itself is set lazily by mount_rootfs_lower.
  #
  # nixct lives at <extracted>/bin/nixct, so _BASE_DIR is
  # `<extracted>` (one dirname up).
  rootfsLine = ''
    _SCRIPT_DIR=$(dirname -- "$(readlink -f -- "$0")")
    _BASE_DIR=$(dirname -- "$_SCRIPT_DIR")
    DATA_DIR=''${DATA_DIR:-$_BASE_DIR/data}
    ROOTFS_BLOB=$DATA_DIR/lower.squash
    ROOTFS_DIR=$DATA_DIR/lower
    ROOTFS=
  '';

  stateDirLine = ''
    STATE_DIR=''${STATE_DIR:-$DATA_DIR}
  '';

  # mount_rootfs_lower() only resolves $ROOTFS (the extracted/mounted
  # rootfs lower). The /nix/store overlay lower is derived internally by
  # store.nix from $ROOTFS/nix/store, since a portable tarball is always
  # self-contained (the rootfs payload carries the full closure). There
  # is no host-side /nix/store or nix-daemon, so nothing else to set.
  mountLowerBody =
    if format == "folder" then ''
      if [ ! -d "$ROOTFS_DIR" ]; then
        echo "mount_rootfs_lower: data/lower/ missing" >&2
        exit 1
      fi
      ROOTFS=$ROOTFS_DIR
    '' else if format == "squashfs" then ''
      ROOTFS=$STATE_DIR/lower-mount
      mkdir -p -- "$ROOTFS"
      if ! mountpoint -q -- "$ROOTFS"; then
        if ! command -v squashfuse >/dev/null 2>&1; then
          echo "mount_rootfs_lower: squashfuse not on PATH; install it or rebuild with format=folder" >&2
          exit 1
        fi
        squashfuse "$ROOTFS_BLOB" "$ROOTFS"
      fi
    '' else /* both */ ''
      if command -v squashfuse >/dev/null 2>&1 && [ -e "$ROOTFS_BLOB" ]; then
        ROOTFS=$STATE_DIR/lower-mount
        mkdir -p -- "$ROOTFS"
        if ! mountpoint -q -- "$ROOTFS"; then
          squashfuse "$ROOTFS_BLOB" "$ROOTFS"
        fi
      elif [ -d "$ROOTFS_DIR" ]; then
        ROOTFS=$ROOTFS_DIR
      else
        echo "mount_rootfs_lower: neither data/lower.squash + squashfuse nor data/lower/ usable" >&2
        exit 1
      fi
    '';

  runText = import ./scripts/run.nix {
    inherit (pkgs) lib;
    inherit tools shellUser name
            hostHasNvidiaContainerToolkit useKeepId keepIdUid keepIdGid;
    # Portable is always self-contained: persistent on-disk overlay
    # (data/upper), store baked into the rootfs lower, no host store or
    # daemon. nixStoreLower stays null so store.nix derives the lower
    # from $ROOTFS/nix/store itself; redirectRoot keeps its default.
    storage = "overlay";
    hostNixStore = false;
    hostNixDaemon = false;
    fusePath = null;
    nixStoreLower = null;
    rootfs = null;
    inherit rootfsLine stateDirLine mountLowerBody;
    hostWatchdogPath    = ''"$_BASE_DIR/lib/host-watchdog"'';
    checkHostCompatPath = ''"$_BASE_DIR/lib/check-host-compat"'';
    # Let podman use its host-configured default runtime (typically
    # runc on Debian/Ubuntu, crun on Fedora/Arch). Forcing `--runtime
    # crun` would break hosts that only ship runc.
    ociRuntimeFlag = "";
  };

  hostWatchdogText = import ./scripts/host-watchdog.nix { inherit tools; };
  checkCompatText  = import ./scripts/check-host-compat.nix { inherit tools; };

  preamble = ''
    #!/usr/bin/env bash
    set -o errexit
    set -o pipefail
    export PATH=''${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
  '';

  # Single dispatcher (bin/nixct) and two helper scripts under lib/.
  nixctScript    = pkgs.writeTextFile {
    name = "nixct"; executable = true;
    destination = "/nixct"; text = preamble + "\n" + runText;
  };
  watchdogScript = pkgs.writeTextFile {
    name = "host-watchdog"; executable = true;
    destination = "/host-watchdog"; text = preamble + "\n" + hostWatchdogText;
  };
  checkScript    = pkgs.writeTextFile {
    name = "check-host-compat"; executable = true;
    destination = "/check-host-compat"; text = preamble + "\n" + checkCompatText;
  };

  # Bash completion. Source from ~/.bashrc or symlink to
  # ~/.local/share/bash-completion/completions/nixct.
  completionPkg = import ./scripts/completion.nix { inherit pkgs; cmdName = "nixct"; };

  readme = pkgs.writeText "README.md" ''
    # ${name}-portable (${format} format)

    Self-contained nix-dev-container bundle. No Nix required on the host.

    ## Setup

    Install via your distro package manager:
    - podman (with rootless setup; `podman info` must succeed)
    - fuse-overlayfs, fuse3, socat
    - util-linux, findutils, gawk
    - xauth (only for X11 forwarding)${if includeSquashfs then ''

    - squashfuse${if format == "both" then " (optional - falls back to folder layout if missing)" else ""}'' else ""}

    Quick check:
    ```
    bin/nixct check-host-compat
    ```

    ## Path setup

    Add `bin/` to your $PATH so `nixct` is directly callable:
    ```
    export PATH="$PWD/bin:$PATH"
    ```
    (Replace `$PWD` with the absolute extracted-dir path. Put it in
    your ~/.bashrc to persist.)

    For tab completion in bash:
    ```
    source share/bash-completion/completions/nixct
    # or, persistently:
    mkdir -p ~/.local/share/bash-completion/completions
    ln -s "$PWD/share/bash-completion/completions/nixct" \
      ~/.local/share/bash-completion/completions/nixct
    ```

    ## Usage

    ```
    nixct up                    # start the container
    nixct enter                 # interactive shell as ${shellUser}
    nixct enter --wayland       # with Wayland forwarded
    nixct develop <path>        # session-bound dev shell for a project
    nixct down                  # stop
    nixct purge                 # wipe state
    nixct check-host-compat     # re-run the host probe
    ```

    State lives in `./data/` next to the scripts. Move the entire
    extracted dir wherever you want; paths are resolved relative to
    the dispatcher's location.

    ## Format

    Built with `format = "${format}"`:
    ${if format == "squashfs" then ''
      - `data/lower.squash`: zstd-compressed rootfs, mounted via squashfuse.''
      else if format == "folder" then ''
      - `data/lower/`: rootfs as plain files, used directly as overlay lowerdir.
      - No squashfuse needed.''
      else /* both */ ''
      - `data/lower.squash` AND `data/lower/`.
      - Picks squashfs at up time when squashfuse is on PATH, else folder.''}
  '';

  copySquashfsCmd =
    if includeSquashfs then ''
      cp ${rootfsSquashfs}/lower.squash         "$stage/data/lower.squash"
      cp ${rootfsSquashfs}/lower.squash.sha256  "$stage/data/lower.squash.sha256"
      chmod 0644 "$stage/data/lower.squash" "$stage/data/lower.squash.sha256"
    '' else "";

  copyFolderCmd =
    if includeFolder then ''
      cp -R --reflink=auto --preserve=mode,timestamps,xattr \
        -- ${rootfsFolder}/. "$stage/data/lower/"
    '' else "";

  versionLine =
    if includeSquashfs then ''
      printf 'rootfs sha256: '
      cat ${rootfsSquashfs}/lower.squash.sha256
    '' else ''
      echo 'rootfs format: folder (no blob)'
    '';
in
pkgs.runCommand "${name}-portable-tarball-${format}"
  {
    nativeBuildInputs = [ pkgs.coreutils pkgs.gnutar pkgs.gzip pkgs.xz ];
    passthru = {
      inherit nixctScript watchdogScript checkScript;
      inherit rootfsFolder;
      rootfsSquashfs = if includeSquashfs then rootfsSquashfs else null;
      tools = tools;
      format = format;
    };
  }
  ''
    set -euo pipefail

    stage=${name}-portable
    mkdir -p \
      "$stage/bin" \
      "$stage/lib" \
      "$stage/share/bash-completion/completions" \
      "$stage/data/upper" "$stage/data/work"
    ${pkgs.lib.optionalString includeFolder ''mkdir -p "$stage/data/lower"''}

    # Single entry point.
    cp ${nixctScript}/nixct                "$stage/bin/nixct"

    # Helpers (not on user's PATH, invoked internally).
    cp ${watchdogScript}/host-watchdog     "$stage/lib/host-watchdog"
    cp ${checkScript}/check-host-compat    "$stage/lib/check-host-compat"

    chmod 0755 "$stage/bin"/* "$stage/lib"/*

    # Bash completion.
    cp ${completionPkg}/share/bash-completion/completions/nixct \
      "$stage/share/bash-completion/completions/nixct"

    # Rootfs payload.
    ${copySquashfsCmd}
    ${copyFolderCmd}

    cp ${readme} "$stage/README.md"
    {
      echo "${name}-portable v${version} (format=${format})"
      ${versionLine}
    } > "$stage/VERSION"

    mkdir -p $out
    tar --owner=0 --group=0 --mtime='@1' \
      -c${tarFlag}f "$out/${name}-portable.${tarSuffix}" "$stage"

    ls -lh $out
  ''
