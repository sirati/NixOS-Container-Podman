# The app rootfs: the smallest tree podman accepts, with the host user in it.
#
# A GUI app is not a daemon, so unlike nix/prison/rootfs.nix it needs the
# invoking user to exist (getpwuid, $HOME lookups) and a few files that host
# bind mounts land on. It still has no shell, no coreutils and no /bin: the
# only programs in the container are the ones the store mount exposes.
#
# One tree serves every app of one user, so it is a function of the user only.
{
  pkgs,
  lib ? pkgs.lib,
  user, # { name; uid; gid; group ? "users"; home; }
}:

let
  group = user.group or "users";
  uid = toString user.uid;
  gid = toString user.gid;
  safe = s: !(lib.hasInfix ":" s || lib.hasInfix "\n" s || lib.hasInfix " " s);
in
assert lib.assertMsg (safe user.name && safe group && lib.hasPrefix "/" user.home && safe user.home)
  "app rootfs: user and group names and the home directory must not contain `:`, spaces or newlines";
pkgs.runCommand "app-rootfs-${user.name}" { } ''
  # Every directory something is bound onto outside a tmpfs has to exist
  # here: the tree is owned by the store, so the container cannot make one.
  mkdir -p $out/{proc,sys,dev,tmp,run,etc,nix/store,var/tmp,usr/share/fonts,usr/share/icons,etc/alsa/conf.d}
  mkdir -p "$out/run/user/${uid}" "$out${user.home}"

  # podman bind-mounts over these, so they have to exist first.
  touch $out/etc/{hostname,hosts,resolv.conf,localtime,machine-id}
  ln -s /proc/mounts $out/etc/mtab
  touch $out/run/.containerenv

  cat > $out/etc/passwd <<'PASSWD'
  root:x:0:0:root:/nonexistent:/noshell
  ${user.name}:x:${uid}:${gid}:${user.name}:${user.home}:/noshell
  PASSWD
  cat > $out/etc/group <<'GROUP'
  root:x:0:
  ${group}:x:${gid}:
  GROUP

  printf 'passwd: files\ngroup: files\nshadow: files\nhosts: files dns\n' > $out/etc/nsswitch.conf
  chmod 0555 $out/etc
''
