# Builds the host-side ssh-agent-filter binary: a filtering proxy for the
# SSH agent protocol, so a container can be handed the use of some keys
# without being handed the agent. Exposes ${drv}/bin/ssh-agent-filter.
{ pkgs }:

pkgs.rustPlatform.buildRustPackage {
  pname = "ssh-agent-filter";
  version = "0.1.0";

  src = ../ssh-agent-filter;

  cargoLock.lockFile = ../ssh-agent-filter/Cargo.lock;
}
