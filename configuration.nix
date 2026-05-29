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

  environment.systemPackages = with pkgs; [
    bashInteractive
    bindfs        # uid-remap fuse mount used by /home/dev-<id>
    coreutils
    curl
    firefox       # wayland / x11 forwarding smoke test
    git
    hello         # smoke-test target for `nix run nixpkgs#hello`
    socat         # used by the inner watchdog + socket-proxy units
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

  # Per-develop-session watchdog. Spawned by the develop subcommand once per
  # session-scope; blocks until session-<mount_id>.scope becomes inactive
  # (i.e. every process the session-user started, including reparented
  # daemons, has exited), then unmounts the per-session bindfs mounts,
  # deletes the session user, and notifies the outer host watchdog so it
  # can drop the host-side bind.
  environment.etc."nix-dev-container/inner-watchdog.sh" = {
    mode = "0555";
    text = ''
      #!${pkgs.bashInteractive}/bin/bash
      # args: <mount_id> <session_user>
      set -u
      PATH=/run/current-system/sw/bin:/run/wrappers/bin

      mount_id=$1
      session_user=$2
      scope="session-''${mount_id}.scope"
      home_dir="/develop-home/''${session_user}"
      socket_dir="/run/sockets/''${mount_id}"

      # Stage 1: wait for the scope to actually come into existence.
      # The watchdog is started before the develop subcommand creates the
      # scope, so without this wait `is-active` would return inactive
      # immediately and we'd tear down before the user ever got a shell.
      for _ in $(seq 1 120); do
        state=$(systemctl is-active "$scope" 2>/dev/null || true)
        case "$state" in active|activating|reloading) break ;; esac
        sleep 0.5
      done

      # Stage 2: wait for the scope to become inactive (= every process,
      # including reparented daemons, has exited).
      while systemctl is-active --quiet "$scope" 2>/dev/null; do
        sleep 2
      done
      # Settle period in case systemd is mid-tear-down.
      sleep 1

      if mountpoint -q -- "$home_dir"; then
        fusermount3 -u -- "$home_dir" 2>/dev/null \
          || umount -- "$home_dir" 2>/dev/null || true
      fi
      rmdir -- "$home_dir" 2>/dev/null || true

      # Forwarded-socket proxies (socat units) are killed by their
      # BindsTo=$scope; just clean up the leftover socket files.
      rm -rf -- "$socket_dir" 2>/dev/null || true

      userdel -- "$session_user" 2>/dev/null || true
      groupdel -- "$session_user" 2>/dev/null || true

      # Notify the per-session host watchdog. The socket path is bound to
      # this mount_id, so we don't pass it as data - the outer watchdog
      # knows by virtue of WHICH socket received the connection what to
      # tear down. A compromised in-container watchdog can only ask for
      # its OWN session's teardown.
      sock="/var/host-watchdog/''${mount_id}/sock"
      if [ -S "$sock" ]; then
        : | socat - "UNIX-CONNECT:$sock" 2>/dev/null || true
      fi
    '';
  };


  # Container directory layout for develop sessions:
  #   /hostmnts                - bind target for host paths. Owned by the
  #                              container root (= host sirati under the
  #                              default rootless mapping); mode 0700 on the
  #                              host source so session users in the
  #                              container can never list / enumerate it.
  #                              They only see /develop-home/<user>, the
  #                              FUSE remap of their own subpath.
  #   /develop-home/<user>     - per-session bindfs view of /hostmnts/<id>
  #                              with the session-user uid mapped in.
  #   /run/agents/<id>         - per-session bindfs view of an agent-socket
  #                              dir (if -A was passed).
  #
  # /hostmnts itself is created by the run script as a 0700 dir on the host
  # before bind-mounting; we don't redeclare it via tmpfiles because that
  # would chmod the bind source on every boot.
  #
  # /develop-home and /run/agents are 0711: traversal-only for non-root.
  # That lets a session user `cd /develop-home/<own_user>` (because they
  # only need execute on the parent) but blocks `ls /develop-home` (no
  # read), so they can't enumerate other sessions' usernames. The bindfs
  # mounts they each get below additionally strip group/other perms, so
  # even if a session user guesses another session's username they can't
  # read into the directory.
  systemd.tmpfiles.rules = [
    "d /develop-home 0711 root root -"
    "d /run/sockets  0711 root root -"
  ];

  networking.hostName = lib.mkDefault "nixct";
}
