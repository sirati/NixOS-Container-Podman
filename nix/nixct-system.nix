# Minimal develop-only NixOS config for the `nixct` package. Built
# host-daemon + develop-only by mkContainer (shellUser = "root"), so it
# defines NO interactive/dev user: the only entry is `nixct develop`,
# which creates ephemeral per-session users at runtime (run script). The
# framework module (nix/container-module.nix) supplies all develop infra
# (watchdog, /develop-home + /run/sockets tmpfiles, bindfs/socat/fuse3),
# direnv integration, and - via nixStore.mode - the host-daemon profile.

{ config, lib, pkgs, ... }:

{
  # git for user projects, vim as a basic editor. bindfs/socat/fuse3 and
  # direnv come from the framework module; don't re-add them here.
  environment.systemPackages = with pkgs; [ git vim ];

  networking.hostName = lib.mkDefault "nixct";
}
