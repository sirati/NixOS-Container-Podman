#!/usr/bin/env bash
#
# The host-daemon container: /nix is bind-mounted read-only from the host
# and every build is delegated to the host's nix-daemon over its socket.
# No daemon inside, no nixbld users, and the store is the host's.

# shellcheck source=../lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

ct_new hd testdaemon.run

check "up" ct up

nixpkgs=$(nix_eval 'flake.inputs.nixpkgs.outPath')
check "the host store IS visible inside" \
  ct exec -- /run/current-system/sw/bin/test -e "$nixpkgs"

# The mount is read-only: a container that can write to the host store can
# rewrite anything the host runs.
check_fails "the host store is read-only inside" \
  ct exec -- /run/current-system/sw/bin/touch /nix/store/nixct-test-write-probe

# No daemon of its own -- that is what "host daemon" means, and a stray
# in-container daemon would quietly take over the builds.
check_fails "there is no in-container nix-daemon" \
  ct exec -- /run/current-system/sw/bin/systemctl is-active nix-daemon

# The end-to-end one: a real dev shell, built through the host daemon from
# the nixpkgs this repo is locked to, entered non-interactively, printing a
# variable that only exists inside it.
proj=$(mk_project_flake "$SCRATCH/proj-flake")
# shellcheck disable=SC2016 # the variable is expanded in the container, not here
check_out "develop --command reaches a real dev shell" "devshell-reached" \
  timeout 900 env NAME="$CT_NAME" STATE_DIR="$CT_STATE" \
    "$CT_RUN" develop --command 'echo "marker=$NIXCT_TEST_MARKER"' "$proj"

ct_core_checks

# A portable tarball cannot be self-contained here, and must say so.
check_err "portable is the not-implemented stub for a host-daemon container" \
  "not implemented" \
  nix build "${NIX_FLAGS[@]}" --no-link "$REPO#legacyPackages.x86_64-linux.testdaemon.portable"

finish
