{ config, lib, pkgs, modulesPath, ... }:

# Framework module - imported by mkContainer for every container build.
# Cribs the load-bearing tricks from Anillc/podman-nixos (the only NixOS-in-
# podman project that actually works): kill specialfs, defuse the wrappers
# tmpfs, postBootCommands for nix-path-registration.
#
# The nixDevContainer.hostDaemon.enable option (set by mkContainer from
# the hostNixDaemon axis) switches the container from running its
# own nix-daemon to delegating to the HOST daemon over a bind-mounted
# socket: no in-container daemon, no nixbld build users, store = daemon.
# The run script provides the matching mounts (host /nix/store ro + the
# daemon socket).

let
  hostDaemon = config.nixDevContainer.hostDaemon.enable;
in
{
  imports = [
    (modulesPath + "/profiles/minimal.nix")
  ];

  options.nixDevContainer.hostDaemon.enable = lib.mkEnableOption ''
    host-daemon nix-store mode: the container runs no nix-daemon and has
    no nixbld users; every build/query is delegated to the host's
    nix-daemon over its bind-mounted socket, with /nix/store mounted
    read-only from the host'';

  config = lib.mkMerge [
    {
      boot = {
        isContainer = true;
        # Required so in-container `nixos-rebuild switch` / `switch-to-configuration`
        # can rewrite /sbin/init -> new toplevel/init.
        loader.initScript.enable = true;

        # Register the closure into the in-container Nix DB on first boot.
        # In host-daemon mode the authoritative DB is the host's (reached
        # via the daemon socket) and the closure is already valid there and
        # visible RO under /nix/store, so there is no local DB to load and
        # no local system profile worth setting - just drop the manifest.
        #
        # NOTE: postBootCommands runs from stage-2-init.sh with a bare
        # environment that does NOT source /etc/set-environment, so the
        # inherited NIX_REMOTE=daemon is absent here; that's another reason
        # the host-daemon branch avoids invoking nix at all.
        postBootCommands =
          if hostDaemon then ''
            rm -f /nix-path-registration
          '' else ''
            if [ -f /nix-path-registration ]; then
              ${config.nix.package}/bin/nix-store --load-db < /nix-path-registration \
                && rm /nix-path-registration
            fi
            ${config.nix.package}/bin/nix-env \
              -p /nix/var/nix/profiles/system --set /run/current-system
          '';
      };

      # The most important line in this file. NixOS's stage-2 init normally tries
      # to mount /proc, /sys, /dev/pts itself - podman/crun has already set those
      # up, and a second mount() fails (or worse, shadows them). Drop the script.
      system.activationScripts.specialfs = lib.mkForce "";

      # /sys/kernel/{debug,tracing} need privileges we don't have in a rootless
      # container; /run/wrappers normally lives on its own tmpfs/overlay which
      # also fails.
      systemd.mounts = [
        { enable = false; where = "/sys/kernel/debug"; }
        { enable = false; where = "/sys/kernel/tracing"; }
        { enable = false; where = "/run/wrappers"; }
      ];

      # Override the wrappers service: instead of waiting for /run/wrappers as a
      # mount unit, just mkdir it and write into the regular tmpfs /run.
      systemd.services.suid-sgid-wrappers = {
        unitConfig.RequiresMountsFor = lib.mkForce [ "/nix/store" ];
        preStart = "mkdir -p /run/wrappers";
      };

      # Container runtime handles networking; don't run dhcpcd by default.
      networking.useDHCP = lib.mkDefault false;

      # Default rlimits inside the container. Without these, services inherit
      # systemd's hard-coded conservative defaults (NOFILE=1024, NPROC=512 in
      # some user-ns configurations) and large apps (Firefox, ML toolkits)
      # hit EAGAIN / "Resource temporarily unavailable" when spawning threads
      # or opening many fds. Match a typical Linux desktop.
      systemd.settings.Manager = {
        DefaultLimitNOFILE = "1024:524288";
        DefaultLimitNPROC = "65535";
        DefaultLimitMEMLOCK = "infinity";
      };

      # NixOS' default ping_group_range is "0 2147483647" - on a rootless
      # container's user-ns the max valid gid is bounded by the subgid range,
      # and the kernel rejects sysctl values exceeding it with EINVAL. Use
      # "0 65535" which is the full user-ns gid range. Permits ping for all
      # gids that exist in the container.
      boot.kernel.sysctl."net.ipv4.ping_group_range" = lib.mkForce "0 65535";

      nix.settings = {
        experimental-features = lib.mkDefault [ "nix-command" "flakes" ];
        # @wheel members (e.g. the dev user from configuration.nix) become
        # trusted-users so they can flip substituters/sandboxing per-invocation.
        # Not lib.mkDefault, because NixOS' default ("root" only) overrides it.
        trusted-users = [ "root" "@wheel" ];
        # The nix sandbox uses mount-namespacing and clone()s in ways that
        # routinely fail in containers without extra caps.
        sandbox = lib.mkDefault false;
      };

      # No nix-channels - everything is pinned through flakes. Pre-populate
      # NIX_PATH with the same nixpkgs source the container is built from, so
      # `nix-shell -p` and `<nixpkgs>` work without producing the
      # "/nix/var/nix/profiles/per-user/root/channels does not exist" warning.
      nix.channel.enable = false;
      nix.nixPath = lib.mkForce [ "nixpkgs=${pkgs.path}" ];

      # direnv (+ nix-direnv `use flake`) for develop sessions. We pull in
      # the integration - which installs direnv, wires up nix-direnv at
      # /etc/direnv/direnvrc and sets DIRENV_CONFIG - but DISABLE the global
      # shell hooks: the hook is enabled per develop session through the
      # session .bashrc below instead, so it never leaks into `enter`
      # shells and the session .bashrc stays in sole control of it.
      programs.direnv = {
        enable = lib.mkDefault true;
        enableBashIntegration = lib.mkDefault false;
        enableZshIntegration = lib.mkDefault false;
        enableFishIntegration = lib.mkDefault false;
      };

      # Skeleton ~/.bashrc installed into every develop-session HOME by the
      # run script (see run.nix develop case). Runs first so direnv is
      # always enabled regardless of the user's own dotfiles, then defers
      # to a user bashrc if one was mounted in (renamed to ~/.bashrc.user
      # so this file keeps control of the direnv setup - see nixct).
      # direnv is referenced by absolute store path because the dev shell
      # spawned by `nix develop` has a hermetic PATH that won't contain it.
      environment.etc."nix-dev-container/bashrc" = {
        mode = "0444";
        text = ''
          # nix-dev-container develop-session ~/.bashrc (framework-managed).
          eval "$(${pkgs.direnv}/bin/direnv hook bash)"
          if [ -f "$HOME/.bashrc.user" ]; then
            . "$HOME/.bashrc.user"
          fi
        '';
      };

      # ---- develop-session infrastructure (any container) -------------
      # These are load-bearing for the run script's `develop` subcommand,
      # so they live in the framework module (not the example config):
      # bindfs (per-session HOME remap), socat (watchdog + socket proxies),
      # fuse3 (fusermount3 for teardown unmounts).
      environment.systemPackages = with pkgs; [ bindfs socat fuse3 ];

      # Container directory layout for develop sessions:
      #   /hostmnts            - bind target for host paths. Owned by the
      #                          container root (= host user under the
      #                          default rootless mapping); mode 0700 on the
      #                          host source so session users can never
      #                          enumerate it. Created by the run script.
      #   /develop-home/<user> - per-session HOME (0700, session-user-owned),
      #                          with the project bind-mounted at <home>/dev.
      #   /run/sockets/<id>    - per-session forwarded sockets.
      #
      # /develop-home and /run/sockets are 0711: traversal-only for non-root,
      # so a session user can cd into its own dir but cannot `ls` the parent
      # to enumerate other sessions' usernames. The per-session bindfs view
      # additionally strips group/other perms.
      systemd.tmpfiles.rules = [
        "d /develop-home 0711 root root -"
        "d /run/sockets  0711 root root -"
      ];

      # Per-develop-session watchdog. Spawned by the develop subcommand once
      # per session-scope; blocks until session-<mount_id>.scope becomes
      # inactive (every process the session user started, including reparented
      # daemons, has exited), then unmounts the per-session mounts, deletes
      # the session user, and notifies the outer host watchdog so it can drop
      # the host-side bind.
      environment.etc."nix-dev-container/inner-watchdog.sh" = {
        mode = "0555";
        text = ''
          #!${pkgs.bashInteractive}/bin/bash
          # args: <mount_id> <session_user>
          set -u
          PATH=/run/current-system/sw/bin:/run/wrappers/bin

          mount_id=$1
          session_user=$2
          scope="session-''${mount_id}.scope"
          home_dir="/develop-home/''${session_user}"
          socket_dir="/run/sockets/''${mount_id}"

          # Stage 1: wait for the scope to actually come into existence.
          # The watchdog is started before the develop subcommand creates the
          # scope, so without this wait `is-active` would return inactive
          # immediately and we'd tear down before the user ever got a shell.
          for _ in $(seq 1 120); do
            state=$(systemctl is-active "$scope" 2>/dev/null || true)
            case "$state" in active|activating|reloading) break ;; esac
            sleep 0.5
          done

          # Stage 2: wait for the scope to become inactive (= every process,
          # including reparented daemons, has exited).
          while systemctl is-active --quiet "$scope" 2>/dev/null; do
            sleep 2
          done
          # Settle period in case systemd is mid-tear-down.
          sleep 1

          # The project is bind-mounted at <home>/dev; the home itself is a
          # real per-session dir holding home-level files (.bashrc, .nixct,
          # nix profile state). Unmount the project bind FIRST, then wipe the
          # home tree - but only once the bind is truly gone, so `rm -rf` can
          # never recurse into the host's project files.
          proj_dir="$home_dir/dev"
          if mountpoint -q -- "$proj_dir"; then
            fusermount3 -u -- "$proj_dir" 2>/dev/null \
              || umount -- "$proj_dir" 2>/dev/null || true
          fi
          if mountpoint -q -- "$proj_dir"; then
            # Bind still up - don't risk rm -rf into host files.
            rmdir -- "$proj_dir" 2>/dev/null || true
          else
            rm -rf -- "$home_dir" 2>/dev/null || true
          fi

          # Forwarded-socket proxies (socat units) are killed by their
          # BindsTo=$scope; just clean up the leftover socket files.
          rm -rf -- "$socket_dir" 2>/dev/null || true

          # wprsd (nixct develop --wprs) is NOT BindsTo=$scope - the scope
          # doesn't exist yet when wprsd starts (systemd-run refuses to
          # create a unit whose BindsTo= target doesn't exist), so it's
          # stopped explicitly here instead. Harmless no-op if absent.
          systemctl stop "wprsd-''${mount_id}.service" 2>/dev/null || true

          userdel -- "$session_user" 2>/dev/null || true
          groupdel -- "$session_user" 2>/dev/null || true

          # Notify the per-session host watchdog. The socket path is bound to
          # this mount_id, so we don't pass it as data - the outer watchdog
          # knows by virtue of WHICH socket received the connection what to
          # tear down. A compromised in-container watchdog can only ask for
          # its OWN session's teardown.
          sock="/var/host-watchdog/''${mount_id}/sock"
          if [ -S "$sock" ]; then
            : | socat - "UNIX-CONNECT:$sock" 2>/dev/null || true
          fi
        '';
      };

      system.stateVersion = lib.mkDefault "25.11";
    }

    # ---- host-daemon profile -------------------------------------------
    (lib.mkIf hostDaemon {
      # Keep the nix CLI (so do NOT set nix.enable = false), but mask the
      # in-container daemon and its socket unit: every client talks to the
      # host daemon over the bind-mounted socket instead.
      systemd.services.nix-daemon.enable = lib.mkForce false;
      systemd.sockets.nix-daemon.enable = lib.mkForce false;
      # Drop the now-stale sockets.target.wants symlink for tidiness.
      systemd.sockets.nix-daemon.wantedBy = lib.mkForce [ ];

      # No nixbld build users / accounts (builds happen on the host). The
      # (empty) nixbld group remains - it's an unconditional gid reservation
      # in nixpkgs and harmless.
      nix.nrBuildUsers = lib.mkForce 0;

      # Force the daemon store for ALL contexts, including bare/non-login
      # ones (systemd units, postBootCommands) that don't read
      # /etc/set-environment's NIX_REMOTE. Written into nix.conf, so it
      # applies regardless of env.
      nix.settings.store = lib.mkForce "daemon";

      # Per-session gcroot-keeper. In host-daemon mode a develop session
      # builds land in the HOST store, but nix records their GC roots against
      # the container-only /develop-home/<user> path - so a host
      # `nix-collect-garbage` can delete paths the live session still needs.
      # This privileged in-container agent (runs as container root) watches
      # the session user's home for symlinks pointing into /nix/store and
      # re-registers them as GC roots in a host-visible directory, keeping the
      # host daemon from collecting them for the session's lifetime.
      #
      # Spawned per develop session and torn down by the run-script wiring
      # (run.nix develop-case + host-watchdog.nix); here we only install the
      # script. Lifecycle is driven by polling the session scope
      # rather than systemd BindsTo: the keeper unit is started BEFORE the
      # scope exists, so a BindsTo dependency would race and the unit would be
      # stopped the instant it started.
      environment.etc."nix-dev-container/gcroot-keeper.sh" = {
        mode = "0555";
        text = ''
          #!${pkgs.bashInteractive}/bin/bash
          # args: <mount_id> <session_user> <gcdir-abs-path>
          set -u
          PATH=/run/current-system/sw/bin:/run/wrappers/bin
          shopt -s nullglob

          mount_id=$1
          session_user=$2
          gcdir=$3
          scope="session-''${mount_id}.scope"
          home="/develop-home/''${session_user}"

          # Scan the curated, shallow set of locations where nix tooling drops
          # store-pointing symlinks, root every valid store path found. Kept
          # shallow on purpose: a deep recursive find of the whole project is
          # too slow and may walk huge trees.
          scan_and_root() {
            [ -d "$home" ] || return 0
            local link target relname rootname
            # The project is bind-mounted at <home>/dev (see run.nix
            # develop case), so build artifacts (result*, .direnv) live
            # there; home-level state (.nixct profile, nix profile dir)
            # lives directly under <home>.
            for link in \
              "$home"/dev/result "$home"/dev/result-* \
              "$home"/dev/.direnv/*-link \
              "$home"/.nixct/devshell* \
              "$home"/.local/state/nix/profiles/*-link
            do
              [ -L "$link" ] || continue
              target=$(readlink -f -- "$link" 2>/dev/null) || continue
              case "$target" in
                /nix/store/*) ;;
                *) continue ;;
              esac

              # Sanitized, shell-safe root name from the link's path relative
              # to $home: replace any char outside [A-Za-z0-9._-] with '_', and
              # guard a leading '-'/'.' so the name can never be read as an
              # option prefix or hidden file.
              relname=''${link#"$home"/}
              rootname=$(printf '%s' "$relname" | tr -c 'A-Za-z0-9._-' '_')
              case "$rootname" in
                -*|.*) rootname="_''${rootname}" ;;
              esac
              [ -n "$rootname" ] || continue

              # Idempotent: --add-root rewrites the symlink. Run as the keeper's
              # own uid (= container root); we do NOT su to the session user -
              # the session user builds as itself, root does the rooting. In
              # host-daemon mode nix.settings.store = "daemon" is baked into
              # nix.conf so plain nix-store already talks to the host daemon.
              # stderr/|| true so a transient failure (path mid-GC, daemon
              # busy) doesn't kill the loop.
              nix-store --add-root "$gcdir/$rootname" --realise "$target" \
                >/dev/null 2>&1 || true
            done
          }

          # Stage 1: wait for the scope to actually come into existence. The
          # keeper is started before the develop subcommand creates the scope;
          # without this wait `is-active` would report inactive immediately and
          # we'd exit before the session ever built anything.
          for _ in $(seq 1 120); do
            state=$(systemctl is-active "$scope" 2>/dev/null || true)
            case "$state" in active|activating|reloading) break ;; esac
            sleep 0.5
          done
          # Never showed up - nothing to protect.
          if ! systemctl is-active --quiet "$scope" 2>/dev/null; then
            exit 0
          fi

          # Stage 2: re-root on a 5s cadence for as long as the scope lives.
          while systemctl is-active --quiet "$scope" 2>/dev/null; do
            scan_and_root
            sleep 5
          done

          # Final pass to catch a build that completed in the last interval.
          # Best-effort: if the in-container watchdog has already unmounted the
          # session home, scan_and_root no-ops via its `[ -d "$home" ]` guard -
          # those last paths were almost always rooted in a prior iteration.
          # Do NOT delete the gcroot dir / its symlinks - removal is the host
          # watchdog's job (see nix/scripts/host-watchdog.nix).
          scan_and_root
          exit 0
        '';
      };

      assertions = [{
        assertion = config.nix.enable;
        message = "nixDevContainer.hostDaemon.enable keeps the nix CLI; do not set nix.enable = false.";
      }];
    })
  ];
}
