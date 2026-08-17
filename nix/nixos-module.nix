# NixOS module factory for the nixct dev container. Imported with the
# flake's `mkNixct` builder and exposes `programs.nixct`: it installs the
# `nixct` binary (host-daemon, develop-only) system-wide and can run a
# per-user systemd service that keeps the container up across the session
# (which owns the lifecycle, so idle shutdown is disabled in that mode).
{ mkNixct }:
{ config, lib, pkgs, ... }:
let
  cfg = config.programs.nixct;
in {
  options.programs.nixct = {
    enable = lib.mkEnableOption "the nixct dev container (host-daemon, develop-only)";
    name = lib.mkOption { type = lib.types.str; default = "nixct"; description = "container name"; };
    idleTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.unsigned; default = 600;
      description = "Stop the container after this many seconds with no active `nixct develop` session. 0 disables. Ignored when service.enable = true (the service owns the lifecycle).";
    };
    gpu = {
      enable = lib.mkEnableOption "GPU/OpenGL passthrough (the user service runs `nixct up --gpu --opengl`)";
      hostHasToolkit = lib.mkEnableOption "use the host's nvidia-container-toolkit (CDI) for --gpu";
    };
    service.enable = lib.mkEnableOption "a per-user systemd service that starts nixct on login and keeps it running (disables idle shutdown)";
    service.restartOnSwitch = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether `nixos-rebuild switch` may restart the container service when
        the built container changes.

        Off by default, because a restart is not an upgrade-in-place: it tears
        the container down and takes every live `nixct develop` session with
        it, along with whatever those sessions were running. The rootfs is
        baked at build time, so there is no way to swap it under a running
        container - the new version applies the next time the service starts
        (a fresh login, or `systemctl --user restart nixct` when nothing is
        running). Until then the old container keeps serving, unharmed by the
        rebuild.
      '';
    };
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Extra packages available inside the nixct develop-session environment.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      description = "The built nixct package (binary `nixct`). Defaults to one built from the options above.";
      default = (mkNixct {
        inherit (cfg) name packages;
        idleTimeout = if cfg.service.enable then 0 else cfg.idleTimeoutSeconds;
        gpuHasToolkit = cfg.gpu.hostHasToolkit;
      }).run;
      defaultText = lib.literalExpression "mkNixct { ... }.run";
    };
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    systemd.user.services.nixct = lib.mkIf cfg.service.enable {
      description = "nixct dev container";
      wantedBy = [ "default.target" ];
      # Emits X-RestartIfChanged=false, which makes switch-to-configuration
      # skip this unit instead of stop/start-ing it. See the option.
      restartIfChanged = cfg.service.restartOnSwitch;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cfg.package}/bin/nixct up" + lib.optionalString cfg.gpu.enable " --gpu --opengl";
        # --force: stopping the unit is an explicit act, so it should not be
        # blocked by the live-session guard that protects against a stray
        # `nixct down` on the command line.
        ExecStop  = "${cfg.package}/bin/nixct down --force";
      };
    };
  };
}
