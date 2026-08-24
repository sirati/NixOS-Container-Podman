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

  # The container's store must be its own. The probe has to be a path that
  # is on the host and genuinely not in the container's closure: nixpkgs is
  # NOT such a path, because NixOS pins it into every system closure through
  # nix.registry and nix.nixPath. This repo's own source is -- the container
  # was built from it, but a build input is not a runtime dependency.
  local hostonly; hostonly=$(nix_eval 'flake.outPath')
  check "the host store is not visible inside" \
    ct exec -- /run/current-system/sw/bin/test '!' -e "$hostonly"

  # The regression that made this container look fine and be broken: its
  # nix-daemon failed with 214/SETSCHEDULER until CPUSchedulingPolicy and
  # the IO scheduling settings were cleared. It is socket-activated, so
  # `is-active` says inactive until something connects -- which is exactly
  # why the check has to connect first and only then look at the unit.
  check "the in-container nix reaches its daemon" \
    ct exec -- /run/current-system/sw/bin/nix --extra-experimental-features nix-command store ping
  check_out "and the daemon unit actually started" "active" \
    ct exec -- /run/current-system/sw/bin/systemctl is-active nix-daemon
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
