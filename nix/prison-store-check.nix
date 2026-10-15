# ExecCondition of every prison service unit: refuses to start it against a
# store view that serves another closure, and queues the view's restart. See
# prison-store-check/src/lib.rs. The binary is ${drv}/bin/prison-store-check.
{ pkgs }:

pkgs.rustPlatform.buildRustPackage {
  pname = "prison-store-check";
  version = "0.1.0";

  src = ../prison-store-check;

  cargoLock.lockFile = ../prison-store-check/Cargo.lock;
}
