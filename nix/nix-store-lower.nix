# nix-store-lower: the "/nix/store" symlink farm.
#
# Builds a /nix/store-shaped tree where, for every path in the closure,
# $out/nix/store/<basename> is a SYMLINK pointing at the real host store
# path. Because the symlink TARGETS are real store paths, $out references
# the entire closure, so a Nix GC root on $out keeps the closure alive --
# this is the GC-pinning reference used by host-nix-store mode.
#
# The FUSE layer (nix-store-shared-fuse) uses this tree as its bind_target,
# realizing each symlink into real content at runtime.
#
# Contract: { pkgs, toplevel, closure } -> drv
#   closure = pkgs.closureInfo { rootPaths = [ toplevel ]; };
#   (provides ${closure}/store-paths, a newline-separated list of store paths)
{ pkgs, toplevel, closure }:

pkgs.runCommand "nix-store-lower"
  {
    passthru = { inherit toplevel closure; };
  } ''
  mkdir -p $out/nix/store

  # Symlink each closure path into $out/nix/store. Each p is
  # /nix/store/<basename>, so "$out$p" lands at $out/nix/store/<basename>.
  # The symlink targets are real store paths, so $out references the whole
  # closure and acts as a GC-pinning root.
  while IFS= read -r p; do
    ln -s "$p" "$out$p"
  done < ${closure}/store-paths
''
