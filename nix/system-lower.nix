# system-lower: a COMPLETE, runnable container rootfs whose store content
# is supplied by a SEPARATE layer.
#
# This is the "lower" half of the orthogonal-layer restructuring. It is a
# full FHS skeleton (the same one staged by flake.nix's `rootfs` runCommand
# and by nix/rootfs-folder.nix): /init -> ${toplevel}/init, sbin/init,
# static /etc (os-release, machine-id, mtab), and the closure manifest
# copied to /nix-path-registration.
#
# Two things differ from the historical rootfs builders, on purpose:
#
#   1. /nix/store is an EMPTY directory - a bare mountpoint. The closure is
#      NOT copied or symlinked here. The store content is layered in
#      separately: either MATERIALIZED from `nixStoreLower` by a packaging
#      step (self-contained / portable builds), or SERVED by the runtime
#      FUSE mount (host-nix-store mode). Keeping the store empty here makes
#      this lower layer tiny and lets the same skeleton compose with either
#      store-provisioning strategy.
#
#   2. /nix/var ships a PRE-BUILT Nix database with the whole closure
#      already registered as valid. Because the db is baked at derivation
#      time, there is NO first-boot `load-db` (no boot.postBootCommands
#      registration step needed): the container boots with a populated,
#      consistent store database from the very first start.
#
# GC pinning: this derivation REFERENCES `nixStoreLower` (its path is
# written into $out/nix/.store-lower) so Nix records it as a runtime
# reference and keeps the whole closure alive through this layer. The
# passthru re-exports toplevel / closure / nixStoreLower for composition.
#
# Input shape (matches the sibling nix/nix-store-lower.nix contract):
#   { pkgs, toplevel, closure, nixStoreLower }: drv
# where nixStoreLower is a derivation whose $out/nix/store/<basename> are
# symlinks to each closure path (passthru.closure), and `closure` is a
# pkgs.closureInfo result (providing ./registration and ./store-paths).

{ pkgs, toplevel, closure, nixStoreLower }:

pkgs.runCommand "nix-container-system-lower"
  {
    nativeBuildInputs = [ pkgs.coreutils pkgs.nix pkgs.sqlite ];
    passthru = { inherit toplevel closure nixStoreLower; };
  }
  ''
    set -euo pipefail

    mkdir -p $out
    cd $out

    # --- FHS skeleton (mirrors flake.nix rootfs / rootfs-folder.nix) -------
    mkdir -p \
      bin boot dev etc home mnt \
      nix/store nix/var \
      opt proc root run sbin srv \
      sys tmp usr var

    ln -s ${toplevel}/init init
    ln -s /init sbin/init
    ln -s ${toplevel}/etc/os-release etc/os-release
    : > etc/machine-id
    ln -s /proc/mounts etc/mtab

    cp ${closure}/registration nix-path-registration

    # /nix/store stays EMPTY: it is just a mountpoint. Store content is
    # layered in separately (materialized from nixStoreLower, or FUSE-served
    # at runtime).

    # --- Pre-built Nix database (no first-boot load-db) --------------------
    # Register the closure into a sqlite db rooted at $out/nix/var/nix.
    # nix-store --load-db reads the registration manifest on stdin. It does
    # NOT require the referenced store paths to physically exist (it only
    # records validity/refs/deriver metadata), so an empty /nix/store is
    # fine here. The store paths in the registration already match the real
    # store prefix (/nix/store), so the baked db lists the correct paths.
    mkdir -p $out/nix/var/nix
    export NIX_STATE_DIR=$out/nix/var/nix
    export HOME=$TMPDIR
    ${pkgs.nix}/bin/nix-store --load-db < ${closure}/registration

    # Verify the db was produced and lists the closure paths.
    if [ ! -f "$out/nix/var/nix/db/db.sqlite" ]; then
      echo "system-lower: ERROR db.sqlite was not created" >&2
      exit 1
    fi
    dbcount=$(${pkgs.sqlite}/bin/sqlite3 "$out/nix/var/nix/db/db.sqlite" \
      'SELECT count(*) FROM ValidPaths;')
    wantcount=$(wc -l < ${closure}/store-paths)
    echo "system-lower: registered $dbcount valid paths (closure has $wantcount)"
    if [ "$dbcount" -lt 1 ]; then
      echo "system-lower: ERROR no valid paths registered in db" >&2
      exit 1
    fi

    # nix-store --load-db side-creates the GC reserved-space block (~8 MiB)
    # and a big-lock in the db dir. Neither belongs in an immutable lower
    # layer; the runtime /nix/var (overlay upper or writable rootfs) recreates
    # them on demand. Drop them so the layer stays small.
    rm -f $out/nix/var/nix/db/reserved $out/nix/var/nix/db/big-lock

    # --- GC reference to nixStoreLower -------------------------------------
    # A passthru alone does NOT create a build-output reference. Writing the
    # path into a file in $out makes Nix record nixStoreLower as a runtime
    # reference of this derivation, keeping the closure GC-alive through the
    # store-lower layer.
    echo ${nixStoreLower} > $out/nix/.store-lower
  ''
