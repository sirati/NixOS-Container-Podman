#!/usr/bin/env bash
# Run oneshot prison services: the unit must end with the program, carry
# its exit status, and not remove the container under it. See
# tests/vm/prison-oneshot.nix.
#
# The VM runs in a memory-capped user slice, NDC_VM_SLICE (vm-tests.slice).

# shellcheck source=../lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

echo "== a oneshot prison service is a task =="

if [ ! -w /dev/kvm ]; then
  skip "prison oneshot VM" "no writable /dev/kvm"
  finish; exit
fi
if ! XDG_RUNTIME_DIR="$HOST_XDG_RUNTIME_DIR" systemctl --user show-environment >/dev/null 2>&1; then
  skip "prison oneshot VM" "no systemd user manager to cap the VM's memory"
  finish; exit
fi

if ! driver=$(nix build "${NIX_FLAGS[@]}" --impure --no-link --print-out-paths --expr "$(nix_expr '
    (import (flake.outPath + "/tests/vm/prison-oneshot.nix") {
      inherit pkgs; src = flake.outPath;
    }).driver')" 2>"$SCRATCH/logs/oneshot-build.log"); then
  cp "$SCRATCH/logs/oneshot-build.log" "$OUTFILE"
  fail "the prison oneshot VM test builds"
  finish; exit
fi

vmdir="$SCRATCH/oneshot-vm"
mkdir -p "$vmdir"
log="$SCRATCH/logs/oneshot-vm.log"
scratch_run=$XDG_RUNTIME_DIR
# systemd-run needs the real user bus; the driver gets the scratch dirs back.
if (cd "$vmdir" && XDG_RUNTIME_DIR="$HOST_XDG_RUNTIME_DIR" \
      systemd-run --user --scope --quiet --slice="${NDC_VM_SLICE:-vm-tests.slice}" \
        --unit="ndc-prison-oneshot-$$-$RANDOM" -- \
        env XDG_RUNTIME_DIR="$scratch_run" "$driver/bin/nixos-test-driver" --no-interactive) \
     >"$log" 2>&1; then
  pass "a oneshot unit ends with its program and its exit status"
else
  grep -a -E 'Error|Traceback|AssertionError' "$log" >"$OUTFILE" || tail -25 "$log" >"$OUTFILE"
  fail "a oneshot unit did not follow its program"
fi

finish
