# The prison rootfs: the smallest tree podman will accept, and nothing else.
#
# There is no shell here, no coreutils, no busybox, no package manager. The
# only executable content a process in the prison can reach is whatever the
# store view exposes -- which is the closure of the services and nothing more.
# An attacker who achieves code execution inside a service therefore has no
# second binary to run: not because a binary was removed from $PATH, but
# because it was never in this filesystem and is not in the store view either.
#
# Everything writable is a tmpfs mounted noexec,nosuid,nodev by the run
# script, so a payload cannot be written and then executed either. That pair
# -- nothing to exec, nowhere to write something execable -- is the property
# this rootfs exists to provide.

{ pkgs
, lib ? pkgs.lib
, name
, users            # [ { name; uid; gid; } ] -- the service accounts
, groups ? [ ]     # [ { name; gid; } ]; derived from users when empty
, extraDirs ? [ ]  # mount points the caller needs to exist before bind time
  # [ { path; source; } ] copied into the rootfs at build time. Used for the
  # namespace owner's pause binary: bind-mounting a store path into a
  # read-only rootfs cannot work, because crun has to create the mount point
  # first and fails with "mkdir /nix/store/...: Permission denied". A static
  # binary copied in needs no mount and no /nix/store at all.
, embed ? [ ]
}:

let
  inherit (lib) concatMapStrings concatMapStringsSep unique;

  allGroups =
    if groups != [ ] then groups
    else unique (map (u: { name = u.name; gid = u.gid; }) users);

  # A container root account exists but is not what services run as. It is
  # here because podman writes files as uid 0 during setup and because
  # getpwuid(0) failing makes some libraries behave oddly -- not because
  # anything is meant to use it.
  passwd = ''
    root:x:0:0:container root:/nonexistent:/noshell
  '' + concatMapStrings
    (u: "${u.name}:x:${toString u.uid}:${toString u.gid}:${u.name} service account:/nonexistent:/noshell\n")
    users;

  group = ''
    root:x:0:
  '' + concatMapStrings (g: "${g.name}:x:${toString g.gid}:\n") allGroups;

  # The login shell is a path that does not exist. Nothing should ever call
  # it; if something does, it fails loudly rather than landing in a shell.
  nsswitch = ''
    passwd:    files
    group:     files
    shadow:    files
    hosts:     files dns
    services:  files
    protocols: files
  '';
in
pkgs.runCommand "prison-rootfs-${name}"
  {
    passthru = { inherit users allGroups; };
  } ''
  set -euo pipefail
  # /var/tmp is here because podman's --read-only-tmpfs defaults on and
  # mounts a tmpfs at /run, /tmp AND /var/tmp; a read-only rootfs cannot
  # create the mount point itself, and crun fails with "mkdir `/var/tmp`:
  # Permission denied" before the service ever starts.
  mkdir -p $out/{proc,sys,dev,tmp,run,etc,nix/store,var/empty,var/tmp}
  ${concatMapStringsSep "\n" (d: "mkdir -p $out${d}") extraDirs}
  ${concatMapStringsSep "\n" (e: ''
    install -Dm0555 ${e.source} "$out${e.path}"
  '') embed}

  # podman bind-mounts over each of these, so they have to exist first; a
  # store rootfs is read-only and cannot create them itself.
  touch $out/etc/{hostname,hosts,resolv.conf}
  ln -s /proc/mounts $out/etc/mtab

  # podman writes this into the rootfs for a --rootfs container rather than
  # creating it, so a read-only lower has to provide it.
  touch $out/run/.containerenv

  cat > $out/etc/passwd <<'PASSWD'
${passwd}PASSWD
  cat > $out/etc/group <<'GROUP'
${group}GROUP
  cat > $out/etc/nsswitch.conf <<'NSS'
${nsswitch}NSS

  # Deliberately absent: /bin, /sbin, /usr, /lib. Their absence is the
  # feature -- there is no path at which a shell could be found even if one
  # were somehow written to disk.
  chmod 0555 $out/etc
''
