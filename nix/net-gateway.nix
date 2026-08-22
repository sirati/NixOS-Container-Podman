# Rootfs for the network-gateway container.
#
# It owns the network namespace and does nothing else: the dev container
# joins that namespace with --network=container:<gw>, so it has no namespace
# of its own to reconfigure, and the filtering ruleset is loaded into the
# namespace by the HOST from outside both containers. Neither container
# polices itself.
#
# Deliberately not a NixOS system: it runs one `sleep`, so a second init, a
# second journal and a second set of units would buy nothing. What podman
# needs from a rootfs is the handful of paths it bind-mounts over, and that
# is all this provides. The command is a full store path, so there is no
# $PATH for it to be missing from.
{ pkgs }:

pkgs.runCommand "nixct-net-gateway-rootfs" { } ''
  mkdir -p $out/{proc,sys,dev,tmp,run,etc,nix/store}
  # podman bind-mounts over each of these, so they have to exist first; a
  # store rootfs is read-only, so it cannot create them itself.
  touch $out/etc/{hostname,hosts,resolv.conf}
  ln -s /proc/mounts $out/etc/mtab
  # podman writes these into the rootfs for a --rootfs container rather
  # than creating them, so a read-only store layer has to provide them.
  touch $out/run/.containerenv
''
