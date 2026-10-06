#!/usr/bin/env bash
# Start and stop a prison's generated service unit in a NixOS VM, quiet and
# while PID 1 is busy with a daemon-reload loop, and require every start to
# succeed with the container already running for a dependent unit. See
# tests/vm/prison-readiness.nix.
#
# The VM runs in a memory-capped user slice, NDC_VM_SLICE (vm-tests.slice).

# shellcheck source=../lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

echo "== prison service readiness under PID 1 load =="

if [ ! -w /dev/kvm ]; then
  skip "prison readiness VM" "no writable /dev/kvm"
  finish; exit
fi
if ! XDG_RUNTIME_DIR="$HOST_XDG_RUNTIME_DIR" systemctl --user show-environment >/dev/null 2>&1; then
  skip "prison readiness VM" "no systemd user manager to cap the VM's memory"
  finish; exit
fi

if ! driver=$(nix build "${NIX_FLAGS[@]}" --impure --no-link --print-out-paths --expr "$(nix_expr '
    (import (flake.outPath + "/tests/vm/prison-readiness.nix") {
      inherit pkgs; src = flake.outPath;
    }).driver')" 2>"$SCRATCH/logs/readiness-build.log"); then
  cp "$SCRATCH/logs/readiness-build.log" "$OUTFILE"
  fail "the readiness VM test builds"
  finish; exit
fi

vmdir="$SCRATCH/readiness-vm"
mkdir -p "$vmdir"
log="$SCRATCH/logs/readiness-vm.log"
scratch_run=$XDG_RUNTIME_DIR
# systemd-run needs the real user bus; the driver gets the scratch dirs back.
if (cd "$vmdir" && XDG_RUNTIME_DIR="$HOST_XDG_RUNTIME_DIR" \
      systemd-run --user --scope --quiet --slice="${NDC_VM_SLICE:-vm-tests.slice}" \
        --unit="ndc-prison-readiness-$$-$RANDOM" -- \
        env XDG_RUNTIME_DIR="$scratch_run" "$driver/bin/nixos-test-driver" --no-interactive) \
     >"$log" 2>&1; then
  pass "every start succeeds, quiet and under a daemon-reload loop"
else
  grep -a -E 'RESULT|Error|Traceback' "$log" >"$OUTFILE" || tail -25 "$log" >"$OUTFILE"
  fail "a prison service start failed"
fi
grep -a '^RESULT' "$log" | while IFS= read -r l; do note "${l#RESULT }"; done

finish
