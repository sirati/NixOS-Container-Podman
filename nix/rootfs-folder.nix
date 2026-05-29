# Build the container rootfs as a directory of REAL files (closure
# copied in, not symlinked back to host /nix/store). The same staging
# tree is consumed by both:
#
#   - nix/rootfs-squashfs.nix (mksquashfs over this output)
#   - nix/portable-tarball.nix (folder-format tarball ships it as-is)
#
# Output: $out is the rootfs directory tree. Layout matches the
# symlink-flavoured rootfs in flake.nix, just with real /nix/store
# entries instead of symlinks into the host store.

{ pkgs, toplevel, closure, name ? "nixct" }:

pkgs.runCommand "nix-container-rootfs-folder"
  {
    nativeBuildInputs = [ pkgs.coreutils ];
    passthru = { inherit toplevel closure; };
  }
  ''
    set -euo pipefail

    mkdir -p $out
    cd $out

    mkdir -p \
      bin boot dev etc home mnt \
      nix/store nix/var \
      opt proc root run sbin srv \
      sys tmp usr var

    ln -s ${toplevel}/init init
    ln -s /init sbin/init
    ln -s ${toplevel}/etc/os-release etc/os-release
    : > etc/machine-id
    ln -s /proc/mounts etc/mtab

    cp ${closure}/registration nix-path-registration

    # Copy the full closure as real files. --reflink=auto lets btrfs
    # hosts dedupe at build time; harmless on other filesystems.
    # -p preserves modes/ownership/timestamps. Closure store paths
    # don't typically carry xattrs, but if they do we keep them.
    echo "rootfs-folder: copying closure ..."
    while IFS= read -r p; do
      base=$(basename -- "$p")
      cp -R --reflink=auto --preserve=mode,ownership,timestamps,xattr \
        -- "$p" "nix/store/$base"
    done < ${closure}/store-paths
    echo "rootfs-folder: closure copy done"

    # Size report (handy when diagnosing tarball bloat).
    du -sh $out 2>/dev/null || true
  ''
