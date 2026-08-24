#!/usr/bin/env bash
#
# nixct: the thin wrapper the whole framework exists for -- host daemon,
# tmpfs state, no dev user, entered through `develop` rather than a shell.
# Everything here is the same code as the other variants; what is being
# tested is that mkNixct's own choices (root shell user, ephemeral storage,
# idle timeout) do not break it.

# shellcheck source=../lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

ct_new nixct nixct

check "up" ct up
check_out "storage is ephemeral" "ephemeral" ct status
check_out "the shell user is root" "root" ct status

proj=$(mk_project_flake "$SCRATCH/proj-flake-nixct")
# shellcheck disable=SC2016 # the variable is expanded in the container, not here
check_out "develop --command reaches a real dev shell" "devshell-reached" \
  timeout 900 env NAME="$CT_NAME" STATE_DIR="$CT_STATE" \
    "$CT_RUN" develop --command 'echo "marker=$NIXCT_TEST_MARKER"' "$proj"

# Two sessions on the same project share one session; the second shell must
# join rather than fail, and both must return.
# shellcheck disable=SC2016 # the variable is expanded in the container, not here
check_out "a second develop joins the live session" "devshell-reached" \
  timeout 900 env NAME="$CT_NAME" STATE_DIR="$CT_STATE" \
    "$CT_RUN" develop --command 'echo "marker=$NIXCT_TEST_MARKER"' "$proj"

ct_core_checks

finish
