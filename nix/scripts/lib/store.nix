# /nix provisioning policy — the single source of truth for how the
# container's rootfs base and /nix/store are provisioned. Interpolated
# into the `podman unshare bash <<'INNER'` blocks (start_persistent +
# boot) and into tear_down, all of which run in the rootless user-ns
# where the overlay / bind / fuse mounts must happen.
#
# These are *bash fragments* (not functions). They rely on the caller
# having exported the new axis env (see nix/scripts/run.nix):
#   STORAGE          ephemeral | overlay | directory
#   HOST_NIX_STORE   0 | 1   (serve host store via the FUSE symlink farm)
#   HOST_NIX_DAEMON  0 | 1   (rbind whole host /nix ro + use host daemon)
#   FUSE_BIN         absolute path to nix-store-shared-fuse (HOST_NIX_STORE)
#   REDIRECT_ROOT    physical store root the FUSE reads from (default /nix/store)
#   NIX_STORE_LOWER  the symlink-FARM store path = FUSE --bind-target
#                    (empty unless HOST_NIX_STORE=1)
# plus ROOTFS UPPER WORK MERGED NIX_UPPER NIX_WORK STATE_DIR.
#
# ----------------------------------------------------------------------
# The design has TWO orthogonal concerns:
#
# (1) Rootfs base at $MERGED
#     - ephemeral / overlay : kernel overlayfs lower=$ROOTFS over a
#       writable upper/work. ephemeral vs overlay differ only in WHERE
#       upper/work live (tmpfs vs on-disk), decided by run.nix; this
#       layer treats them identically.
#     - directory : NO overlay. run.nix's ensure_state already
#       materialized $ROOTFS into a writable real copy at $MERGED, so
#       the base needs no mount here.
#
# (2) /nix provisioning on top of the base
#     - HOST_NIX_DAEMON=1 : rbind the WHOLE host /nix read-only (carries
#       host store + authoritative /nix/var db + daemon socket). No FUSE,
#       no store overlay, no in-container daemon (host-daemon NixOS
#       profile is baked in at build time). HOST_NIX_STORE is ignored.
#     - HOST_NIX_STORE=1 (daemon=0) : launch the RO FUSE over the
#       symlink farm, then (except directory mode) stack a writable
#       fuse-overlayfs upper so the in-container daemon's new paths land
#       in $NIX_UPPER. directory mode mounts the FUSE RO directly (no
#       upper — directory mode means no overlays; store stays RO).
#     - neither (self-contained) : the store is BAKED into $ROOTFS.
#       Provide /nix/store as its own mount so the in-container
#       nix-daemon's makeStoreWritable sees a real mount:
#         ephemeral/overlay -> fuse-overlayfs lower=$ROOTFS/nix/store
#                              + writable upper.
#         directory         -> the materialized $MERGED/nix/store is
#                              already real & writable; mount nothing.
# ----------------------------------------------------------------------

{ }:

{
  # (Re)mount the rootfs base at $MERGED, then provision /nix on top per
  # the axes. Idempotent: stale mounts from a half-torn-down run are
  # dropped first. Used by start_persistent and boot.
  mountAll = ''
    # --- drop any stale mounts from a previous, half-torn-down run ---
    # Order mirrors the teardown order: anything stacked inside the base
    # first, then the base. All no-ops when not present.
    # host-daemon: the whole-/nix rbind (recursive).
    umount -R "$MERGED/nix" 2>/dev/null || true
    # host-store / self-contained: the /nix/store overlay or FUSE mount.
    fusermount3 -u "$MERGED/nix/store" 2>/dev/null \
      || umount "$MERGED/nix/store" 2>/dev/null || true
    # host-store: the standalone FUSE that backs the store overlay.
    if [ -n "''${STATE_DIR:-}" ]; then
      fusermount3 -u "$STATE_DIR/fuse-store" 2>/dev/null \
        || umount "$STATE_DIR/fuse-store" 2>/dev/null || true
    fi
    # the rootfs base overlay (directory mode never has one).
    umount "$MERGED" 2>/dev/null || true

    # --- (1) rootfs base at $MERGED ---
    case "$STORAGE" in
      ephemeral|overlay)
        mount -t overlay overlay \
          -o "lowerdir=$ROOTFS,upperdir=$UPPER,workdir=$WORK,userxattr" \
          "$MERGED"
        ;;
      directory)
        # No base overlay: $MERGED is a materialized writable real copy
        # of $ROOTFS, prepared by run.nix's ensure_state. Nothing to do.
        :
        ;;
      *)
        echo "bad STORAGE: $STORAGE" >&2
        exit 2
        ;;
    esac

    # --- (2) /nix provisioning ---
    if [ "''${HOST_NIX_DAEMON:-0}" = "1" ]; then
      # Bring the WHOLE host /nix read-only into the container: host
      # store + authoritative /nix/var db + the daemon socket at
      # /nix/var/nix/daemon-socket/socket. HOST_NIX_STORE is ignored.
      #
      # An `mount -o ro --rbind` does NOT make the recursively-bound
      # submounts read-only (the `ro` only applies to the top bind). So
      # rbind first, then remount-bind ro the top AND every submount
      # underneath it. Walk the mount table for everything mounted at or
      # under $MERGED/nix and remount it read-only.
      mkdir -p "$MERGED/nix"
      mount --rbind /nix "$MERGED/nix"
      # make the subtree private so our remounts don't propagate to the
      # host's /nix mounts.
      mount --make-rprivate "$MERGED/nix" 2>/dev/null || true
      # Remount the top bind ro first, then each submount. findmnt lists
      # deepest-last by default which is the right order for remounts.
      mount -o remount,bind,ro "$MERGED/nix" 2>/dev/null || true
      while IFS= read -r _mp; do
        [ -n "$_mp" ] || continue
        mount -o remount,bind,ro "$_mp" 2>/dev/null || true
      done < <(findmnt -rno TARGET -- "$MERGED/nix" 2>/dev/null | grep -v "^$MERGED/nix\$" || true)
    elif [ "''${HOST_NIX_STORE:-0}" = "1" ]; then
      # Serve the host store through the RO FUSE over the symlink farm,
      # then (except directory mode) stack a writable upper.
      if [ -z "''${FUSE_BIN:-}" ] || [ -z "''${NIX_STORE_LOWER:-}" ]; then
        echo "HOST_NIX_STORE=1 requires FUSE_BIN and NIX_STORE_LOWER" >&2
        exit 2
      fi
      mkdir -p "$STATE_DIR/fuse-store"
      # The FUSE runs in the foreground and OWNS its mount session. We
      # need it to (a) return control to this unshare bash so the block
      # proceeds, and (b) survive after this bash exits, for the whole
      # container lifetime. setsid + background + closed stdio fully
      # detaches it into its own session; it then lives as a host
      # process inside podman's rootless user-ns (the same ns the
      # overlay mounts live in), serving the mount until teardown
      # fusermount3 -u's it. This mirrors how fuse-overlayfs daemonizes.
      setsid "$FUSE_BIN" \
        --bind-target "$NIX_STORE_LOWER" \
        --resolution-root /nix/store \
        --redirect-root "$REDIRECT_ROOT" \
        --allow-other \
        "$STATE_DIR/fuse-store" </dev/null >/dev/null 2>&1 &
      # Poll until the FUSE mount is live (or give up after ~5s).
      _i=0
      while [ "$_i" -lt 50 ]; do
        mountpoint -q "$STATE_DIR/fuse-store" && break
        _i=$((_i + 1))
        sleep 0.1
      done
      if ! mountpoint -q "$STATE_DIR/fuse-store"; then
        echo "nix-store-shared-fuse did not come up at $STATE_DIR/fuse-store" >&2
        exit 2
      fi
      if [ "$STORAGE" = "directory" ]; then
        # directory mode = no overlays. Mount the FUSE store RO directly.
        # TRADEOFF: the in-container store is then READ-ONLY; an
        # in-container daemon cannot add new paths. Acceptable because
        # directory mode is the "no overlay" storage profile.
        mount --bind -o ro "$STATE_DIR/fuse-store" "$MERGED/nix/store"
        mount -o remount,bind,ro "$MERGED/nix/store" 2>/dev/null || true
      else
        # Writable upper so the in-container daemon's new paths land in
        # $NIX_UPPER; the FUSE-served host store is the RO lower.
        fuse-overlayfs \
          -o "lowerdir=$STATE_DIR/fuse-store,upperdir=$NIX_UPPER,workdir=$NIX_WORK" \
          "$MERGED/nix/store"
      fi
    else
      # Self-contained: the store is baked into $ROOTFS. Provide
      # /nix/store as its own mount so the in-container daemon's
      # makeStoreWritable sees a real mount.
      case "$STORAGE" in
        ephemeral|overlay)
          fuse-overlayfs \
            -o "lowerdir=$ROOTFS/nix/store,upperdir=$NIX_UPPER,workdir=$NIX_WORK" \
            "$MERGED/nix/store"
          ;;
        directory)
          # $MERGED/nix/store is already a real writable copy in place
          # (materialized by ensure_state); mount nothing.
          :
          ;;
      esac
    fi
  '';

  # Tear down /nix then the rootfs base, in reverse order, for whichever
  # case mountAll set up. Idempotent: each step is a no-op when absent.
  # Used by tear_down and the boot trap.
  unmount = ''
    if [ "''${HOST_NIX_DAEMON:-0}" = "1" ]; then
      # Recursive unmount of the whole-/nix rbind (carries store, var,
      # daemon socket bind).
      umount -R -- "$MERGED/nix" 2>/dev/null || true
    else
      # host-store: the writable store overlay (or RO FUSE bind in
      # directory mode), THEN the standalone FUSE backing it.
      # self-contained: just the store overlay. All no-ops when absent.
      fusermount3 -u -- "$MERGED/nix/store" 2>/dev/null \
        || umount -- "$MERGED/nix/store" 2>/dev/null || true
      if [ -n "''${STATE_DIR:-}" ]; then
        fusermount3 -u -- "$STATE_DIR/fuse-store" 2>/dev/null \
          || umount -- "$STATE_DIR/fuse-store" 2>/dev/null || true
      fi
    fi
    # The rootfs base overlay (directory mode never has one; the umount
    # is a harmless no-op there).
    umount -- "$MERGED" 2>/dev/null || true
  '';
}
