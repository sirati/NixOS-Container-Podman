# Host-side wrapper for a prison service's `podman run`: see
# prison-start/src/main.rs. The binary is ${drv}/bin/prison-start.
{ pkgs }:

pkgs.rustPlatform.buildRustPackage {
  pname = "prison-start";
  version = "0.1.0";

  src = ../prison-start;

  cargoLock.lockFile = ../prison-start/Cargo.lock;

  nativeCheckInputs = [ pkgs.procps ];
}
