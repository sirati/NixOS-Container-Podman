# NixOS module factory for the nixct dev container. Imported with the
# flake's `mkNixct` builder and exposes `programs.nixct`: it installs the
# `nixct` binary (host-daemon, develop-only) system-wide and can run a
# per-user systemd service that keeps the container up across the session
# (which owns the lifecycle, so idle shutdown is disabled in that mode).
{ mkNixct }:
{ config, lib, pkgs, ... }:
let
  cfg = config.programs.nixct;

  # Rootless podman shells out to the SETUID newuidmap/newgidmap to apply a
  # multi-id mapping. Two things go wrong from a user service at boot:
  # /run/wrappers/bin is not on a unit PATH, and the system unit that
  # populates it may not have run yet when the user manager starts us. A
  # user unit cannot order itself after a system unit, so wait for the
  # wrapper instead of failing the container start outright - otherwise the
  # container is simply absent after a reboot, with
  #   Error: command required for rootless mode with multiple IDs:
  #          exec: "newuidmap": executable file not found in $PATH
  # buried in the user journal.
  waitForWrappers = pkgs.writeShellScript "nixct-wait-for-wrappers" ''
    for _ in $(seq 1 60); do
      [ -x /run/wrappers/bin/newuidmap ] && exit 0
      sleep 1
    done
    echo "nixct: /run/wrappers/bin/newuidmap never appeared" >&2
    exit 1
  '';
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
      # Rootless podman needs the setuid newuidmap/newgidmap from
      # /run/wrappers/bin, which is not on a systemd unit PATH by default;
      # without it `up` fails with status 125 and the container never starts.
      path = [ "/run/wrappers" "/run/current-system/sw" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStartPre = "${waitForWrappers}";
        ExecStart = "${cfg.package}/bin/nixct up" + lib.optionalString cfg.gpu.enable " --gpu --opengl";
        # --force: stopping the unit is an explicit act, so it should not be
        # blocked by the live-session guard that protects against a stray
        # `nixct down` on the command line.
        ExecStop  = "${cfg.package}/bin/nixct down --force";
      };
    };
  };
}
