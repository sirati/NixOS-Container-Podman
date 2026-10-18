#!/usr/bin/env bash
# Kill a prison's namespace owner: its unit must end, be restarted and
# bring the prison's services back. See tests/vm/prison-owner-death.nix.
#
# The VM runs in a memory-capped user slice, NDC_VM_SLICE (vm-tests.slice).

# shellcheck source=../lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

echo "== a prison whose namespace owner dies is set up again =="

if [ ! -w /dev/kvm ]; then
  skip "prison owner death VM" "no writable /dev/kvm"
  finish; exit
fi
if ! XDG_RUNTIME_DIR="$HOST_XDG_RUNTIME_DIR" systemctl --user show-environment >/dev/null 2>&1; then
  skip "prison owner death VM" "no systemd user manager to cap the VM's memory"
  finish; exit
fi

if ! driver=$(nix build "${NIX_FLAGS[@]}" --impure --no-link --print-out-paths --expr "$(nix_expr '
    (import (flake.outPath + "/tests/vm/prison-owner-death.nix") {
      inherit pkgs; src = flake.outPath;
    }).driver')" 2>"$SCRATCH/logs/owner-death-build.log"); then
  cp "$SCRATCH/logs/owner-death-build.log" "$OUTFILE"
  fail "the prison owner death VM test builds"
  finish; exit
fi

vmdir="$SCRATCH/owner-death-vm"
mkdir -p "$vmdir"
log="$SCRATCH/logs/owner-death-vm.log"
scratch_run=$XDG_RUNTIME_DIR
# systemd-run needs the real user bus; the driver gets the scratch dirs back.
if (cd "$vmdir" && XDG_RUNTIME_DIR="$HOST_XDG_RUNTIME_DIR" \
      systemd-run --user --scope --quiet --slice="${NDC_VM_SLICE:-vm-tests.slice}" \
        --unit="ndc-prison-owner-death-$$-$RANDOM" -- \
        env XDG_RUNTIME_DIR="$scratch_run" "$driver/bin/nixos-test-driver" --no-interactive) \
     >"$log" 2>&1; then
  pass "a dead namespace owner is set up again with its services"
else
  grep -a -E 'Error|Traceback|AssertionError' "$log" >"$OUTFILE" || tail -25 "$log" >"$OUTFILE"
  fail "a dead namespace owner was not set up again"
fi

finish
