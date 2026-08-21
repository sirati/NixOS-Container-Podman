# Hooks for `develop --git-serve`. Pointed at by core.hooksPath in the
# server-side config the git daemon runs under, so the policy never touches
# the served repository's own configuration or hooks.
{ pkgs }:

pkgs.writeTextFile {
  name = "nixct-git-serve-hooks";
  destination = "/pre-receive";
  executable = true;
  text = ''
    #!${pkgs.bash}/bin/bash
    # Refuse any ref update outside the policy. This is the ENFORCEMENT for
    # pushes: uploadpack.hideRefs governs what a session may READ, but git
    # will not let a hidden ref be written either, so a push policy wider
    # than a single branch cannot be expressed that way and is decided here.
    set -u
    allowed=''${NIXCT_GIT_PUSH_GLOB:?pre-receive: no push policy in the environment}
    rc=0
    while read -r _old _new ref; do
      case "$ref" in
        refs/heads/*) name=''${ref#refs/heads/} ;;
        *)
          echo "nixct: refusing non-branch ref $ref" >&2
          rc=1
          continue ;;
      esac
      # Unquoted on purpose: $allowed is a glob, and quoting it would turn
      # the pattern into a literal.
      # shellcheck disable=SC2254
      case "$name" in
        $allowed) ;;
        *)
          echo "nixct: refusing push to '$name' (allowed: $allowed)" >&2
          rc=1 ;;
      esac
    done
    exit $rc
  '';
}
