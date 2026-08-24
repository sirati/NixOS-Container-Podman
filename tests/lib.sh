# shellcheck shell=bash
#
# Shared setup for the nix-dev-container test suite.
#
# The one rule this file exists to enforce: a test run must not touch
# anything outside tests/scratch. That is harder than pointing podman
# somewhere else, because a rootless container run reaches for state in
# five different places, and only one of them is podman's own storage:
#
#   STATE_DIR         the framework's own tree (overlay upper/work, the
#                     merged rootfs, the session mounts). podman's
#                     --root/--runroot are derived from it by the run
#                     script, so redirecting this redirects podman too.
#   XDG_RUNTIME_DIR   where rootless podman keeps the pause process that
#                     owns the user namespace every container joins. Left
#                     alone, a test would join -- and on a machine with no
#                     podman running, CREATE -- the user's own.
#   XDG_{CONFIG,DATA,STATE,CACHE}_HOME
#                     containers.conf, storage.conf, the nix eval cache,
#                     and the run script's default STATE_DIR all live
#                     under these.
#   TMPDIR            podman and nix both scribble here.
#
# All five are redirected below. What is deliberately NOT redirected is
# HOME: nix needs it, and nothing under it is written once the four XDG
# vars point elsewhere. The residue check at the end of the run verifies
# that claim rather than trusting it.

set -euo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd -- "$TESTS_DIR/.." && pwd)
SCRATCH="$TESTS_DIR/scratch"

# Captured before the redirect, so the residue check can look at the real
# host state (the user's podman, the user's state dirs) to prove nothing
# was added there.
export HOST_XDG_RUNTIME_DIR=${HOST_XDG_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}}
export HOST_XDG_CONFIG_HOME=${HOST_XDG_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}
export HOST_XDG_DATA_HOME=${HOST_XDG_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}}
export HOST_XDG_STATE_HOME=${HOST_XDG_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}}
export HOST_XDG_CACHE_HOME=${HOST_XDG_CACHE_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}}

export XDG_RUNTIME_DIR="$SCRATCH/run"
export XDG_CONFIG_HOME="$SCRATCH/xdg/config"
export XDG_DATA_HOME="$SCRATCH/xdg/data"
export XDG_STATE_HOME="$SCRATCH/xdg/state"
export XDG_CACHE_HOME="$SCRATCH/xdg/cache"
export TMPDIR="$SCRATCH/tmp"

# Rootless podman refuses a runtime dir other users can see.
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" \
         "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$TMPDIR" \
         "$SCRATCH/state" "$SCRATCH/logs"
chmod 700 "$XDG_RUNTIME_DIR"

# The suite's own bookkeeping, kept in files rather than shell variables
# because teardown runs in a different process from the cases and has to
# clean up after a case that died halfway.
REGISTRY="$SCRATCH/registry"          # run-script<TAB>name<TAB>state-dir
touch "$REGISTRY"

# Where a failing check dumps what it saw. Overridable because the residue
# checks run after the scratch dir has been deleted.
OUTFILE="$SCRATCH/last.out"

# /etc/nix is still read, so a NixOS host's experimental-features apply;
# passing them anyway means the suite also runs on a host where they are
# only enabled in the user's nix.conf, which the redirect above hides.
NIX_FLAGS=(--extra-experimental-features "nix-command flakes")

# ---------------------------------------------------------------- output

_c() { if [ -t 1 ]; then printf '\033[%sm%s\033[0m' "$1" "$2"; else printf '%s' "$2"; fi; }
PASS_N=0
FAIL_N=0
SKIP_N=0

pass() { PASS_N=$((PASS_N + 1)); printf '  %s %s\n' "$(_c 32 ok)" "$1"; }
skip() { SKIP_N=$((SKIP_N + 1)); printf '  %s %s (%s)\n' "$(_c 33 '--')" "$1" "${2:-skipped}"; }
fail() {
  FAIL_N=$((FAIL_N + 1))
  printf '  %s %s\n' "$(_c 31 FAIL)" "$1"
  if [ -s "$OUTFILE" ]; then
    sed -e 's/^/      | /' "$OUTFILE" | tail -25
  fi
}
note() { printf '  %s %s\n' "$(_c 36 '::')" "$1"; }

# check <desc> <cmd...>            -- passes if the command exits 0
check() {
  local desc=$1; shift
  if "$@" >"$OUTFILE" 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# check_fails <desc> <cmd...>      -- passes if the command exits non-zero
check_fails() {
  local desc=$1; shift
  if "$@" >"$OUTFILE" 2>&1; then fail "$desc (unexpectedly succeeded)"; else pass "$desc"; fi
}

# check_out <desc> <needle> <cmd...> -- command must succeed AND print needle
check_out() {
  local desc=$1 needle=$2; shift 2
  if "$@" >"$OUTFILE" 2>&1 && grep -qF -- "$needle" "$OUTFILE"; then
    pass "$desc"
  else
    fail "$desc (expected output to contain: $needle)"
  fi
}

# check_err <desc> <needle> <cmd...> -- command must FAIL and say needle.
# The distinction matters for the "not implemented" checks: a build that
# fails for some unrelated reason would satisfy check_fails alone.
check_err() {
  local desc=$1 needle=$2; shift 2
  if "$@" >"$OUTFILE" 2>&1; then
    fail "$desc (unexpectedly succeeded)"
  elif grep -qF -- "$needle" "$OUTFILE"; then
    pass "$desc"
  else
    fail "$desc (failed, but not with: $needle)"
  fi
}

finish() {
  printf '  %s\n' "-- $PASS_N passed, $FAIL_N failed, $SKIP_N skipped"
  [ "$FAIL_N" -eq 0 ]
}

# ------------------------------------------------------------------- nix

# Evaluation against the flake's own pinned nixpkgs. The repo is a git
# checkout, so the flake sees only tracked files -- tests/scratch is
# untracked and gitignored and therefore cannot be copied into the store,
# however large it has grown.
nix_expr() {
  cat <<EOF
let
  flake = builtins.getFlake "git+file://$REPO";
  lib = flake.inputs.nixpkgs.lib;
  pkgs = flake.inputs.nixpkgs.legacyPackages.\${builtins.currentSystem};
  ct = flake.lib.\${builtins.currentSystem};
in $1
EOF
}

# nix_eval <expr>  -- evaluate against the flake, print the result
nix_eval() {
  nix eval "${NIX_FLAGS[@]}" --impure --raw --expr "$(nix_expr "$1")"
}

# build <flake-attr>  -- realise it, print the store path, cache the answer.
# Building is by far the slowest thing here and several cases want the same
# container, so the result is memoised for the run.
build() {
  local attr=$1 key out
  key="$SCRATCH/build-$(printf '%s' "$attr" | tr -c 'a-zA-Z0-9' '-')"
  if [ -f "$key" ]; then cat "$key"; return 0; fi
  if ! out=$(nix build "${NIX_FLAGS[@]}" --no-link --print-out-paths \
               "$REPO#$attr" 2>"$SCRATCH/logs/build.log"); then
    tail -30 "$SCRATCH/logs/build.log" >&2
    return 1
  fi
  printf '%s\n' "$out" | tee "$key"
}

# ------------------------------------------------------------- containers

# ct_new <label> <flake-attr>
#
# Claims a container name and state dir for this case and registers both
# with teardown before anything is created, so a case that dies between
# `up` and `down` still gets cleaned up. STATE_DIR must end in /$NAME --
# `purge` refuses to delete a state dir that doesn't, which is also what
# makes it safe to point at a directory inside the repo.
ct_new() {
  local label=$1 attr=$2 out
  out=$(build "$attr")
  # One binary per subcommand package; the run package has exactly one.
  CT_RUN=$(echo "$out"/bin/*)
  CT_NAME="nixct-test-$label"
  CT_STATE="$SCRATCH/state/$CT_NAME"
  printf '%s\t%s\t%s\n' "$CT_RUN" "$CT_NAME" "$CT_STATE" >>"$REGISTRY"
  note "$CT_NAME -> $(basename "$(dirname "$(dirname "$CT_RUN")")")"
}

# ct <args...>  -- invoke the run script for the current container
ct() {
  NAME="$CT_NAME" STATE_DIR="$CT_STATE" "$CT_RUN" "$@"
}

# ct_podman <args...> -- podman against THIS container's storage only
ct_podman() {
  podman --root "$CT_STATE/podman-root" --runroot "$CT_STATE/podman-runroot" "$@"
}

# eval_is <desc> <expected> <expr>   -- expression must evaluate to exactly this
eval_is() {
  local desc=$1 expected=$2 expr=$3 got
  if got=$(nix_eval "$expr" 2>"$OUTFILE"); then
    if [ "$got" = "$expected" ]; then
      pass "$desc"
    else
      printf '%s\n' "expected: $expected" "actual:   $got" >"$OUTFILE"
      fail "$desc"
    fi
  else
    fail "$desc (evaluation failed)"
  fi
}

# eval_ends_with <desc> <suffix> <expr>  -- result must END with this
eval_ends_with() {
  local desc=$1 suffix=$2 expr=$3 got
  if got=$(nix_eval "$expr" 2>"$OUTFILE"); then
    case "$got" in
      *"$suffix")
        pass "$desc" ;;
      *)
        printf '%s\n' "expected to end with: $suffix" "actual: $got" >"$OUTFILE"
        fail "$desc" ;;
    esac
  else
    fail "$desc (evaluation failed)"
  fi
}

# eval_fails <desc> <needle> <expr>  -- must throw, and say this
eval_fails() {
  local desc=$1 needle=$2 expr=$3
  check_err "$desc" "$needle" nix_eval "$expr"
}

# ------------------------------------------------------------- projects

# A directory with no flake in it. `develop` still has to do all of its own
# work to reach the point where nix says so -- bind-mount the project,
# create the session user, start the scope, run the command and hand back
# an exit status -- which is exactly the part of `develop` this framework
# owns, and it needs nothing in the container's store to exercise.
mk_project_bare() {
  local dir=$1
  mkdir -p "$dir"
  printf 'not a flake\n' >"$dir/README"
  printf '%s' "$dir"
}

# A real dev shell, from the nixpkgs this repo is already locked to. Only
# usable where the container can see the host store; a self-contained store
# holds the container's own closure and nothing else.
mk_project_flake() {
  local dir=$1 nixpkgs system
  nixpkgs=$(nix_eval 'flake.inputs.nixpkgs.outPath')
  # Spelled out rather than builtins.currentSystem: a flake is evaluated in
  # pure mode, where currentSystem does not exist, and `nix develop` inside
  # the container is no exception.
  system=$(nix_eval 'builtins.currentSystem')
  mkdir -p "$dir"
  cat >"$dir/flake.nix" <<EOF
{
  inputs.nixpkgs.url = "path:$nixpkgs";
  outputs = { self, nixpkgs }:
    let pkgs = nixpkgs.legacyPackages."$system";
    in {
      devShells."$system".default = pkgs.mkShell {
        NIXCT_TEST_MARKER = "devshell-reached";
      };
    };
}
EOF
  printf '%s' "$dir"
}

# ------------------------------------------------------- lifecycle checks

# The checks every container variant must pass, whatever its store and
# storage axes are. Kept here rather than copied into each case so that a
# new variant is one file that calls this, and so a check added here is
# added to every variant at once.
ct_core_checks() {
  check "up" ct up
  check_out "status reports it running" "running" ct status
  check_out "exec runs a command and returns its output" "container-alive" \
    ct exec -- /run/current-system/sw/bin/echo container-alive
  check_out "the container has a working nix" "nix (Nix)" \
    ct exec -- /run/current-system/sw/bin/nix --version

  # The regression this suite was written for: `develop` used to ask podman
  # for a pty unconditionally, so with no terminal it waited forever instead
  # of returning. It must now come back with an exit status, and the failure
  # it reports must be nix's (no flake here), not a hang and not a framework
  # error -- which is what proves the whole session path ran.
  local bare; bare=$(mk_project_bare "$SCRATCH/proj-bare-$CT_NAME")
  check_err "develop returns instead of hanging when there is no terminal" \
    "flake.nix" \
    timeout 300 env NAME="$CT_NAME" STATE_DIR="$CT_STATE" \
      "$CT_RUN" develop --command true "$bare"

  check "down" ct down --force
  check_out "status reports it gone" "not created" ct status
  check "purge" ct purge --force
  check "purge leaves no state dir behind" test '!' -e "$CT_STATE"
}
