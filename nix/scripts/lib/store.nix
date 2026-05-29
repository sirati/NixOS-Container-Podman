# /nix/store mounting policy — the single source of truth for how the
# container's /nix/store is provisioned. Previously this logic was
# duplicated inline in start_persistent, hardcoded (fuse-overlayfs only,
# ignoring NIX_STORE_MODE) in boot, and a third, never-called
# `nix_store_mount_args` helper sat dead in run.nix. All three are now
# replaced by the snippets below, interpolated into both INNER heredocs
# and into tear_down.
#
# These are *bash fragments* (not functions): they are interpolated into
# the `podman unshare bash <<'INNER'` blocks, which run in the rootless
# user-ns where the overlay/bind mounts must happen. They rely on the
# caller having exported: ROOTFS UPPER WORK MERGED NIX_STORE_MODE
# NIX_STORE_LOWER NIX_UPPER NIX_WORK and, for host-daemon, NIX_DAEMON_SOCKET.
#
# Modes:
#   overlay      host /nix/store RO lower + writable fuse-overlayfs upper.
#                In-container installs land in the upper, host store
#                untouched. The default.
#   passthrough  bind host /nix/store rw; in-container writes hit the
#                host store directly.
#   ro           bind host /nix/store ro; no installs from inside.
#   host-daemon  bind host /nix/store ro AND bind the host nix-daemon
#                socket into /nix/var/nix/daemon-socket/socket, so every
#                in-container nix client delegates builds/queries to the
#                host daemon (which writes to the host store, visible RO
#                here). Pairs with the NixOS-module changes gated on
#                nixDevContainer.hostDaemon.enable (no in-container
#                daemon, no nixbld users, store = daemon).

{ }:

{
  # (Re)mount the rootfs kernel-overlay at $MERGED, then mount /nix/store
  # on top of it per $NIX_STORE_MODE. Idempotent: stale mounts are torn
  # down first. Used by start_persistent and boot.
  mountAll = ''
    # Drop any stale mounts from a previous, half-torn-down run.
    # The daemon-socket bind (host-daemon mode) lives inside $MERGED, so
    # release it before the overlay; a no-op in the other modes.
    umount "$MERGED/nix/var/nix/daemon-socket/socket" 2>/dev/null || true
    fusermount3 -u "$MERGED/nix/store" 2>/dev/null \
      || umount "$MERGED/nix/store" 2>/dev/null || true
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
      passthrough)
        mount --bind "$NIX_STORE_LOWER" "$MERGED/nix/store"
        ;;
      ro)
        mount --bind -o ro "$NIX_STORE_LOWER" "$MERGED/nix/store"
        ;;
      host-daemon)
        # Host store, read-only: the host daemon owns all writes.
        mount --bind -o ro "$NIX_STORE_LOWER" "$MERGED/nix/store"
        # Bind the host nix-daemon socket to the conventional client
        # path. NIX_REMOTE=daemon / store=daemon (set by the NixOS
        # module) makes every in-container client connect here.
        _sockdir="$MERGED/nix/var/nix/daemon-socket"
        mkdir -p "$_sockdir"
        [ -e "$_sockdir/socket" ] || : > "$_sockdir/socket"
        mount --bind "$NIX_DAEMON_SOCKET" "$_sockdir/socket"
        ;;
      *)
        echo "bad NIX_STORE_MODE: $NIX_STORE_MODE" >&2
        exit 2
        ;;
    esac
  '';

  # Unmount the /nix/store mount then the rootfs overlay. Used by
  # tear_down and the boot trap. host-daemon's socket bind lives inside
  # $MERGED, so it is released when $MERGED is unmounted — no special
  # case needed here.
  unmount = ''
    umount -- "$MERGED/nix/var/nix/daemon-socket/socket" 2>/dev/null || true
    fusermount3 -u -- "$MERGED/nix/store" 2>/dev/null \
      || umount -- "$MERGED/nix/store" 2>/dev/null || true
    umount -- "$MERGED" 2>/dev/null || true
  '';
}
