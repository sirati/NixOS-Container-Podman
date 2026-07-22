# Bash completion for a nix-dev-container run script. Shared by the
# NixOS-installed package (flake.nix's mkContainer) and the portable
# tarball (portable-tarball.nix) - both dispatch the same subcommand
# set, only the binary name (`cmdName`) differs.
{ pkgs, cmdName }:
let
  fnName = "_" + builtins.replaceStrings [ "-" ] [ "_" ] cmdName;
in
pkgs.writeTextFile {
  name = "${cmdName}-bash-completion";
  destination = "/share/bash-completion/completions/${cmdName}";
  text = ''
    # Bash completion for ${cmdName}.
    ${fnName}() {
      local cur prev
      cur=''${COMP_WORDS[COMP_CWORD]}
      prev=''${COMP_WORDS[COMP_CWORD-1]}

      if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W \
          "up down stop enter shell develop wayland-attach wayland-detach exec boot logs status purge check-host-compat" \
          -- "$cur") )
        return
      fi

      local subcmd=''${COMP_WORDS[1]}
      case "$subcmd" in
        up|boot)
          COMPREPLY=( $(compgen -W "--gpu --opengl" -- "$cur") )
          ;;
        enter|shell)
          COMPREPLY=( $(compgen -W \
            "-A --forward-agent --x11 --x11-untrusted --wayland -S --socket" \
            -- "$cur") )
          ;;
        develop)
          case "$cur" in
            -*)
              COMPREPLY=( $(compgen -W \
                "-A --forward-agent --x11 --x11-untrusted --wayland --wprs -S --socket --mount-bashrc --mount-gitconfig" \
                -- "$cur") )
              ;;
            *)
              # Only complete dirs when not directly after -S/--socket
              # (which expects name=path).
              if [ "$prev" != "-S" ] && [ "$prev" != "--socket" ]; then
                COMPREPLY=( $(compgen -d -- "$cur") )
              fi
              ;;
          esac
          ;;
        wayland-attach|wayland-detach)
          COMPREPLY=( $(compgen -d -- "$cur") )
          ;;
        exec)
          # exec passes the rest to the container as a command.
          COMPREPLY=( $(compgen -c -- "$cur") )
          ;;
      esac
    }

    complete -F ${fnName} ${cmdName}
  '';
}
