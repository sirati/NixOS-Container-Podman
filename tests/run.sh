#!/usr/bin/env bash
#
# The nix-dev-container test suite.
#
#   tests/run.sh              everything
#   tests/run.sh --quick      only what needs no container
#   tests/run.sh 20 30        only cases whose name matches
#   tests/run.sh --keep       leave the scratch dir for inspection
#
# Containers are real: they are started, entered and torn down for real.
# What makes that safe to run on a machine with its own podman and its own
# nix-dev-container is that every path a test could write to is redirected
# into tests/scratch first (see lib.sh), and that the last thing this
# script does is prove the redirect held and the cleanup was total.

# shellcheck source=lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

QUICK=0
KEEP=0
FILTERS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -q|--quick) QUICK=1; shift ;;
    -k|--keep)  KEEP=1; shift ;;
    -h|--help)  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "unknown flag: $1" >&2; exit 2 ;;
    *)          FILTERS+=("$1"); shift ;;
  esac
done

# ------------------------------------------------------------- snapshots

# What the host looked like before the run, read off the filesystem rather
# than by asking podman: invoking the user's podman would itself start
# their rootless pause process on a machine where none was running, which
# is the sort of side effect this suite exists to avoid.
snapshot_host() {
  local d
  for d in "$HOST_XDG_DATA_HOME/containers" \
           "$HOST_XDG_RUNTIME_DIR/containers" \
           "$HOST_XDG_RUNTIME_DIR/libpod" \
           "$HOST_XDG_RUNTIME_DIR/nixct" \
           "$HOST_XDG_STATE_HOME/nix-dev-container"; do
    printf -- '--- %s\n' "$d"
    if [ -d "$d" ]; then find "$d" -maxdepth 1 -printf '%P\n' 2>/dev/null | sort; fi
  done
}

BEFORE=$(snapshot_host)

# --------------------------------------------------------------- teardown

# Runs whatever the cases left, in the order that can actually free things:
# the framework's own `down` and `purge` first (they know about the mounts,
# the watchdogs and the session users), then the podman pause process that
# owns the user namespace, then the directory itself.
teardown() {
  if [ "$KEEP" -eq 1 ]; then note "--keep: leaving $SCRATCH"; return 0; fi

  local run name state
  while IFS=$'\t' read -r run name state; do
    [ -n "${run:-}" ] || continue
    NAME="$name" STATE_DIR="$state" "$run" down --force  >/dev/null 2>&1 || true
    NAME="$name" STATE_DIR="$state" "$run" purge --force >/dev/null 2>&1 || true
  done <"$REGISTRY"

  # The rootless user namespace is held by a pause process recorded here.
  # Killed by pid from its own pidfile -- never by name or pattern, which
  # on this machine would reach the user's real podman.
  local pausefile="$XDG_RUNTIME_DIR/libpod/tmp/pause.pid" pid
  if [ -r "$pausefile" ]; then
    pid=$(cat "$pausefile" 2>/dev/null || true)
    case "$pid" in
      ''|*[!0-9]*) ;;
      *) kill "$pid" 2>/dev/null || true ;;
    esac
  fi

  # Anything else still holding a path inside the scratch dir. Matched on
  # the absolute scratch path -- unique to this checkout -- and confirmed
  # against each pid's own cmdline before signalling it.
  local p
  for p in $(pgrep -u "$(id -u)" -f -- "$SCRATCH" 2>/dev/null || true); do
    if [ "$p" = "$$" ]; then continue; fi
    if tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -qF -- "$SCRATCH"; then
      kill "$p" 2>/dev/null || true
    fi
  done

  # podman leaves its storage owned by subuids, so the last of it can only
  # be removed from inside the user namespace that owns those ids.
  if [ -d "$SCRATCH" ]; then
    podman unshare rm -rf -- "$SCRATCH" 2>/dev/null || rm -rf -- "$SCRATCH" || true
  fi
}

# ---------------------------------------------------------- residue check

# The last check, and the one that gives the rest of the suite its licence
# to start real containers: nothing of this run is left anywhere.
residue_checks() {
  echo
  echo "== cleanup was total =="

  check "the scratch directory is gone" test '!' -e "$SCRATCH"
  check_fails "git sees no scratch left in the working tree" \
    bash -c "git -C '$REPO' status --porcelain --ignored -- tests/ | grep -q scratch"

  local after; after=$(snapshot_host)
  if [ "$after" = "$BEFORE" ]; then
    pass "the host's podman and state dirs are exactly as they were"
  else
    diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$after") >"$OUTFILE" 2>&1 || true
    fail "the host's podman and state dirs changed"
  fi

  check_fails "nothing is still mounted under the scratch path" \
    grep -qF -- "$SCRATCH" /proc/self/mountinfo

  local procs
  procs=$(pgrep -u "$(id -u)" -af -- "$SCRATCH" 2>/dev/null || true)
  if [ -z "$procs" ]; then
    pass "no process is still holding the scratch path"
  else
    printf '%s\n' "$procs" >"$OUTFILE"
    fail "processes are still holding the scratch path"
  fi

  # A develop session in host-daemon mode registers its store paths as
  # indirect gc roots, which live in the host's gcroots directory and point
  # back into the state dir. Purging the state dir is what releases them:
  # the link is left dangling, pins nothing, and nix removes dangling
  # indirect roots itself on its next collection. A LIVE one would mean the
  # suite is still pinning store paths, and that is what this rejects.
  local live=0 l t
  for l in /nix/var/nix/gcroots/auto/*; do
    [ -L "$l" ] || continue
    t=$(readlink "$l" 2>/dev/null || true)
    case "$t" in
      "$SCRATCH"*) if [ -e "$t" ]; then live=$((live + 1)); fi ;;
    esac
  done
  if [ "$live" -eq 0 ]; then
    pass "no live gc root points into the scratch path"
  else
    printf 'live gc roots into scratch: %s\n' "$live" >"$OUTFILE"
    fail "gc roots are still pinning store paths for this run"
  fi
}

# -------------------------------------------------------------------- run

cases=()
for f in "$TESTS_DIR"/cases/*.sh; do
  base=$(basename "$f")
  if [ "$QUICK" -eq 1 ] && [ "$base" != "00-eval.sh" ]; then continue; fi
  if [ ${#FILTERS[@]} -gt 0 ]; then
    keep=0
    for filter in "${FILTERS[@]}"; do
      case "$base" in *"$filter"*) keep=1 ;; esac
    done
    [ "$keep" -eq 1 ] || continue
  fi
  cases+=("$f")
done

if [ ${#cases[@]} -eq 0 ]; then
  echo "no cases matched" >&2
  exit 2
fi

failed=()
for f in "${cases[@]}"; do
  echo
  echo "### $(basename "$f")"
  if bash "$f"; then :; else failed+=("$(basename "$f")"); fi
done

echo
echo "### teardown"
teardown

# The scratch dir is gone by now, so the residue checks cannot write their
# output there. A temp file outside the repo, removed on exit, is the one
# place left -- and it is itself the smallest possible thing to clean up.
OUTFILE=$(mktemp --tmpdir=/tmp nixct-residue.XXXXXX)
trap 'rm -f -- "$OUTFILE"' EXIT
# shellcheck disable=SC2034 # counted by lib.sh's check helpers
PASS_N=0 FAIL_N=0 SKIP_N=0
if [ "$KEEP" -eq 1 ]; then
  echo
  echo "== cleanup was total =="
  skip "residue checks" "--keep was given"
else
  residue_checks
fi
[ "$FAIL_N" -eq 0 ] || failed+=("residue")

echo
if [ ${#failed[@]} -eq 0 ]; then
  printf '%s all cases passed\n' "$(_c 32 'PASS')"
  exit 0
fi
printf '%s failing: %s\n' "$(_c 31 'FAIL')" "${failed[*]}"
exit 1
