# nixct-nvidia: dev container with the host-matching nvidia userland
# plus a "ready to install CUDA / PyTorch / python myself" toolbox.
# Intentionally does NOT bake CUDA, torch, or python into the closure -
# those get installed per-project by the user via devenv / nix-direnv
# inside /develop-home/<session>.

{ config, lib, pkgs, ... }:

{
  imports = [ ./configuration.nix ];

  # nvidia-x11 and any future GPU-userland binaries are proprietary.
  nixpkgs.config.allowUnfree = true;

  networking.hostName = lib.mkForce "nixct-nvidia";

  environment.systemPackages = with pkgs; [
    # Host-matching nvidia userland (nvidia-smi, nvidia-debugdump, etc.).
    # production currently == 595.71.05; tracks the host driver. ABI
    # must match the host's kernel module exactly.
    config.boot.kernelPackages.nvidiaPackages.production.bin

    # Dev toolbox.
    btop htop tmux git
    direnv nix-direnv
    devenv
  ];

  # direnv hook into bash + nix-direnv's use_flake / use_nix helpers.
  # Without these, the user has to manually eval the hook in every
  # shell and direnv won't understand .envrc files that say `use flake`.
  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
  };

  # Substituters and their public keys. These get OR'd with whatever
  # the container-module.nix already has (substituters merge as lists),
  # and the @wheel trusted-users from the framework already covers the
  # dev user. allowUnfree above lets them pull GPU/ML binaries from the
  # CUDA / AI caches without re-deriving each one.
  nix.settings = {
    substituters = [
      "https://cache.nixos.org/"
      "https://nix-community.cachix.org"
      "https://cache.nixos-cuda.org"
      "https://cuda-maintainers.cachix.org"
      "https://ai.cachix.org"
      "https://cache.flox.dev"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "cache.nixos-cuda.org:74DUi4Ye579gUqzH4ziL9IyiJBlDpMRn9MBN8oNan9M="
      "cuda-maintainers.cachix.org-1:0dq3bujKpuEPMCX6U4WylrUDZ9JyUG0VpVZa7CNfq5E="
      "ai.cachix.org-1:N9dzRK+alWwoKXQlnn0H6aUx0lU/mspIoz8hMvGvbbc="
      "flox-cache-public-1:7F4OyH7ZCnFhcze3fJdfyXYLQw/aV7GEed86nQ7IsOs="
    ];
  };
}
