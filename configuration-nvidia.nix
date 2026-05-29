# Nvidia-flavoured variant of the example configuration. Adds the host-
# matching nvidia userland (nvidia-smi & friends) so `nix run
# .#testnvidia.up -- --gpu` followed by `.enter` can run nvidia-smi
# directly. The kernel-module side comes from the host's /dev/nvidia*
# nodes (bound in by the --gpu flag in the run script).

{ config, lib, pkgs, ... }:

{
  imports = [ ./configuration.nix ];

  # nvidia-x11 is unfree (proprietary userland blob). Whitelist just it
  # so the rest of the closure remains under the default free policy.
  nixpkgs.config.allowUnfreePredicate = pkg:
    builtins.elem (lib.getName pkg) [ "nvidia-x11" "nvidia-settings" ];

  environment.systemPackages = [
    # nvidiaPackages.production currently == host's 595.71.05. The bin
    # output ships nvidia-smi, nvidia-debugdump, nvidia-modprobe (unused
    # in container), nvidia-settings, etc. Userland ABI must match the
    # host's kernel module exactly - production is the safest channel
    # for that.
    config.boot.kernelPackages.nvidiaPackages.production.bin
  ];

  networking.hostName = lib.mkForce "nixct-nvidia";
}
