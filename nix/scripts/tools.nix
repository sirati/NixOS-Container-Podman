# Tool resolution for the run script. Two attrsets with the same keys
# but different values:
#
#   mkNixosTools pkgs        - full /nix/store paths (NixOS target)
#   mkPortableTools          - bare names, resolved at runtime via $PATH
#                              (portable tarball target on Debian/Fedora/Arch)
#
# Why full paths on NixOS instead of bare names + runtimeInputs?
# systemd units on NixOS do NOT inherit the parent shell's $PATH (only
# /run/current-system/sw/bin + /run/wrappers/bin by default, often
# sanitized further). Any script body or generated ExecStart= that
# happens to be launched from a unit will silently break if it relies
# on PATH. Baking the full path costs one extra string segment per
# reference and removes that whole failure mode.
#
# For coreutils and util-linux (lots of binaries each), the attr is the
# directory of binaries. Callers compose: ${tools.coreutils}/mkdir,
# ${tools.utilLinux}/mount, etc. Saves a dozen keys.
#
# Portable variant uses bare names because the tarball ships to hosts
# whose podman/crun/etc. live at distro-specific paths we can't predict.
# `check-host-compat` is the safety net that verifies every needed
# binary resolves on PATH before the user starts a container.

{
  mkNixosTools = pkgs: {
    # Interpreter & runtime
    bash          = "${pkgs.bashInteractive}/bin/bash";
    podman        = "${pkgs.podman}/bin/podman";
    crun          = "${pkgs.crun}/bin/crun";

    # Overlay / squashfs userland
    fuseOverlayfs = "${pkgs.fuse-overlayfs}/bin/fuse-overlayfs";
    fusermount3   = "${pkgs.fuse-overlayfs}/bin/fusermount3";
    squashfuse    = "${pkgs.squashfuse}/bin/squashfuse";
    unsquashfs    = "${pkgs.squashfsTools}/bin/unsquashfs";

    # Forwarding / X11 / sockets
    socat         = "${pkgs.socat}/bin/socat";
    xauth         = "${pkgs.xauth}/bin/xauth";
    setfacl       = "${pkgs.acl}/bin/setfacl";
    # Filtering ssh-agent proxy for --agent-allow / --agent-deny. Runs on
    # the HOST: the container only ever sees the socket it serves.
    sshAgentFilter = "${import ../ssh-agent-filter.nix { inherit pkgs; }}/bin/ssh-agent-filter";

    # Standard textproc
    sed           = "${pkgs.gnused}/bin/sed";
    awk           = "${pkgs.gawk}/bin/awk";

    # findutils
    find          = "${pkgs.findutils}/bin/find";
    xargs         = "${pkgs.findutils}/bin/xargs";

    # Directories of binaries — callers do ${tools.coreutils}/mkdir etc.
    coreutils     = "${pkgs.coreutils}/bin";
    utilLinux     = "${pkgs.util-linux}/bin";
  };

  mkPortableTools = {
    bash          = "bash";
    podman        = "podman";
    crun          = "crun";

    fuseOverlayfs = "fuse-overlayfs";
    fusermount3   = "fusermount3";
    squashfuse    = "squashfuse";
    unsquashfs    = "unsquashfs";

    socat         = "socat";
    xauth         = "xauth";
    setfacl       = "setfacl";
    sshAgentFilter = "ssh-agent-filter";

    sed           = "sed";
    awk           = "awk";

    find          = "find";
    xargs         = "xargs";

    # Empty string + literal binary name yields the bare name when
    # callers write `${tools.coreutils}/mkdir` -> "/mkdir". To keep the
    # script body identical across variants, the portable tools strip
    # the leading slash via a trailing-no-slash convention: callers
    # should compose with a helper, not raw `${tools.coreutils}/mkdir`.
    #
    # Concretely: run.nix defines a small Nix-level helper
    #   bin = tools: name: if tools.coreutils == ""
    #                     then name
    #                     else "${tools.coreutils}/${name}";
    # and the script body uses `${bin tools "mkdir"}` instead of the
    # raw concat. See nix/scripts/run.nix for usage.
    coreutils     = "";
    utilLinux     = "";
  };
}
