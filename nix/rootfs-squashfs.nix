# Squashfs blob of the container rootfs, built by running mksquashfs
# over the staged tree produced by nix/rootfs-folder.nix. Keeping the
# staging logic in one place avoids divergence between folder-format
# and squashfs-format portable tarballs.
#
# Output:
#   $out/lower.squash              - the squashfs blob
#   $out/lower.squash.sha256       - sha256 of the blob (for integrity
#                                    checking in the portable tarball)

{ pkgs, rootfsFolder }:

pkgs.runCommand "nix-container-rootfs-squashfs"
  {
    nativeBuildInputs = [ pkgs.squashfsTools pkgs.coreutils ];
    passthru = { inherit rootfsFolder; };
  }
  ''
    set -euo pipefail

    # mksquashfs:
    #   -comp zstd -Xcompression-level 19   speed/size sweet spot.
    #     zstd decompresses 5-10x faster than xz at near-xz density,
    #     which matters when squashfuse-mounting on container up.
    #   -all-root                            uids in the squashfs all
    #     become 0:0. Matches how a rootless container sees /nix/store
    #     ownership and removes any extraction-uid sensitivity.
    #   (xattrs preserved by default in modern mksquashfs - kept.)
    mkdir -p $out
    echo "rootfs-squashfs: building squashfs blob ..."
    mksquashfs ${rootfsFolder} $out/lower.squash \
      -comp zstd -Xcompression-level 19 \
      -all-root \
      -no-progress \
      -quiet
    echo "rootfs-squashfs: blob built"

    # Sidecar checksum used by check-host-compat to verify the tarball
    # wasn't corrupted in transit.
    ( cd $out && sha256sum lower.squash | cut -d' ' -f1 > lower.squash.sha256 )

    ls -lh $out
  ''
