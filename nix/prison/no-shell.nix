# The store view of a prison service, refused if it contains a shell.
#
# A prison's /nix/store is exactly the service's closure. A shell in it is a
# second program for anyone who reaches code execution, and the usual way one
# gets there is by accident: a writeShellScript wrapper, a package whose bin/
# carries a helper script, or a library that propagates a -dev output. So
# every service's closure passes through this derivation, and the store farm
# the FUSE view serves is built from its output, not from the raw closure.
# There is no parameter to skip it: a prison that cannot be built without a
# shell does not get built.
#
# A path is refused when its name is a shell package, or when it provides an
# executable under a shell's name in bin/ or sbin/ (this is what catches a
# /bin/sh provider that is not named like one, e.g. a busybox build).
#
# Contract: { pkgs, name, closure } -> drv with the same files as `closure`
#   (closureInfo output: store-paths, registration, total-nar-size).
{
  pkgs,
  name,
  closure,
}:

pkgs.runCommand "prison-${name}-closure" { }
  ''
    set -euo pipefail

    shellNames='sh bash dash ash hush zsh ksh mksh oksh loksh yash fish tcsh csh nu posh busybox toybox'
    namePattern='^(bash|bash-interactive|dash|busybox|busybox-sandbox-shell|mksh|zsh|ksh|oksh|loksh|yash|fish|tcsh|nushell|toybox|posh)-[0-9]'

    found=()
    while IFS= read -r p; do
      base=''${p#${builtins.storeDir}/}
      base=''${base#*-}
      if [[ $base =~ $namePattern ]]; then
        found+=("$p (shell package)")
        continue
      fi
      for d in bin sbin; do
        for n in $shellNames; do
          if [ -e "$p/$d/$n" ] || [ -L "$p/$d/$n" ]; then
            found+=("$p (provides $d/$n)")
            continue 3
          fi
        done
      done
    done < ${closure}/store-paths

    if [ ''${#found[@]} -ne 0 ]; then
      {
        echo "prison: the store view of service ${name} contains a shell."
        echo
        echo "A prison's /nix/store is the service's closure, and it must not hold"
        echo "bash, sh or any other shell. Offending paths and what in the closure"
        echo "refers to each:"
        for f in "''${found[@]}"; do
          p=''${f%% *}
          echo "  $f"
          awk -v want="$p" '
            # registration: path, hash, size, deriver, n, then n references.
            BEGIN { st = 0 }
            st == 0 { cur = $0; st = 1; next }
            st == 1 { st = 2; next }
            st == 2 { st = 3; next }
            st == 3 { st = 4; next }
            st == 4 { n = $0 + 0; st = (n > 0) ? 5 : 0; next }
            st == 5 {
              if ($0 == want && cur != want) print "      referenced by " cur
              if (--n == 0) st = 0
            }
          ' ${closure}/registration
        done
        echo
        echo "Remove the reference: exec the program directly instead of through a"
        echo "shell wrapper, copy only the binary a service needs out of a package"
        echo "whose bin/ also ships scripts, or drop a provably unused reference."
      } >&2
      exit 1
    fi

    mkdir -p $out
    cp ${closure}/store-paths ${closure}/registration ${closure}/total-nar-size $out/
  ''
