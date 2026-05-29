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
    package = lib.mkOption {
      type = lib.types.package;
      description = "The built nixct package (binary `nixct`). Defaults to one built from the options above.";
      default = (mkNixct {
        inherit (cfg) name;
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
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${cfg.package}/bin/nixct up" + lib.optionalString cfg.gpu.enable " --gpu --opengl";
        ExecStop  = "${cfg.package}/bin/nixct down";
      };
    };
  };
}
