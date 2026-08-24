# The container that owns a network namespace, shared by the dev container and
# by prisons.
#
# Both need the same thing: a container that holds a netns, does nothing, and
# can be policed from the host with nftables loaded into it from outside. It
# was written twice -- net-gateway.nix running `coreutils sleep infinity` with
# the whole host store bind-mounted in, and prison's infra-net -- so this is
# the one definition.
#
# It runs catatonit in pause mode. catatonit is statically linked, so the
# rootfs carries an empty /pause and the binary is bind-mounted onto it: crun
# can mount a file onto an existing file in a read-only rootfs, where mounting
# a store path fails because it would have to create the mount point first
# ("mkdir /nix/store/...: Permission denied"). That is why /nix/store is not
# mounted here at all -- the namespace owner needs no store, no libc and no
# coreutils, and gets none.
#
# Deliberately not a NixOS system, and deliberately not a podman pod: a pod's
# infra container comes from podman's image machinery, and whether that pulls
# an OCI image is decided by infra_image in the host's containers.conf rather
# than by anything declared here.

{ pkgs
, lib ? pkgs.lib
, name ? "net-owner"
}:

rec {
  # The binary, on the host. Bind-mounted onto `path` below.
  binary = "${pkgs.catatonit}/bin/catatonit";

  # Where it appears inside the container, and therefore argv[0].
  path = "/pause";

  # Pause mode: reap and forward signals, do nothing else.
  command = [ path "-P" ];

  rootfs = pkgs.runCommand "${name}-rootfs" { } ''
    mkdir -p $out/{proc,sys,dev,tmp,run,etc,var/tmp}

    # podman bind-mounts over each of these, so they have to exist first; a
    # store rootfs is read-only and cannot create them itself. /var/tmp is
    # here because --read-only-tmpfs defaults on and mounts /run, /tmp and
    # /var/tmp, and crun fails before startup if the mount point is missing.
    touch $out/etc/{hostname,hosts,resolv.conf}
    ln -s /proc/mounts $out/etc/mtab

    # podman writes this into the rootfs for a --rootfs container rather than
    # creating it, so a read-only lower has to provide it.
    touch $out/run/.containerenv

    # The mount point for the pause binary. An empty file, because a bind
    # mount needs the target to exist and this filesystem is read-only.
    touch $out${path}

    # Deliberately absent: /bin, /sbin, /usr, /lib, /nix. There is nothing in
    # here to execute except the one static binary mounted over /pause.
  '';
}
