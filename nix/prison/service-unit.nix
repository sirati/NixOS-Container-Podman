# Configuration synchronization and supervised service unit generation.
{
  lib,
  pkgs,
  backend,
}:

let
  inherit (lib) nameValuePair escapeShellArgs;

  # Copy a config tree into the directory bind-mounted into the container.
  # Per file, via a rename inside the same directory, so a reader sees either
  # the old file or the new one and never a half-written one -- and so the
  # directory itself is never replaced, which would detach the bind mount and
  # force the container to be recreated to see the change.
  syncConfig = pkgs.writeShellApplication {
    name = "prison-sync-config";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
    ];
    text = ''
      set -euo pipefail
      src=$1; dst=$2
      mkdir -p "$dst"
      while IFS= read -r -d ''' f; do
        mkdir -p "$dst/$(dirname "$f")"
        cp -L "$src/$f" "$dst/$f.tmp"
        chmod 0444 "$dst/$f.tmp"
        mv -f "$dst/$f.tmp" "$dst/$f"
      done < <(cd "$src" && find . -type f -print0)
    '';
  };

  syncCmd =
    p: s:
    escapeShellArgs [
      "${syncConfig}/bin/prison-sync-config"
      "${s.configTree}"
      (backend.configMountPoint p s)
    ];

  serviceUnit =
    p: s:
    let
      reload = backend.reloadArgs p s;
    in
    nameValuePair "${p.name}-${s.name}" {
      description = "${p.name}: ${s.name}";
      after = [ "${p.name}.service" ];
      bindsTo = [ "${p.name}.service" ];
      partOf = [ "${p.name}.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "exec";
        User = p.user;
        Restart = "on-failure";
        RestartSec = 2;
        ExecStartPre = lib.optional s.hasConfig (syncCmd p s);
        ExecStart = escapeShellArgs (backend.runService p s);
        ExecStop = escapeShellArgs (backend.stopArgs p s);
        # Reload re-syncs the configuration and tells the service, without
        # touching the container: the mount is a directory the host rewrites
        # in place, so the new content is already visible inside.
        ExecReload = lib.optionals (reload != null) (
          lib.optional s.hasConfig (syncCmd p s) ++ [ (escapeShellArgs reload) ]
        );
      };
    };

in
{
  inherit syncCmd serviceUnit;
}
