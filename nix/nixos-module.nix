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
    service.upgradeOnSwitch = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether `nixos-rebuild switch` should upgrade the running container
        in place instead of leaving it on the old system.

        `nixct` containers take their whole /nix from the host daemon, so a
        container system built during the rebuild is already realised inside
        the container and can simply be activated - the same thing
        nixos-rebuild does on a real machine. The switch therefore reloads
        this unit, which runs `nixct switch`: the container keeps running,
        every develop session in it survives (they live in transient scopes,
        which activation does not touch), and the new configuration takes
        effect immediately.

        Turn this off to leave a running container strictly untouched by
        rebuilds; the new system then applies at its next start.
      '';
    };
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
      # On `nixos-rebuild switch`, RELOAD instead of restarting: the reload
      # activates the freshly built container system inside the RUNNING
      # container (see `nixct switch`), so a rebuild upgrades it without
      # dropping it or the develop sessions in it. Emits X-ReloadIfChanged,
      # which switch-to-configuration honours ahead of the restart logic.
      #
      # Only host-nix-daemon containers can do this - anything else has its
      # system baked into an immutable rootfs - so for those fall back to
      # X-RestartIfChanged=false, i.e. leave the running container alone and
      # let the new build apply at the next start.
      reloadIfChanged = cfg.service.upgradeOnSwitch;
      restartIfChanged = cfg.service.restartOnSwitch;
      # Rootless podman needs the setuid newuidmap/newgidmap from
      # /run/wrappers/bin, which is not on a systemd unit PATH by default;
      # without it `up` fails with status 125 and the container never starts.
      path = [ "/run/wrappers" "/run/current-system/sw" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStartPre = "${waitForWrappers}";
        # What the reload above runs. Activates the new system inside the
        # live container; a no-op when it is not running.
        ExecReload = "${cfg.package}/bin/nixct switch";
        ExecStart = "${cfg.package}/bin/nixct up" + lib.optionalString cfg.gpu.enable " --gpu --opengl";
        # --force: stopping the unit is an explicit act, so it should not be
        # blocked by the live-session guard that protects against a stray
        # `nixct down` on the command line.
        ExecStop  = "${cfg.package}/bin/nixct down --force";
      };
    };
  };
}
