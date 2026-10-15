#!/usr/bin/env bash
# Replay a switch window that leaves a prison store view serving the old
# closure, and require the next service start to replace the view instead
# of running against it. See tests/vm/prison-store-freshness.nix.
#
# The VM runs in a memory-capped user slice, NDC_VM_SLICE (vm-tests.slice).

# shellcheck source=../lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

echo "== a stale prison store view heals itself =="

if [ ! -w /dev/kvm ]; then
  skip "store freshness VM" "no writable /dev/kvm"
  finish; exit
fi
if ! XDG_RUNTIME_DIR="$HOST_XDG_RUNTIME_DIR" systemctl --user show-environment >/dev/null 2>&1; then
  skip "store freshness VM" "no systemd user manager to cap the VM's memory"
  finish; exit
fi

if ! driver=$(nix build "${NIX_FLAGS[@]}" --impure --no-link --print-out-paths --expr "$(nix_expr '
    (import (flake.outPath + "/tests/vm/prison-store-freshness.nix") {
      inherit pkgs; src = flake.outPath;
    }).driver')" 2>"$SCRATCH/logs/freshness-build.log"); then
  cp "$SCRATCH/logs/freshness-build.log" "$OUTFILE"
  fail "the store freshness VM test builds"
  finish; exit
fi

vmdir="$SCRATCH/freshness-vm"
mkdir -p "$vmdir"
log="$SCRATCH/logs/freshness-vm.log"
scratch_run=$XDG_RUNTIME_DIR
# systemd-run needs the real user bus; the driver gets the scratch dirs back.
if (cd "$vmdir" && XDG_RUNTIME_DIR="$HOST_XDG_RUNTIME_DIR" \
      systemd-run --user --scope --quiet --slice="${NDC_VM_SLICE:-vm-tests.slice}" \
        --unit="ndc-prison-freshness-$$-$RANDOM" -- \
        env XDG_RUNTIME_DIR="$scratch_run" "$driver/bin/nixos-test-driver" --no-interactive) \
     >"$log" 2>&1; then
  pass "a view left on the old closure is replaced on the next service start"
else
  grep -a -E 'Error|Traceback|AssertionError' "$log" >"$OUTFILE" || tail -25 "$log" >"$OUTFILE"
  fail "a service ran against a stale store view"
fi

finish
