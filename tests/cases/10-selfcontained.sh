#!/usr/bin/env bash
#
# The self-contained container: its /nix/store is baked into the rootfs and
# served by its own fuse-overlayfs, with its own nix-daemon inside. Nothing
# of the host's store is visible, which is the whole point and also the
# thing that is easy to break without noticing.

# shellcheck source=../lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

ct_new sc testcontainer.run

ct_core_checks_with_store() {
  check "up" ct up

  # The container's store must be its own. A path that exists on the host
  # but is not in the container's closure -- the nixpkgs source this repo
  # is locked to -- is the cheapest proof that nothing of the host leaked
  # in, and it is a path `develop` would silently make work if the store
  # were shared.
  local nixpkgs; nixpkgs=$(nix_eval 'flake.inputs.nixpkgs.outPath')
  check "the host store is not visible inside" \
    ct exec -- /run/current-system/sw/bin/test '!' -e "$nixpkgs"

  # Its own daemon has to be up: this is the container whose nix-daemon
  # failed with 214/SETSCHEDULER until CPUSchedulingPolicy and the IO
  # scheduling settings were cleared, and a container whose daemon is dead
  # still starts, still execs, and only fails once something builds.
  check_out "the in-container nix-daemon is running" "active" \
    ct exec -- /run/current-system/sw/bin/systemctl is-active nix-daemon
  check_out "the in-container nix can talk to its daemon" "/nix/store" \
    ct exec -- /run/current-system/sw/bin/nix --extra-experimental-features nix-command \
      eval --raw --expr 'builtins.storeDir' --impure
}

ct_core_checks_with_store

# Then the shared lifecycle, from a container that is already up. `up` is
# idempotent, so running it again is itself a check.
ct_core_checks

# A portable tarball is only meaningful for a self-contained container, so
# this is the variant where it must NOT be the not-implemented stub.
check_fails "portable is a real tarball here, not the not-implemented stub" \
  bash -c "nix eval ${NIX_FLAGS[*]} --raw '$REPO#legacyPackages.x86_64-linux.testcontainer.portable.name' | grep -q not-implemented"

finish
