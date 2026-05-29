# Example NixOS configuration for the container. Edit / replace freely;
# `lib.mkContainer { modules = [ ./this-file ]; shellUser = "dev"; }` in the
# flake will combine it with the framework module (nix/container-module.nix)
# and build a rootfs.

{ config, lib, pkgs, ... }:

{
  # uid 1000 is fixed so podman's --userns=keep-id maps host's invoking
  # user (also typically uid 1000) to this dev user, leaving bind-mounted
  # host paths editable by the host user without `podman unshare chown`.
  users.users.dev = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [ "wheel" ];
    initialPassword = "dev";
    home = "/home/dev";
    shell = pkgs.bashInteractive;
  };

  users.users.root.initialHashedPassword = lib.mkOverride 150 "";

  security.sudo.wheelNeedsPassword = false;

  # bindfs / socat / fuse3 are provided by the framework module (they're
  # load-bearing for the develop subcommand in any container).
  environment.systemPackages = with pkgs; [
    bashInteractive
    coreutils
    curl
    firefox       # wayland / x11 forwarding smoke test
    git
    hello         # smoke-test target for `nix run nixpkgs#hello`
    vim
  ];
  # xauth is pulled into the closure via shellInit below (direct
  # ${pkgs.xauth}/bin/xauth reference) but intentionally NOT in
  # systemPackages, so the user's PATH isn't polluted. If you want to run
  # xauth interactively, just `nix run nixpkgs#xauth -- ...`.

  # X11 cookie auto-install. The run script sets XCOOKIE + DISPLAY on the
  # exec env when --x11/--x11-untrusted is used; this hook runs at every
  # login-shell start, registers the cookie under the chosen DISPLAY in a
  # per-user XAUTHORITY file under /tmp (so it doesn't pollute the project
  # home), and is a silent no-op when XCOOKIE isn't set.
  environment.shellInit = ''
    if [ -n "''${XCOOKIE:-}" ] && [ -n "''${DISPLAY:-}" ]; then
      export XAUTHORITY="''${XAUTHORITY:-/tmp/.Xauthority-''${UID}}"
      ${pkgs.xauth}/bin/xauth add \
        "$DISPLAY" MIT-MAGIC-COOKIE-1 "$XCOOKIE" 2>/dev/null || true
    fi
    # If the run script up'd the container with --gpu or --opengl (and
    # the host isn't using nvidia-container-toolkit), the host's GPU
    # userland (libcuda.so, libGL.so, dri drivers...) is bind-mounted
    # under one of these paths:
    #   /run/opengl-driver/lib   - NixOS host
    #   /opt/host-graphics-libs  - non-NixOS host (run script binds the
    #                              detected /usr/lib<...> here)
    # Plumb whichever exists into LD_LIBRARY_PATH so PyTorch / CUDA /
    # OpenGL apps' dlopen()s find their libs without per-user fiddling.
    # With nvidia-container-toolkit on the host, the toolkit injects the
    # CUDA libs at the conventional paths; this hook is then a no-op for
    # pure CUDA workloads (though OpenGL still uses these bind paths
    # because the toolkit doesn't ship GL libs).
    for _gpu_libdir in /run/opengl-driver/lib /opt/host-graphics-libs; do
      if [ -d "$_gpu_libdir" ]; then
        export LD_LIBRARY_PATH="$_gpu_libdir''${LD_LIBRARY_PATH:+:''$LD_LIBRARY_PATH}"
      fi
    done
    unset _gpu_libdir
  '';

  # The develop-session watchdog, the /develop-home + /run/sockets tmpfiles,
  # and bindfs/socat/fuse3 now live in the framework module
  # (nix/container-module.nix) so every container supports `develop`.

  networking.hostName = lib.mkDefault "nixct";
}
