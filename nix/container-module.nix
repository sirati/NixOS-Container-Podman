{ config, lib, pkgs, modulesPath, ... }:

# Framework module - imported by mkContainer for every container build.
# Cribs the load-bearing tricks from Anillc/podman-nixos (the only NixOS-in-
# podman project that actually works): kill specialfs, defuse the wrappers
# tmpfs, postBootCommands for nix-path-registration.

{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
  ];

  boot = {
    isContainer = true;
    # Required so in-container `nixos-rebuild switch` / `switch-to-configuration`
    # can rewrite /sbin/init -> new toplevel/init.
    loader.initScript.enable = true;

    # Register the closure into the in-container Nix DB on first boot. This is
    # exactly the Anillc snippet - simpler than a custom systemd service and
    # runs at the right point in the boot sequence.
    postBootCommands = ''
      if [ -f /nix-path-registration ]; then
        ${config.nix.package}/bin/nix-store --load-db < /nix-path-registration \
          && rm /nix-path-registration
      fi
      ${config.nix.package}/bin/nix-env \
        -p /nix/var/nix/profiles/system --set /run/current-system
    '';
  };

  # The most important line in this file. NixOS's stage-2 init normally tries
  # to mount /proc, /sys, /dev/pts itself - podman/crun has already set those
  # up, and a second mount() fails (or worse, shadows them). Drop the script.
  system.activationScripts.specialfs = lib.mkForce "";

  # /sys/kernel/{debug,tracing} need privileges we don't have in a rootless
  # container; /run/wrappers normally lives on its own tmpfs/overlay which
  # also fails.
  systemd.mounts = [
    { enable = false; where = "/sys/kernel/debug"; }
    { enable = false; where = "/sys/kernel/tracing"; }
    { enable = false; where = "/run/wrappers"; }
  ];

  # Override the wrappers service: instead of waiting for /run/wrappers as a
  # mount unit, just mkdir it and write into the regular tmpfs /run.
  systemd.services.suid-sgid-wrappers = {
    unitConfig.RequiresMountsFor = lib.mkForce [ "/nix/store" ];
    preStart = "mkdir -p /run/wrappers";
  };

  # Container runtime handles networking; don't run dhcpcd by default.
  networking.useDHCP = lib.mkDefault false;

  # Default rlimits inside the container. Without these, services inherit
  # systemd's hard-coded conservative defaults (NOFILE=1024, NPROC=512 in
  # some user-ns configurations) and large apps (Firefox, ML toolkits)
  # hit EAGAIN / "Resource temporarily unavailable" when spawning threads
  # or opening many fds. Match a typical Linux desktop.
  systemd.settings.Manager = {
    DefaultLimitNOFILE = "1024:524288";
    DefaultLimitNPROC = "65535";
    DefaultLimitMEMLOCK = "infinity";
  };

  # NixOS' default ping_group_range is "0 2147483647" - on a rootless
  # container's user-ns the max valid gid is bounded by the subgid range,
  # and the kernel rejects sysctl values exceeding it with EINVAL. Use
  # "0 65535" which is the full user-ns gid range. Permits ping for all
  # gids that exist in the container.
  boot.kernel.sysctl."net.ipv4.ping_group_range" = lib.mkForce "0 65535";

  nix.settings = {
    experimental-features = lib.mkDefault [ "nix-command" "flakes" ];
    # @wheel members (e.g. the dev user from configuration.nix) become
    # trusted-users so they can flip substituters/sandboxing per-invocation.
    # Not lib.mkDefault, because NixOS' default ("root" only) overrides it.
    trusted-users = [ "root" "@wheel" ];
    # The nix sandbox uses mount-namespacing and clone()s in ways that
    # routinely fail in containers without extra caps.
    sandbox = lib.mkDefault false;
  };

  # No nix-channels - everything is pinned through flakes. Pre-populate
  # NIX_PATH with the same nixpkgs source the container is built from, so
  # `nix-shell -p` and `<nixpkgs>` work without producing the
  # "/nix/var/nix/profiles/per-user/root/channels does not exist" warning.
  nix.channel.enable = false;
  nix.nixPath = lib.mkForce [ "nixpkgs=${pkgs.path}" ];

  system.stateVersion = lib.mkDefault "25.11";
}
