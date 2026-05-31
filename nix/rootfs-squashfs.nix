# Squashfs blob of the container rootfs, built by running mksquashfs over
# the assembled tree produced by nix/rootfs-folder.nix. The folder builder
# is the single source of truth for the assemble + conditional-materialize
# model, so this file just wraps it and compresses the result.
#
# Output:
#   $out/lower.squash              - the squashfs blob
#   $out/lower.squash.sha256       - sha256 of the blob (for integrity
#                                    checking in the portable tarball)
#
# Contract:
#   { pkgs, systemLower, nixStoreLower, includeStore ? false, name ? "nixct" }
#     -> drv
#   includeStore is threaded straight into rootfs-folder.nix:
#     false -> squashfs over a store-empty skeleton (runtime fills /nix/store)
#     true  -> squashfs over a self-contained, materialized closure

{ pkgs, systemLower, nixStoreLower, includeStore ? false, name ? "nixct" }:

let
  # Single source of truth: assemble the folder, then squash THAT.
  rootfsFolder = import ./rootfs-folder.nix {
    inherit pkgs systemLower nixStoreLower includeStore name;
  };
in
pkgs.runCommand "${name}-rootfs-squashfs"
  {
    nativeBuildInputs = [ pkgs.squashfsTools pkgs.coreutils ];
    # Re-export the inner folder (and its layers) for debugging.
    passthru = { inherit rootfsFolder includeStore; };
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
