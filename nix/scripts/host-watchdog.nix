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

  ${bin "rm"} -f "$SOCK"
  ${bin "rmdir"} "$SOCK_DIR" 2>/dev/null || true
''
