# Per-session host watchdog: one-shot. Listens on its own socket (path
# encodes mount_id). On any incoming connection, tears down the
# host-side bind for ITS mount_id and exits. A compromised in-container
# watchdog cannot influence other sessions because each watchdog only
# knows its own bound mount_id.
#
# Launched by the main run script via `nohup`, NOT by systemd. Even so,
# every tool reference is a full path: keeps the watchdog robust against
# PATH-stripping environments and future moves into a systemd user unit.

{ tools }:

let
  # Helpers for tool families. tools.coreutils / tools.utilLinux is the
  # bin-directory on NixOS (e.g. /nix/store/.../bin) and an empty string
  # on portable; we collapse the latter to a bare command name.
  bin = n: if tools.coreutils == "" then n else "${tools.coreutils}/${n}";
  ul  = n: if tools.utilLinux == "" then n else "${tools.utilLinux}/${n}";
in
''
  set -u
  STATE_DIR=$1
  MOUNT_ID=$2

  WORK_SHARED=$STATE_DIR/work-shared
  SOCK_DIR=$STATE_DIR/host-watchdog/$MOUNT_ID
  SOCK=$SOCK_DIR/sock

  ${bin "mkdir"} -p "$SOCK_DIR"
  ${bin "rm"} -f "$SOCK"

  # Wait for any connection (= notification from inner watchdog).
  ${tools.socat} -u UNIX-LISTEN:"$SOCK" - >/dev/null 2>&1

  # Teardown host-side binds for THIS mount_id only.
  SM=$STATE_DIR/socket-mounts
  export _MID="$MOUNT_ID" _WS="$WORK_SHARED" _SM="$SM"
  ${tools.podman} unshare \
    ${tools.bash} -c '
      set +e
      t="$_WS/$_MID"
      [ -d "$t" ] && ${ul "mountpoint"} -q -- "$t" && ${ul "umount"} -- "$t"
      ${bin "rmdir"} -- "$t" 2>/dev/null

      # socat-proxied socket forwards under $_WS/.sockets/$_MID/*
      if [ -d "$_WS/.sockets/$_MID" ]; then
        for s in "$_WS/.sockets/$_MID"/*; do
          [ -e "$s" ] && ${ul "mountpoint"} -q -- "$s" && ${ul "umount"} -- "$s"
          ${bin "rm"} -f -- "$s" 2>/dev/null
        done
        ${bin "rmdir"} -- "$_WS/.sockets/$_MID" 2>/dev/null
      fi
      # Raw socket binds under $_SM/$_MID/*
      if [ -d "$_SM/$_MID" ]; then
        for s in "$_SM/$_MID"/*; do
          [ -e "$s" ] && ${ul "mountpoint"} -q -- "$s" && ${ul "umount"} -- "$s"
          ${bin "rm"} -f -- "$s" 2>/dev/null
        done
        ${bin "rmdir"} -- "$_SM/$_MID" 2>/dev/null
      fi
      exit 0
    '

  # Drop this session's GC roots. In host-daemon mode the in-container
  # gcroot-keeper places GC-root symlinks under
  # $STATE_DIR/session-gcroots/$MOUNT_ID (a host-visible dir bind-mounted
  # at the same absolute path) so a concurrent host nix-collect-garbage
  # won't delete store paths the live session needs. The session is now
  # over, so those roots must go: removing the symlinks leaves the host
  # daemon's matching gcroots/auto/* entries dangling, and nix prunes
  # dangling auto-roots on its next GC - making the paths collectable
  # again exactly when the session ends.
  #
  # Unconditional (mode-agnostic): the dir only exists in host-daemon
  # mode and `rm -rf` of a missing path is a harmless no-op. It's owned
  # by the host user (= container root under default rootless), so this
  # watchdog (running as the host user) can remove it directly without
  # `podman unshare`.
  #
  # Fire-and-forget vs the keeper's final pass: the keeper may write one
  # last symlink here as we remove the dir. Both interleavings are benign
  # - the link is either removed with the dir, or orphaned and pruned at
  # the next host GC (a dangling auto-root). MOUNT_ID is the run script's
  # sanitized id (no `/`, `..`, spaces, or globs), and the path is quoted
  # and `--`-terminated, so this can never escape the session subdir.
  ${bin "rm"} -rf -- "$STATE_DIR/session-gcroots/$MOUNT_ID"

  # Any attached wprsc viewer (nixct wayland-attach) would otherwise be
  # left running against a socket that just got torn down above. The
  # short-path symlink alias (see wprs_short_sock_path in wprs.nix -
  # AF_UNIX connect() caps sun_path at ~108 bytes, well under a real
  # $STATE_DIR-derived path) is keyed by the SAME sha256(mount_id)
  # computation so it's found here without sharing bash functions.
  WPRS_PID_FILE="$STATE_DIR/wprs-viewers/$MOUNT_ID.pid"
  if [ -f "$WPRS_PID_FILE" ]; then
    kill "$(${bin "cat"} "$WPRS_PID_FILE" 2>/dev/null)" 2>/dev/null || true
    ${bin "rm"} -f -- "$WPRS_PID_FILE"
  fi
  WPRS_SHORT_HASH=$(printf '%s' "$MOUNT_ID" | ${bin "sha256sum"} | ${bin "cut"} -c1-16)
  ${bin "rm"} -f -- "''${XDG_RUNTIME_DIR:-/tmp}/nixct-wprs-''${WPRS_SHORT_HASH}.sock"

  ${bin "rm"} -f "$SOCK"
  ${bin "rmdir"} "$SOCK_DIR" 2>/dev/null || true
''
