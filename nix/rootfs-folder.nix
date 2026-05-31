# Assemble the container rootfs FOLDER from the orthogonal lower layers.
#
# This is the packaging step that turns the tiny, store-empty `systemLower`
# skeleton into a concrete rootfs directory, OPTIONALLY materializing the
# real Nix closure into /nix/store.
#
# Model:
#   - systemLower carries the COMPLETE runnable skeleton: FHS dirs, /init,
#     sbin/init, static /etc, /nix-path-registration, the PRE-BUILT
#     /nix/var Nix db (closure already registered), the /nix/.store-lower
#     GC-reference file, and an EMPTY /nix/store mountpoint.
#   - We copy that whole tree into $out as WRITABLE real files and then,
#     depending on `includeStore`, either leave /nix/store empty (the
#     runtime FUSE / host rbind fills it) or MATERIALIZE the real closure
#     into it (a fully self-contained lower).
#
# Consumed by:
#   - nix/rootfs-squashfs.nix (mksquashfs over this output)
#   - nix/portable-tarball.nix (folder-format tarball ships it as-is)
#
# Contract:
#   { pkgs, systemLower, nixStoreLower, includeStore ? false, name ? "nixct" }
#     -> drv whose $out is the assembled rootfs directory.
#
#   systemLower    = import ./system-lower.nix { ... }  (skeleton + db)
#   nixStoreLower  = import ./nix-store-lower.nix { ... }  (passthru.closure)
#   includeStore   = false -> /nix/store stays EMPTY
#                    true  -> /nix/store materialized with the real closure

{ pkgs, systemLower, nixStoreLower, includeStore ? false, name ? "nixct" }:

pkgs.runCommand "${name}-rootfs-folder"
  {
    nativeBuildInputs = [ pkgs.coreutils ];
    # Re-export the layers and the chosen mode for composition/debugging,
    # plus toplevel/closure for convenience (sourced from systemLower).
    passthru = {
      inherit systemLower nixStoreLower includeStore;
      inherit (systemLower) toplevel closure;
    };
  }
  ''
    set -euo pipefail

    # --- Copy the complete skeleton in as writable real files -------------
    # systemLower lives in the read-only store with r-xr-xr-x dirs. cp -R
    # preserves that, so we MUST chmod -R u+w afterwards or later steps (and
    # the runtime) cannot write. We deliberately do NOT preserve ownership;
    # everything ends up owned by the build user and is normalized to 0:0
    # later (mksquashfs -all-root / tarball packaging). The pre-built
    # /nix/var db and the /nix/.store-lower GC marker come along verbatim.
    echo "rootfs-folder: staging systemLower skeleton ..."
    mkdir -p $out
    cp -R --reflink=auto -- ${systemLower}/. $out/
    chmod -R u+w $out

    ${if includeStore then ''
    # --- Materialize the real closure into /nix/store ---------------------
    # Self-contained lower: copy every closure path in as REAL files (not
    # symlinks). --reflink=auto lets btrfs hosts dedupe at build time;
    # harmless elsewhere. We preserve mode/timestamps/xattr but not
    # ownership (normalized at package time). Source the path list from the
    # nixStoreLower closure (passthru.closure) so both layers agree on the
    # exact closure being shipped. /nix/store already exists (empty) from
    # the skeleton copy.
    echo "rootfs-folder: includeStore=true, materializing closure ..."
    while IFS= read -r p; do
      base=$(basename -- "$p")
      cp -R --reflink=auto --preserve=mode,timestamps,xattr \
        -- "$p" "$out/nix/store/$base"
    done < ${nixStoreLower.closure}/store-paths
    chmod -R u+w $out/nix/store
    echo "rootfs-folder: closure materialized"
    '' else ''
    # --- Leave /nix/store EMPTY -------------------------------------------
    # includeStore=false: the store mountpoint stays empty. The runtime
    # fills it -- FUSE (host-nix-store mode) or a host /nix rbind (daemon
    # mode). Nothing to do here.
    echo "rootfs-folder: includeStore=false, /nix/store left empty"
    ''}

    # Size report (handy when diagnosing tarball bloat).
    du -sh $out 2>/dev/null || true
  ''
