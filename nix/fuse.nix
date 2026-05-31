# Builds the host-side nix-store-shared-fuse binary: a read-only FUSE
# filesystem that serves a GC-pinned, exact-closure /nix/store symlink farm
# against a relocated backing store. The resulting derivation exposes the
# binary at ${drv}/bin/nix-store-shared-fuse.
{ pkgs }:

pkgs.rustPlatform.buildRustPackage {
  pname = "nix-store-shared-fuse";
  version = "0.1.0";

  src = ../nix-store-shared-fuse;

  cargoLock.lockFile = ../nix-store-shared-fuse/Cargo.lock;

  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ pkgs.fuse3 ];
}
