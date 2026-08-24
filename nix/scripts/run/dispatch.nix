# Subcommand dispatch: everything after the helpers are defined.
#
# Split out of run.nix, which had grown to ~3000 lines with this case
# statement as half of it. The body is emitted verbatim into the same script,
# in the same position, so the generated text is unchanged -- verified by
# hashing the emitted script before and after the split.

{ tools
, storeLib
, checkHostCompatPath
, toplevel ? null
, ociRuntimeFlag
, developArgLines
, sessionEnvLines
, sessionFlagLine
, sessionShareLines
, sessionTemplateLines
}:

''
  # ----- subcommand dispatch ------------------------------------

  cmd=''${1:-enter}
  if [ $# -gt 0 ]; then shift; fi

  case "$cmd" in
    up)
      ENABLE_GPU=0
      ENABLE_OPENGL=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --gpu)    ENABLE_GPU=1; shift ;;
          --opengl) ENABLE_OPENGL=1; shift ;;
          --) shift; break ;;
          -*) echo "up: unknown flag $1" >&2; exit 2 ;;
          *)  break ;;
        esac
      done
      export ENABLE_GPU ENABLE_OPENGL
      if container_running; then
        echo "$NAME: already running"; exit 0
      fi
      if container_exists; then pm rm -f "$NAME" >/dev/null; fi
      start_persistent
      tags=""
      [ "$ENABLE_GPU"    = "1" ] && tags="$tags gpu"
      [ "$ENABLE_OPENGL" = "1" ] && tags="$tags opengl"
      echo "$NAME: up''${tags:+ (''${tags# })} [storage: $STORAGE, nix: $(store_summary)]"
      maybe_start_idle_monitor
      ;;
    switch|upgrade)
      # Upgrade a RUNNING container to this run script's system, in place.
      #
      # Only possible with hostNixDaemon: there the container sees the host
      # /nix, so a system built on the host is already realised inside it and
      # can simply be activated - the same thing nixos-rebuild does on a real
      # machine. Everything else (self-contained store, host-store FUSE) has
      # its system baked into an immutable rootfs layer built at image time,
      # and there is nothing to swap under a live container.
      #
      # Activation is `test`, not `switch`: the container has no bootloader,
      # and /nix/var here is the HOST profile directory, mounted read-only -
      # so the system profile must not be touched. `test` activates and
      # repoints /run/current-system, which is all a container needs.
      #
      # Develop sessions are unaffected: they live in transient scopes, which
      # activation does not restart.
      ${if toplevel == null then ''
        echo "$cmd: this build has no system to activate" >&2
        exit 1
      '' else ""}
      if [ "$HOST_NIX_DAEMON" != "1" ]; then
        echo "$cmd: only host-nix-daemon containers can be upgraded in place;" >&2
        echo "  this one has its system baked into its rootfs, so it needs a" >&2
        echo "  restart (down + up) to pick up a new build." >&2
        exit 1
      fi
      if ! container_running; then
        echo "$NAME: not running - the next \`up\` starts the new system anyway"
        exit 0
      fi
      current=$(pm exec -u root "$NAME" \
        /run/current-system/sw/bin/readlink -f /run/current-system 2>/dev/null \
        | tr -d '[:space:]')
      if [ "$current" = "${if toplevel == null then "" else toplevel}" ]; then
        echo "$NAME: already running this system"
        exit 0
      fi
      echo "$NAME: activating ${if toplevel == null then "" else toplevel}"
      pm exec -u root "$NAME" \
        ${if toplevel == null then "true" else "${toplevel}/bin/switch-to-configuration"} test
      echo "$NAME: upgraded in place (develop sessions kept running)"
      ;;
    down|stop)
      force=0
      while [ $# -gt 0 ]; do
        case "$1" in
          -f|--force) force=1; shift ;;
          *) echo "$cmd: unknown flag $1" >&2; exit 2 ;;
        esac
      done
      require_no_live_sessions "$cmd" "$force" || exit 1
      tear_down
      echo "$NAME: down"
      ;;
    __idle-monitor)
      # Hidden: host-side loop that tears the container down after
      # IDLE_TIMEOUT seconds with no active develop session. Spawned
      # detached by maybe_start_idle_monitor. A flock on a per-state
      # lock file makes this single-instance: if another monitor holds
      # it we just exit.
      exec 9>"$STATE_DIR/.idle-monitor.lock" || exit 0
      flock -n 9 || exit 0
      [ "''${IDLE_TIMEOUT:-0}" -gt 0 ] || exit 0
      # Poll often enough to be responsive but never busy-loop: clamp
      # to [3, 30] and never above the timeout itself.
      interval=$IDLE_TIMEOUT
      [ "$interval" -gt 30 ] && interval=30
      [ "$interval" -lt 3 ] && interval=3
      last=$(date +%s)
      while container_running; do
        # An active develop session shows up as a running
        # session-*.scope unit (created only by `develop`). grep -c
        # exits 1 on zero matches, so `|| true` is required here.
        active=$(pm exec "$NAME" \
          /run/current-system/sw/bin/systemctl list-units \
            --type=scope --state=active --no-legend 'session-*.scope' \
          2>/dev/null | grep -c '\.scope' || true)
        now=$(date +%s)
        # Activity = a live session scope OR a recent mark_activity touch
        # (the latter covers develop's setup window, before the scope
        # exists, so a stale monitor can't tear down a starting session).
        amt=$(stat -c %Y "$STATE_DIR/.idle-activity" 2>/dev/null || echo 0)
        if [ "''${active:-0}" -gt 0 ]; then
          last=$now
        else
          [ "''${amt:-0}" -gt "$last" ] && last=$amt
          if [ $((now - last)) -ge "$IDLE_TIMEOUT" ]; then
            tear_down
            break
          fi
        fi
        sleep "$interval"
      done
      exit 0
      ;;
    enter|shell)
      forward_agent=0
      x11_mode=""
      wayland=0
      sock_specs=()
      while [ $# -gt 0 ]; do
        case "$1" in
          -A|--forward-agent) forward_agent=1; shift ;;
          --x11)             x11_mode=trusted; shift ;;
          --x11-untrusted)   x11_mode=untrusted; shift ;;
          --wayland)         wayland=1; shift ;;
          -S|--socket)
            if [ -z "''${2:-}" ]; then
              echo "enter: -S requires name=path" >&2; exit 2
            fi
            sock_specs+=("$2"); shift 2 ;;
          --) shift; break ;;
          -*) echo "enter: unknown flag $1" >&2; exit 2 ;;
          *)  break ;;
        esac
      done

      ensure_running
      ns=dev
      # dev's uid/gid are fixed by configuration.nix (1000/100).
      dev_uid=1000
      dev_gid=100

      exec_env=()
      if [ "$forward_agent" -eq 1 ]; then
        if [ -z "''${SSH_AUTH_SOCK:-}" ] || [ ! -S "$SSH_AUTH_SOCK" ]; then
          echo "enter: -A given but SSH_AUTH_SOCK is unset/invalid" >&2
          exit 2
        fi
        bind_socket "$ns" "ssh-agent" "$SSH_AUTH_SOCK"
        spawn_socket_proxy "$ns" "ssh-agent" "$dev_uid" "$dev_gid"
        exec_env+=(--env "SSH_AUTH_SOCK=/run/sockets/$ns/ssh-agent")
      fi

      for spec in "''${sock_specs[@]+''${sock_specs[@]}}"; do
        parsed=$(parse_socket_spec "$spec") || exit 2
        sock_name=$(printf '%s' "$parsed" | sed -n '1p')
        sock_host=$(printf '%s' "$parsed" | sed -n '2p')
        bind_socket "$ns" "$sock_name" "$sock_host"
        spawn_socket_proxy "$ns" "$sock_name" "$dev_uid" "$dev_gid"
        echo "forward: $sock_host -> /run/sockets/$ns/$sock_name"
      done

      if [ -n "$x11_mode" ]; then
        x11_out=$(setup_x11 "$x11_mode" "$ns" "$dev_uid" "$dev_gid") || exit 2
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          exec_env+=(--env "$line")
        done <<<"$x11_out"
        echo "forward: X11 ($x11_mode)"
      fi

      if [ "$wayland" -eq 1 ]; then
        wl_out=$(setup_wayland "$ns" "$dev_uid" "$dev_gid") || exit 2
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          exec_env+=(--env "$line")
        done <<<"$wl_out"
        echo "forward: Wayland"
      fi

      while IFS= read -r line; do
        [ -z "$line" ] && continue
        exec_env+=(--env "$line")
      done <<<"$(term_env)"

      trap restore_term EXIT
      trap 'restore_term; exit 130' INT
      trap 'restore_term; exit 143' TERM
      pm exec -it -u "$SHELL_USER" \
        "''${exec_env[@]+''${exec_env[@]}}" \
        "$NAME" \
        ${tools.bash} -l
      ;;
    exec)
      if [ "''${1:-}" = "--" ]; then shift; fi
      ensure_running
      trap restore_term EXIT
      trap 'restore_term; exit 130' INT
      trap 'restore_term; exit 143' TERM
      pm exec -it -u "$SHELL_USER" "$NAME" "$@"
      ;;
    develop)
      # Container-declared default flags (mkContainer `sessionFlags`),
      # prepended to the command line so an explicit flag still parses after
      # them. Emitted double-quoted, so $HOME and friends expand here.
      ${sessionFlagLine}
      host_ports=()
      forward_agent=0
      agent_sock=""
      agent_allow=()
      agent_deny=()
      git_serve_branch=""
      git_serve_glob=""
      x11_mode=""
      wayland=0
      wprs=0
      dbus=0
      mount_bashrc=0
      mount_gitconfig=0
      translate_gitconfig=0
      native_project=0
      sock_specs=()
      # Container-declared templates (mkContainer `sessionTemplates`).
      # Emitted by the flake, so the host paths may reference $HOME /
      # $XDG_STATE_HOME and are expanded here, at run time.
      template_specs=()
      ${sessionTemplateLines}
      # Container-declared shares (mkContainer `sessionShares`) and the
      # default `nix develop` arguments (`developArgs`). CLI flags append to
      # both, so a session can add to what the container already provides.
      share_specs=()
      ${sessionShareLines}
      # Session environment (mkContainer `sessionEnv`), plus any --env.
      env_specs=()
      ${sessionEnvLines}
      develop_args=()
      ${developArgLines}
      while [ $# -gt 0 ]; do
        case "$1" in
          -A|--forward-agent) forward_agent=1; shift ;;
          --agent)
            # Like -A but naming the socket, for when the agent you want is
            # not the one $SSH_AUTH_SOCK happens to point at - e.g. the
            # 1Password agent while the login session carries a forwarded one.
            if [ -z "''${2:-}" ]; then
              echo "develop: --agent requires a socket path" >&2; exit 2
            fi
            agent_sock=$2; forward_agent=1; shift 2 ;;
          --agent-allow|--agent-deny)
            if [ -z "''${2:-}" ]; then
              echo "develop: $1 requires a key fingerprint or comment" >&2; exit 2
            fi
            if [ "$1" = "--agent-allow" ]; then agent_allow+=("$2"); else agent_deny+=("$2"); fi
            shift 2 ;;
          --git-serve)
            if [ -z "''${2:-}" ]; then
              echo "develop: --git-serve requires <branch>[:<push-glob>]" >&2; exit 2
            fi
            case "$2" in
              *:*) git_serve_branch=''${2%%:*}; git_serve_glob=''${2#*:} ;;
              *)   git_serve_branch=$2;        git_serve_glob=$2 ;;
            esac
            if [ -z "$git_serve_branch" ]; then
              echo "develop: --git-serve: empty branch" >&2; exit 2
            fi
            shift 2 ;;
          --x11)             x11_mode=trusted; shift ;;
          --x11-untrusted)   x11_mode=untrusted; shift ;;
          --wayland)         wayland=1; shift ;;
          --wprs)            wprs=1; shift ;;
          --dbus)            dbus=1; shift ;;
          --mount-bashrc)    mount_bashrc=1; shift ;;
          --mount-gitconfig) mount_gitconfig=1; shift ;;
          # Implies --mount-gitconfig: it is a modifier on that copy.
          --translate-gitconfig)
            mount_gitconfig=1; translate_gitconfig=1; shift ;;
          --native)          native_project=1; shift ;;
          --no-native)       native_project=0; shift ;;
          -S|--socket)
            if [ -z "''${2:-}" ]; then
              echo "develop: -S requires name=path" >&2; exit 2
            fi
            sock_specs+=("$2"); shift 2 ;;
          --template)
            if [ -z "''${2:-}" ]; then
              echo "develop: --template requires <hostpath>[:<name>]" >&2; exit 2
            fi
            template_specs+=("$2"); shift 2 ;;
          --env)
            if [ -z "''${2:-}" ]; then
              echo "develop: --env requires KEY=VALUE" >&2; exit 2
            fi
            env_specs+=("$2"); shift 2 ;;
          --share)
            if [ -z "''${2:-}" ]; then
              echo "develop: --share requires <hostpath>[:<name>][:ro|:rw]" >&2; exit 2
            fi
            share_specs+=("$2"); shift 2 ;;
          --host-port)
            if [ -z "''${2:-}" ]; then
              echo "develop: --host-port requires a port" >&2; exit 2
            fi
            host_ports+=("$2"); shift 2 ;;
          -D|--develop-arg)
            if [ -z "''${2:-}" ]; then
              echo "develop: --develop-arg requires a value" >&2; exit 2
            fi
            develop_args+=("$2"); shift 2 ;;
          --) shift; break ;;
          -*) echo "develop: unknown flag $1" >&2; exit 2 ;;
          *)  break ;;
        esac
      done
      if [ "$wayland" -eq 1 ] && [ "$wprs" -eq 1 ]; then
        echo "develop: --wayland and --wprs are mutually exclusive (--wayland shares the raw compositor socket; --wprs proxies it through wprsd)" >&2
        exit 2
      fi
      # Resolve the agent socket up front. The forward itself happens much
      # further down, but --translate-gitconfig needs the host path while
      # copying the config, which is earlier.
      agent_src=""
      if [ "$forward_agent" -eq 1 ]; then
        agent_src=''${agent_sock:-''${SSH_AUTH_SOCK:-}}
        if [ -z "$agent_src" ] || [ ! -S "$agent_src" ]; then
          if [ -n "$agent_sock" ]; then
            echo "develop: --agent: not a socket: $agent_sock" >&2
          else
            echo "develop: -A given but SSH_AUTH_SOCK is unset/invalid" >&2
          fi
          exit 2
        fi
      fi

      # Where the copied host git config goes, and where the framework puts
      # its own stanza (safe.directory, for --native).
      #
      # git defines TWO global-scope files - ~/.gitconfig and
      # $XDG_CONFIG_HOME/git/config - reads both, and merges them; the XDG
      # one is not shadowed by the other (only *writes* pick one). So the
      # copy keeps the layout it had on the host, and the framework takes
      # whichever of the two is left. Nothing contends for one file, and a
      # tool that reads ~/.gitconfig by hand still finds your config there
      # if that is where you keep it.
      git_src="" git_dst=""
      if [ "$mount_gitconfig" -eq 1 ]; then
        if [ -f "$HOME/.gitconfig" ]; then
          git_src="$HOME/.gitconfig"; git_dst=".gitconfig"
        elif [ -f "''${XDG_CONFIG_HOME:-$HOME/.config}/git/config" ]; then
          git_src="''${XDG_CONFIG_HOME:-$HOME/.config}/git/config"
          git_dst=".config/git/config"
        fi
      fi
      if [ "$git_dst" = ".gitconfig" ]; then
        fw_git_cfg=".config/git/config"
      else
        fw_git_cfg=".gitconfig"
      fi

      # No path given: develop the current working directory.
      target=''${1:-.}
      if ! hostpath=$(realpath -- "$target" 2>/dev/null); then
        echo "develop: cannot resolve $target" >&2; exit 2
      fi
      if [ ! -d "$hostpath" ]; then
        echo "develop: not a directory: $hostpath" >&2; exit 2
      fi

      ensure_running

      mount_id=$(compute_mount_id "$hostpath")

      # With --git-serve the project is never mounted, so there is nothing
      # to bind: the daemon reads the repository on the host directly.
      if [ -z "$git_serve_branch" ]; then
        bind_workdir "$hostpath" "$mount_id"
      fi

      # One SESSION per project path (user, home, binds, forwards,
      # watchdogs - all keyed on $mount_id), but any number of SHELLS in it.
      # Each shell gets its own scope, so running `develop` again on a path
      # that already has a live session opens another shell alongside the
      # first instead of failing on a name clash. The session lives until
      # its LAST shell exits.
      #
      # Joining has to be ATOMIC against teardown. Merely looking for a live
      # scope would race: the watchdog can decide "no shells left" and start
      # unmounting while this invocation is between that check and having its
      # own scope - the new shell would then land in a session being
      # dismantled underneath it. So both sides take the same per-session
      # lock, and this side registers a JOINER marker before releasing it.
      # The watchdog only tears down while holding that lock and only when
      # there is neither a live scope nor a joiner; the marker is dropped by
      # the shell itself, from inside its scope, once that scope exists (see
      # develop_cmd below), leaving no gap between the two.
      #
      # Not a login shell, and answers are tagged: /etc/profile emits a
      # terminal-title escape sequence that would otherwise be captured into
      # the values (and end up inside a unit name).
      # shellcheck disable=SC2016
      join_out=$(pm exec -u root "$NAME" \
        /run/current-system/sw/bin/bash -c '
          set -e
          sw=/run/current-system/sw/bin
          id=$1
          dir=/run/nixct-sessions/$id
          "$sw/mkdir" -p "$dir/joiners"
          # Sticky-writable, /tmp style: the marker is removed by the shell
          # itself, which runs as the session user, and unlinking needs write
          # permission on the DIRECTORY - owning the file is not enough. The
          # sticky bit still stops one session user from removing markers
          # belonging to another.
          "$sw/chmod" 1777 "$dir/joiners"
          exec 9>"$dir/lock"
          "$sw/flock" 9
          if [ -f "$dir/live" ]; then echo "STATE:joined"; else echo "STATE:new"; fi
          : > "$dir/live"
          i=1
          while [ "$i" -le 64 ]; do
            state=$("$sw/systemctl" show -p LoadState \
                      --value "session-$id-$i.scope" 2>/dev/null)
            if [ "$state" = "not-found" ] || [ -z "$state" ]; then
              if [ ! -e "$dir/joiners/$i" ]; then
                : > "$dir/joiners/$i"
                echo "IDX:$i"
                exit 0
              fi
            fi
            i=$((i + 1))
          done
          echo "IDX:0"
        ' bash "$mount_id")
      shell_idx=$(printf '%s' "$join_out" | sed -n 's/.*IDX:\([0-9][0-9]*\).*/\1/p' | head -1)
      join_state=$(printf '%s' "$join_out" | sed -n 's/.*STATE:\([a-z]*\).*/\1/p' | head -1)
      if [ -z "$shell_idx" ] || [ "$shell_idx" = "0" ]; then
        echo "develop: too many concurrent shells for this session" >&2
        exit 1
      fi
      scope="session-$mount_id-$shell_idx.scope"
      joiner_marker="/run/nixct-sessions/$mount_id/joiners/$shell_idx"

      # Session user (unique uid, NOT in wheel). Each develop
      # invocation allocates a fresh uid via useradd's auto
      # selection; reused across develop calls on the same path.
      # `--` terminates option parsing in useradd.
      # Session user (unique uid via auto-assignment, NOT in
      # wheel). useradd is idempotent via the existence check, so
      # running develop twice on the same hostpath reuses the
      # same user.
      session_user="dev-$mount_id"
      # shellcheck disable=SC2016
      pm exec -u root "$NAME" \
        /run/current-system/sw/bin/bash -lc '
          set -e
          if ! id -u "$1" >/dev/null 2>&1; then
            useradd \
              --no-create-home \
              --user-group \
              --home-dir "/develop-home/$1" \
              --shell /run/current-system/sw/bin/bash \
              -- "$1"
          fi
        ' bash "$session_user" >/dev/null

      uid=$(pm exec -u root "$NAME" /run/current-system/sw/bin/id -u -- "$session_user" | tr -d '[:space:]')
      gid=$(pm exec -u root "$NAME" /run/current-system/sw/bin/id -g -- "$session_user" | tr -d '[:space:]')

      # The joiner marker is dropped by the shell itself once its scope is
      # up (see develop_cmd), and that runs as the session user - so hand it
      # over now that the uid exists.
      pm exec -u root "$NAME" \
        /run/current-system/sw/bin/chown "$uid:$gid" "$joiner_marker" \
        >/dev/null 2>&1 || true

      # Per-session HOME at /develop-home/<session_user>, with the
      # project bind-mounted ONE LEVEL DOWN at <home>/dev. Keeping the
      # home and the project separate lets us drop home-level files
      # (.bashrc, .nixct, nix profile state) into the session HOME
      # without polluting the user's project tree.
      #   <home>      - real writable dir owned by the session user, 0700.
      #   <home>/dev  - bindfs view of /hostmnts/<id>. --perms="og="
      #                 strips group/other perms so other session users
      #                 can't peek in even if they guess the username.
      #
      # With --native the project is a plain bind instead, once the host
      # directory has been probed and granted (see use_native). That keeps
      # reflinks and native mmap, at the cost of the --perms="og=" screen:
      # a plain bind shows the real host permissions, so a project other
      # session users could read on the host stays readable to them here.
      # Only when this shell is the one that will actually mount. A second
      # `develop` on the same path JOINS the live session and reuses its
      # mount, so deciding again there would re-probe and re-walk the tree
      # to no effect - and print a native line for a session that is on
      # bindfs. Whichever way the first shell went is what the session is.
      project_native=0
      if [ -n "$git_serve_branch" ]; then native_project=0; fi
      if [ "$native_project" -eq 1 ] \
         && ! already_mounted "/develop-home/$session_user/dev" \
         && use_native "$hostpath" "$uid" "$gid" "native"; then
        project_native=1
      fi
      # shellcheck disable=SC2016
      pm exec -u root "$NAME" \
        /run/current-system/sw/bin/bash -lc '
          set -e
          # A FUSE daemon opens the underlying file for every file opened
          # through its mount, so ITS rlimit is the ceiling on how many
          # files everything using this project can hold open at once -
          # shared, not per process. At the inherited soft limit of 1024
          # that ceiling is ~660 files for the whole session, which a
          # single `cargo build -j32` blows through; it then surfaces as
          # EMFILE in an unrelated-looking place - a half-written .rlib, and
          # then a missing-crate error in crates nobody touched. Give the
          # daemon the hard limit.
          ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
          home_dir=/develop-home/$1
          proj_dir=$home_dir/dev
          src=/hostmnts/$2
          mkdir -p "$proj_dir"
          chown "$3:$4" "$home_dir"
          chmod 0700 "$home_dir"
          # $XDG_CONFIG_HOME, owned by the session user from the start.
          # Plenty of tools create things under it without checking, and a
          # root-owned ~/.config is a confusing failure far from its cause.
          mkdir -p "$home_dir/.config"
          chown "$3:$4" "$home_dir/.config"
          chmod 0755 "$home_dir/.config"
          # Framework-managed ~/.bashrc (enables direnv; sources a
          # mounted-in user bashrc if present). Reinstalled every run so
          # it stays current; user customisation goes in ~/.bashrc.user.
          cp /etc/nix-dev-container/bashrc "$home_dir/.bashrc"
          chown "$3:$4" "$home_dir/.bashrc"
          chmod 0644 "$home_dir/.bashrc"
          if [ "$7" = "1" ]; then
            # --git-serve: ~/dev is an empty directory owned by the session,
            # to clone into. Nothing of the host repository is mounted.
            chown "$3:$4" "$proj_dir"
            chmod 0700 "$proj_dir"
          elif ! mountpoint -q "$proj_dir" && [ "$5" != "1" ]; then
            # --multithreaded is NOT the bindfs default: without it one thread
            # serves every request for this project, so parallel builds
            # queue behind each other on a single FUSE daemon (46 requests
            # waiting against 1 thread, in the case that prompted this).
            bindfs --multithreaded --map=0/$3:@0/@$4 --perms="og=" \
              -o allow_other "$src" "$proj_dir"
          fi
        ' bash "$session_user" "$mount_id" "$uid" "$gid" "$project_native" \
          "" "$( [ -n "$git_serve_branch" ] && echo 1 || echo 0 )"
      if [ "$project_native" -eq 1 ]; then
        bind_native "/hostmnts/$mount_id" "/develop-home/$session_user/dev" rw
        allow_git_dir "$session_user" "$uid" "$gid" "/develop-home/$session_user/dev" "$fw_git_cfg"
        echo "native: $hostpath -> /develop-home/$session_user/dev (plain bind; reflinks work)"
      fi

      # Opt-in: copy the invoking host user's dotfiles read-only into
      # the session HOME. Each is piped in as container root, chowned
      # to the session user and locked to 0444. The framework ~/.bashrc
      # already sources ~/.bashrc.user. Missing host sources are
      # skipped silently. Use -i (stdin piped), not -it.
      if [ "$mount_bashrc" -eq 1 ] && [ -f "$HOME/.bashrc" ]; then
        # shellcheck disable=SC2016
        pm exec -i -u root "$NAME" /run/current-system/sw/bin/bash -lc '
          set -e; dest="/develop-home/$1/$2"; cat > "$dest"; chown "$3:$4" "$dest"; chmod 0444 "$dest"
        ' bash "$session_user" ".bashrc.user" "$uid" "$gid" < "$HOME/.bashrc"
      fi
      # Copy the host git config in (source and destination decided above).
      #
      # --translate-gitconfig rewrites the forwarded agent socket on the
      # way through. A host config that names the socket by path - an
      # `IdentityAgent` in a core.sshCommand, a signing helper pointed at
      # it - carries a path that does not exist in the session, where the
      # same agent is reachable at /run/sockets/<id>/ssh-agent instead. The
      # rewrite is a plain substitution of the one path -A resolved to, so
      # a config that says $SSH_AUTH_SOCK (already correct in the session)
      # is left alone.
      if [ "$mount_gitconfig" -eq 1 ]; then
        if [ -n "$git_src" ]; then
          git_filter=(cat)
          if [ "$translate_gitconfig" -eq 1 ]; then
            if [ -z "$agent_src" ]; then
              echo "develop: --translate-gitconfig without a forwarded agent - nothing to translate" >&2
            else
              git_filter=(sed -e "s|$agent_src|/run/sockets/$mount_id/ssh-agent|g")
            fi
          fi
          # shellcheck disable=SC2016
          pm exec -i -u root "$NAME" /run/current-system/sw/bin/bash -lc '
            set -e
            home="/develop-home/$1"
            dest="$home/$2"
            # Create EVERY missing level as the session user, not just the
            # last one. Leaving an intermediate (~/.config) owned by root
            # means the session can read it but never create anything in it,
            # which breaks any tool that expects to write under $XDG_CONFIG_HOME
            # - Chromium putting its crash-reporter state there, for one.
            rel=$(dirname -- "$2")
            cur="$home"
            if [ "$rel" != "." ]; then
              IFS=/ read -ra _parts <<< "$rel"
              for _p in "''${_parts[@]}"; do
                [ -z "$_p" ] && continue
                cur="$cur/$_p"
                mkdir -p "$cur"
                chown "$3:$4" "$cur"
                chmod 0755 "$cur"
              done
            fi
            cat > "$dest"
            chown "$3:$4" "$dest"
            chmod 0444 "$dest"
          ' bash "$session_user" "$git_dst" "$uid" "$gid" \
            < <("''${git_filter[@]}" -- "$git_src")
        fi
      fi

      home_dir="/develop-home/$session_user"
      proj_dir="$home_dir/dev"
      extra_setenv=()

      # `--env KEY=VALUE`: environment for the session shell.
      #
      # $HOME is expanded here, to the session HOME, because that is the
      # only place it can be: the session user is derived from the project
      # path, so whoever writes the value cannot know the path it will
      # have. Nothing else is expanded - the value is otherwise literal.
      for spec in "''${env_specs[@]+''${env_specs[@]}}"; do
        case "$spec" in
          *=*) ;;
          *) echo "develop: --env: not KEY=VALUE: $spec" >&2; exit 2 ;;
        esac
        e_key=''${spec%%=*}
        case "$e_key" in
          ""|*[!A-Za-z0-9_]*)
            echo "develop: --env: not a variable name: $e_key" >&2; exit 2 ;;
        esac
        e_val=''${spec#*=}
        e_val=''${e_val//\$HOME/$home_dir}
        extra_setenv+=(--setenv="$e_key=$e_val")
      done

      # `--template <hostpath>[:<name>]`: a host directory handed to the
      # session as a TEMPLATE at ~/<name>, next to ~/dev.
      #
      # A session HOME is wiped on teardown, so state a disposable container
      # must INHERIT (browser profiles, tool logins, caches) has to come
      # from the host. Handing that state over as a plain read-write bind
      # would hand every throwaway session a channel into shared, credential-
      # bearing state - it could corrupt it for every later session, or
      # persist into it. So the host copy is never writable here:
      #
      #   lower  = the host dir, bound in read-only (frozen source)
      #   upper  = a fresh per-session dir on the container's own (with
      #            ephemeral storage: tmpfs) filesystem
      #   result = fuse-overlayfs at ~/<name>
      #
      # The session sees an ordinary writable directory - which is what a
      # browser profile needs - but every write lands in the upper and is
      # discarded with the session. Two sessions never see each other's
      # writes, and the template on the host cannot be touched at all.
      # Templates are repeatable, and repeating the SAME name stacks: each
      # host dir becomes another overlay lower under that one mount point,
      # earlier entries winning over later ones (overlayfs order). That is
      # how a session can get, say, a base profile plus a project-specific
      # layer on top without either being writable.
      declare -A tpl_lowers=()
      tpl_names=()
      tpl_idx=0
      for spec in "''${template_specs[@]+''${template_specs[@]}}"; do
        case "$spec" in
          *:*) t_host=''${spec%:*}; t_name=''${spec##*:} ;;
          *)   t_host=$spec;        t_name=$(basename -- "$spec") ;;
        esac
        case "$t_name" in
          ""|.|..|dev|.bashrc|.bashrc.user|.gitconfig|.nixct|*/*|-*)
            echo "develop: --template: refusing name '$t_name'" >&2
            echo "  (must not be empty, contain '/', start with '-', or" >&2
            echo "   collide with a framework-managed entry)" >&2
            exit 2 ;;
        esac
        if ! t_host=$(realpath -- "$t_host" 2>/dev/null) || [ ! -d "$t_host" ]; then
          echo "develop: --template: not a directory: ''${spec%:*}" >&2; exit 2
        fi
        tpl_idx=$((tpl_idx + 1))
        bind_workdir "$t_host" "$mount_id.$t_name.$tpl_idx"
        if [ -z "''${tpl_lowers[$t_name]:-}" ]; then
          tpl_names+=("$t_name")
          tpl_lowers[$t_name]="/hostmnts/$mount_id.$t_name.$tpl_idx"
        else
          tpl_lowers[$t_name]="''${tpl_lowers[$t_name]}:/hostmnts/$mount_id.$t_name.$tpl_idx"
        fi
        echo "template: $t_host -> $home_dir/$t_name (overlay; writes are session-local)"
      done
      for t_name in "''${tpl_names[@]+''${tpl_names[@]}}"; do
        # shellcheck disable=SC2016
        pm exec -u root "$NAME" \
          /run/current-system/sw/bin/bash -lc '
            set -e
            # Same shared-handle-pool reasoning as the project bindfs above.
            ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
            session_user=$1; lowers=$2; uid=$3; gid=$4; tname=$5; id=$6
            dst=/develop-home/$session_user/$tname
            scratch=/run/nixct-templates/$id.$tname
            mkdir -p "$dst" "$scratch/upper" "$scratch/work"
            chown "$uid:$gid" "$scratch/upper"
            chmod 0700 "$scratch" "$scratch/upper"
            if ! mountpoint -q "$dst"; then
              # squash_to_uid presents the frozen lower as owned by the
              # session user (the host files map to container root), so it
              # can read them and copy-up on write.
              fuse-overlayfs \
                -o "lowerdir=$lowers,upperdir=$scratch/upper,workdir=$scratch/work" \
                -o "squash_to_uid=$uid,squash_to_gid=$gid" \
                -o allow_other \
                "$dst"
              chown "$uid:$gid" "$dst" 2>/dev/null || true
            fi
          ' bash "$session_user" "''${tpl_lowers[$t_name]}" "$uid" "$gid" "$t_name" "$mount_id"
      done

      # `--share <hostpath>[:<name>][:ro|:rw]`: the real host directory in
      # the session HOME at ~/<name>, same mechanism as ~/dev.
      #
      # This is the counterpart to --template, and the difference is the
      # whole point: a template is frozen and its writes die with the
      # session, a share is the live directory and writes go through to the
      # host and outlive the session. That is what you want for things a
      # session should accumulate across runs (a cargo registry, a build
      # cache) and NOT what you want for anything you would mind a
      # throwaway session corrupting. rw is the default because sharing a
      # directory read-only is what --template already does better; `:ro`
      # exists for a shared directory that must stay pristine.
      for spec in "''${share_specs[@]+''${share_specs[@]}}"; do
        s_mode=rw
        s_native=0
        case "$spec" in
          *:rw)     s_mode=rw; spec=''${spec%:rw} ;;
          *:ro)     s_mode=ro; spec=''${spec%:ro} ;;
          # `:native` is rw plus the native mount (a read-only native
          # mount would be `:ro`, which bindfs already serves at no cost).
          *:native) s_mode=rw; s_native=1; spec=''${spec%:native} ;;
        esac
        case "$spec" in
          *:*) s_host=''${spec%:*}; s_name=''${spec##*:} ;;
          *)   s_host=$spec;        s_name=$(basename -- "$spec") ;;
        esac
        case "$s_name" in
          ""|.|..|dev|.bashrc|.bashrc.user|.gitconfig|.nixct|*/*|-*)
            echo "develop: --share: refusing name $s_name" >&2
            echo "  (must not be empty, contain a slash, start with a dash," >&2
            echo "   or collide with a framework-managed entry)" >&2
            exit 2 ;;
        esac
        for t_name in "''${tpl_names[@]+''${tpl_names[@]}}"; do
          if [ "$t_name" = "$s_name" ]; then
            echo "develop: $s_name is both a --template and a --share" >&2
            exit 2
          fi
        done
        if ! s_host=$(realpath -- "$s_host" 2>/dev/null) || [ ! -d "$s_host" ]; then
          echo "develop: --share: not a directory: ''${spec%:*}" >&2; exit 2
        fi
        bind_workdir "$s_host" "$mount_id.$s_name"
        if [ "$s_native" -eq 1 ] \
           && ! already_mounted "/develop-home/$session_user/$s_name" \
           && use_native "$s_host" "$uid" "$gid" "share $s_name"; then
          bind_native "/hostmnts/$mount_id.$s_name" \
                      "/develop-home/$session_user/$s_name" "$s_mode"
          allow_git_dir "$session_user" "$uid" "$gid" \
                        "/develop-home/$session_user/$s_name" "$fw_git_cfg"
          echo "share: $s_host -> $home_dir/$s_name (native; reflinks work)"
          continue
        fi
        # shellcheck disable=SC2016
        pm exec -u root "$NAME" \
          /run/current-system/sw/bin/bash -lc '
            set -e
            ulimit -n "$(ulimit -Hn)" 2>/dev/null || true
            dst=/develop-home/$1/$5
            src=/hostmnts/$2
            ro_flag=""
            [ "$6" = "ro" ] && ro_flag="-r"
            mkdir -p "$dst"
            if ! mountpoint -q "$dst"; then
              # shellcheck disable=SC2086
              bindfs --multithreaded --map=0/$3:@0/@$4 --perms="og=" $ro_flag \
                -o allow_other "$src" "$dst"
            fi
          ' bash "$session_user" "$mount_id.$s_name" "$uid" "$gid" "$s_name" "$s_mode"
        echo "share: $s_host -> $home_dir/$s_name ($s_mode; writes reach the host)"
      done

      # Dev-shell command. In host-daemon mode, build the dev shell
      # through a discoverable profile under the session HOME so the
      # gcroot-keeper can register the resulting store paths as GC
      # roots (protecting them from host nix-collect-garbage for the
      # session lifetime). The --profile build runs as the SESSION
      # user (enforced by systemd-run --uid/--gid below), preserving
      # trust separation. Other modes keep plain `nix develop`.
      develop_cmd='nix develop'
      if [ "$HOST_NIX_DAEMON" = "1" ]; then
        # $HOME expands inside the inner `bash -lc` as the session
        # user, not here - keep it single-quoted.
        # shellcheck disable=SC2016
        develop_cmd='mkdir -p "$HOME/.nixct" && nix develop --profile "$HOME/.nixct/devshell"'
      fi

      # Container-declared developArgs plus any --develop-arg from the
      # command line, quoted so values with spaces survive the trip through
      # the inner `bash -lc`.
      for arg in "''${develop_args[@]+''${develop_args[@]}}"; do
        develop_cmd="$develop_cmd $(printf '%q' "$arg")"
      done

      # Hand the joiner registration over to the scope itself: by the time
      # this runs, the scope exists, so the watchdog can see a live shell.
      # Dropping the marker any earlier would reopen the window this is
      # meant to close. Runs as the session user, which owns nothing here -
      # the marker is world-writable-by-owner-root only in /run, so remove
      # it best-effort and let the watchdog's staleness sweep catch the
      # rest.
      develop_cmd="rm -f $joiner_marker 2>/dev/null; $develop_cmd"


      # --git-serve: the project reaches the session as a git remote rather
      # than a mount. Bridged the same way the ssh-agent is - a host unix
      # socket bound into the container - with a TCP proxy on the far side
      # because git:// has no unix-socket form. The container has its own
      # netns, so that port is reachable by nothing else.
      if [ -n "$git_serve_branch" ]; then
        start_git_server "$mount_id" "$hostpath" \
                         "$git_serve_branch" "$git_serve_glob" || exit 1
        bind_socket "$mount_id" "git" "$STATE_DIR/git-serve/$mount_id.sock"
        spawn_tcp_proxy "$mount_id" "git" 9418
        extra_setenv+=(--setenv="NIXCT_GIT_REMOTE=git://127.0.0.1/")
        # Cloned for the session, not left to it: ~/dev is where `nix
        # develop` runs, so an empty one would just fail to find a flake.
        # Done as the session user so the working tree is its own.
        # shellcheck disable=SC2016
        if ! pm exec -u root "$NAME" \
             /run/current-system/sw/bin/setpriv \
               --reuid="$uid" --regid="$gid" --clear-groups \
               /run/current-system/sw/bin/bash -c '
                 set -e
                 export PATH=/run/current-system/sw/bin:/run/wrappers/bin
                 # setpriv changes credentials, not the environment, so
                 # HOME is still the one root had; git would go looking in
                 # /root for its config and warn about every file there.
                 export HOME=$3
                 command -v git >/dev/null 2>&1 || {
                   echo "develop: --git-serve needs git in the container package set" >&2
                   exit 1
                 }
                 git clone --quiet --branch "$2" "$1" "$3/dev"
               ' bash "git://127.0.0.1/" "$git_serve_branch" "$home_dir"; then
          echo "develop: --git-serve: clone into the session failed" >&2
          exit 1
        fi
        echo "git-serve: $hostpath -> git://127.0.0.1/ in the session"
        echo "  readable: branch $git_serve_branch (every other ref hidden)"
        echo "  pushable: $git_serve_glob"
        echo "  ~/dev is a clone, not a mount; push to reach the host repo"
      fi

      if [ "$forward_agent" -eq 1 ]; then
        # $agent_src was resolved and validated up front, before the git
        # config copy that --translate-gitconfig hooks into.
        #
        # With a policy, what gets forwarded is not the agent but a filtered
        # view of it - and the filter runs HERE, on the host. That placement
        # is the whole point: a filter inside the container would sit on the
        # wrong side of the boundary it enforces, reachable by whatever it
        # is meant to restrain. The container only ever sees the socket the
        # filter serves, and never the real one.
        if [ "''${#agent_allow[@]}" -gt 0 ] || [ "''${#agent_deny[@]}" -gt 0 ]; then
          agent_src=$(start_agent_filter "$mount_id" "$agent_src") || exit 1
        fi
        bind_socket "$mount_id" "ssh-agent" "$agent_src"
        spawn_socket_proxy "$mount_id" "ssh-agent" "$uid" "$gid"
        extra_setenv+=(--setenv="SSH_AUTH_SOCK=/run/sockets/$mount_id/ssh-agent")
      fi

      # Forwards belong to the SESSION, not to the shell that asked for
      # them: no BindsTo on this shell's scope, and the inner watchdog
      # stops them when the last shell is gone. So a second `develop -A`
      # on a live session adds agent forwarding for the new shell (and
      # only that shell gets $SSH_AUTH_SOCK set, ssh-style), while exiting
      # that shell leaves the socket up for the ones still running.
      for spec in "''${sock_specs[@]+''${sock_specs[@]}}"; do
        parsed=$(parse_socket_spec "$spec") || exit 2
        sock_name=$(printf '%s' "$parsed" | sed -n '1p')
        sock_host=$(printf '%s' "$parsed" | sed -n '2p')
        bind_socket "$mount_id" "$sock_name" "$sock_host"
        spawn_socket_proxy "$mount_id" "$sock_name" "$uid" "$gid"
        echo "forward: $sock_host -> /run/sockets/$mount_id/$sock_name"
      done

      if [ -n "$x11_mode" ]; then
        x11_out=$(setup_x11 "$x11_mode" "$mount_id" "$uid" "$gid") || exit 2
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          extra_setenv+=(--setenv="$line")
        done <<<"$x11_out"
        echo "forward: X11 ($x11_mode)"
      fi

      if [ "$wayland" -eq 1 ]; then
        wl_out=$(setup_wayland "$mount_id" "$uid" "$gid") || exit 2
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          extra_setenv+=(--setenv="$line")
        done <<<"$wl_out"
        echo "forward: Wayland"
      fi

      if [ "$wprs" -eq 1 ]; then
        wprs_out=$(start_wprsd "$mount_id" "$uid" "$gid") || exit 2
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          extra_setenv+=(--setenv="$line")
        done <<<"$wprs_out"
        echo "forward: wprs (proxied Wayland; '$(basename "$0") wayland-attach $hostpath' to view)"
      fi

      for hp in "''${host_ports[@]+''${host_ports[@]}}"; do
        case "$hp" in
          ""|*[!0-9]*) echo "develop: --host-port: not a port: $hp" >&2; exit 2 ;;
        esac
        ensure_host_port "$hp"
        echo "host port: 127.0.0.1:$hp in the session -> host 127.0.0.1:$hp"
      done

      if [ "$dbus" -eq 1 ]; then
        dbus_out=$(start_session_dbus "$mount_id" "$uid" "$gid") || exit 2
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          extra_setenv+=(--setenv="$line")
        done <<<"$dbus_out"
        echo "forward: session D-Bus"
      fi

      # Terminal capabilities, so a TUI in the session sees the real
      # terminal rather than podman's bare TERM=xterm.
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        extra_setenv+=(--setenv="$line")
      done <<<"$(term_env)"

      # Spawn the per-session HOST watchdog (waits on a socket
      # uniquely named for this mount_id; tears down host-side
      # binds on receipt of any connection).
      start_session_watchdog "$mount_id"

      # Spawn the per-session IN-CONTAINER watchdog (waits for every
      # session-<id>-*.scope to be gone - i.e. the last shell of this
      # session exited, including reparented daemons - then unmounts the
      # in-container mounts, stops the session's forwards, userdels, and
      # dials the host watchdog so the host side gets dropped too). Both
      # watchdogs are one-shot per session and idempotent.
      watchdog_unit="watchdog-$mount_id.service"
      if ! pm exec -u root "$NAME" \
          /run/current-system/sw/bin/systemctl is-active --quiet \
          "$watchdog_unit" 2>/dev/null; then
        pm exec -u root "$NAME" \
          /run/current-system/sw/bin/systemd-run \
            --unit="$watchdog_unit" \
            --collect --quiet \
            /etc/nix-dev-container/inner-watchdog.sh \
            "$mount_id" "$session_user" >/dev/null
      fi

      # HOST_NIX_DAEMON: create the per-session GC-root subdir (as
      # container root, mode 0700 - outside /develop-home so the
      # session user can't reach it) and spawn the gcroot-keeper.
      # The keeper watches the session HOME, registers store-pointing
      # symlinks here, and (because this dir is bound at an identical
      # path host-side) the host nix-daemon protects those paths from
      # nix-collect-garbage for the session lifetime.
      if [ "$HOST_NIX_DAEMON" = "1" ]; then
        pm exec -u root "$NAME" \
          /run/current-system/sw/bin/mkdir -p "$SESSION_GCROOTS/$mount_id"
        pm exec -u root "$NAME" \
          /run/current-system/sw/bin/chmod 0700 "$SESSION_GCROOTS/$mount_id"
        keeper_unit="gcroot-keeper-$mount_id.service"
        if ! pm exec -u root "$NAME" \
            /run/current-system/sw/bin/systemctl is-active --quiet \
            "$keeper_unit" 2>/dev/null; then
          pm exec -u root "$NAME" \
            /run/current-system/sw/bin/systemd-run \
              --unit="$keeper_unit" --collect --quiet \
              /etc/nix-dev-container/gcroot-keeper.sh \
              "$mount_id" "$session_user" "$SESSION_GCROOTS/$mount_id" >/dev/null
        fi
      fi

      # Wrap the user's shell in a transient .scope unit.
      # --collect: the scope unit is auto-removed when it goes
      #            inactive (after last member exits).
      # --scope:   the spawned process is placed in a new scope,
      #            and any descendants stay in it (so daemons
      #            keep the scope alive after the foreground
      #            shell exits, until they too exit).
      # --uid/--gid + --setenv=HOME=...: shell runs as session
      #            user with the project as HOME.
      # Final activity bump right before the scope exists, so a tight
      # idle timeout can't fire during the last moments of setup.
      mark_activity
      trap restore_term EXIT
      trap 'restore_term; exit 130' INT
      trap 'restore_term; exit 143' TERM
      if [ "$join_state" = "joined" ]; then
        echo "develop: joining live session as shell #$shell_idx (its forwards stay up until the last shell exits)"
      fi
      echo "develop: $hostpath -> $proj_dir (HOME: $home_dir, scope: $scope)"
      pm exec -it -u root "$NAME" \
        /run/current-system/sw/bin/systemd-run \
          --scope --collect --quiet \
          --unit="$scope" \
          --uid="$uid" --gid="$gid" \
          --working-directory="$proj_dir" \
          --setenv="HOME=$home_dir" \
          "''${extra_setenv[@]+''${extra_setenv[@]}}" \
          ${tools.bash} -lc "$develop_cmd"
      ;;
    wayland-attach)
      if [ -z "''${1:-}" ]; then
        echo "usage: $(basename "$0") wayland-attach <host-path>" >&2
        exit 2
      fi
      if ! hostpath=$(realpath -- "$1" 2>/dev/null); then
        echo "wayland-attach: cannot resolve $1" >&2; exit 2
      fi
      mount_id=$(compute_mount_id "$hostpath")
      wprs_attach "$mount_id"
      ;;
    wayland-detach)
      if [ -z "''${1:-}" ]; then
        echo "usage: $(basename "$0") wayland-detach <host-path>" >&2
        exit 2
      fi
      if ! hostpath=$(realpath -- "$1" 2>/dev/null); then
        echo "wayland-detach: cannot resolve $1" >&2; exit 2
      fi
      mount_id=$(compute_mount_id "$hostpath")
      wprs_detach "$mount_id"
      ;;
    boot)
      # ephemeral foreground systemd boot, for debugging the
      # boot sequence. Wipes any persistent container first.
      ENABLE_GPU=0
      ENABLE_OPENGL=0
      force=0
      while [ $# -gt 0 ]; do
        case "$1" in
          --gpu)    ENABLE_GPU=1; shift ;;
          --opengl) ENABLE_OPENGL=1; shift ;;
          -f|--force) force=1; shift ;;
          --) shift; break ;;
          -*) echo "boot: unknown flag $1" >&2; exit 2 ;;
          *)  break ;;
        esac
      done
      # boot removes the running container outright, so it is as
      # destructive to live sessions as down/purge.
      require_no_live_sessions "$cmd" "$force" || exit 1
      if container_exists; then pm rm -f "$NAME" >/dev/null; fi
      ensure_state
      mount_rootfs_lower
      mkdir -p "$HOST_WATCHDOG_DIR"
      plant_store_gcroot
      export ENABLE_OPENGL
      GPU_FLAGS_STR=$(accelerator_flags "$ENABLE_GPU" "$ENABLE_OPENGL")
      export GPU_FLAGS_STR
      migrate_to_keepid
      export USE_KEEP_ID KEEPID_UID KEEPID_GID
      export ROOTFS UPPER WORK MERGED NIX_UPPER NIX_WORK STATE_DIR
      export STORAGE HOST_NIX_STORE HOST_NIX_DAEMON
      export FUSE_BIN REDIRECT_ROOT NIX_STORE_LOWER
      export PODMAN_ROOT PODMAN_RUNROOT NAME WORK_SHARED SOCKET_MOUNTS
      export HOST_WATCHDOG_DIR
      podman unshare "${tools.bash}" <<'INNER'
  set -euo pipefail

  # Mount the rootfs base + provision /nix (per the storage/host-nix axes).
  ${storeLib.mountAll}

  # WORK_SHARED + SOCKET_MOUNTS rshared so develop binds propagate.
  if ! mountpoint -q "$WORK_SHARED"; then
    mount --bind "$WORK_SHARED" "$WORK_SHARED"
  fi
  mount --make-rshared "$WORK_SHARED"
  if ! mountpoint -q "$SOCKET_MOUNTS"; then
    mount --bind "$SOCKET_MOUNTS" "$SOCKET_MOUNTS"
  fi
  mount --make-rshared "$SOCKET_MOUNTS"
  GPU=()
  if [ -n "''${GPU_FLAGS_STR:-}" ]; then
    # shellcheck disable=SC2206
    GPU=($GPU_FLAGS_STR)
  fi
  USERNS=()
  if [ "''${USE_KEEP_ID:-0}" = "1" ]; then
    USERNS=(
      --userns=keep-id:uid="$KEEPID_UID",gid="$KEEPID_GID"
      --user=0:0
    )
  fi
  trap '${storeLib.unmount}' EXIT
  exec podman --root "$PODMAN_ROOT" --runroot "$PODMAN_RUNROOT" \
    ${ociRuntimeFlag} run --rm -it \
    "''${USERNS[@]+''${USERNS[@]}}" \
    --name "$NAME" \
    --systemd=always \
    --cgroupns=host \
    --cap-add=SYS_ADMIN \
    --cap-add=NET_RAW \
    --cap-add=NET_ADMIN \
    --device=/dev/fuse \
    --security-opt unmask=/sys/fs/cgroup \
    --security-opt systempaths=unconfined \
    --security-opt label=disable \
    --ulimit nproc=-1:-1 \
    --ulimit "nofile=$NOFILE_SOFT:$NOFILE_HARD" \
    --pids-limit=-1 \
    --shm-size=1g \
    --hostname "$NAME" \
    -v "$WORK_SHARED:/hostmnts:rshared" \
    -v "$SOCKET_MOUNTS:/var/socket-mounts:rshared" \
    -v "$HOST_WATCHDOG_DIR:/var/host-watchdog" \
    "''${GPU[@]+''${GPU[@]}}" \
    --rootfs "$MERGED" \
    /init
  INNER
      ;;
    purge)
      force=0
      while [ $# -gt 0 ]; do
        case "$1" in
          -f|--force) force=1; shift ;;
          *) echo "$cmd: unknown flag $1" >&2; exit 2 ;;
        esac
      done
      require_no_live_sessions "$cmd" "$force" || exit 1
      tear_down
      # Defense in depth beyond the NAME check above: STATE_DIR itself
      # is also directly runtime-overridable (the `${"\${STATE_DIR:-...}"}`
      # in stateDirLine), so a mistyped/misconfigured env var could
      # otherwise point this rm -rf at an arbitrary path. The one thing
      # guaranteed true across every stateDirLine variant (default,
      # ephemeral/nixct, portable) is that it ends in "/$NAME" - NAME
      # itself is already validated non-empty and slash-free above.
      case "$STATE_DIR" in
        */"$NAME") ;;
        *) echo "error: refusing to purge STATE_DIR that doesn't end in /\$NAME: '$STATE_DIR'" >&2; exit 1 ;;
      esac
      # Further defense in depth: rm -rf recurses into whatever is
      # actually there, trusting the checks above alone to have gotten
      # STATE_DIR right. Instead, enumerate its TOP-LEVEL entries and
      # refuse to touch anything if even one isn't in the closed set
      # this framework is known to create there - if STATE_DIR were
      # ever misdirected despite the checks above, real user files
      # wouldn't match this allowlist and purge would abort instead of
      # deleting them. Contents *below* the top level are framework-
      # generated (nix store paths, container ids, ...) and can't be
      # enumerated the same way, so this bounds the blast radius to
      # exactly the directories nix-dev-container itself creates.
      podman unshare ${tools.bash} -c '
        set -euo pipefail
        state_dir=$1
        [ -d "$state_dir" ] || exit 0
        allowed="
          upper work merged nix-store-upper nix-store-work
          nix-store-lower.gcroot work-shared socket-mounts host-ports
          podman-root podman-runroot host-watchdog session-gcroots
          wprs-viewers wayland-acl native-acl agent-filter git-serve lower-mount fuse-store fuse-store.log
          .idle-activity .idle-monitor.lock .keepid-migrated
        "
        # Collapse the list to single-space-separated words: the literal
        # above is multi-line, and the membership test below matches on
        # " $name " - without this, every entry sitting at the end of a
        # line (session-gcroots, socket-mounts, ...) is followed by a
        # newline rather than a space and never matches, so purge aborts.
        allowed=" $(printf "%s" "$allowed" | tr -s "[:space:]" " ") "
        for entry in "$state_dir"/* "$state_dir"/.[!.]*; do
          [ -e "$entry" ] || continue
          name=$(basename -- "$entry")
          case "$allowed" in
            *" $name "*) ;;
            *)
              printf "error: purge: unexpected entry in STATE_DIR, refusing to delete anything: %s\n" "$entry" >&2
              exit 1
              ;;
          esac
        done
        for name in $allowed; do
          rm -rf -- "$state_dir/$name"
        done
        rmdir -- "$state_dir" 2>/dev/null || true
      ' bash "$STATE_DIR"
      ;;
    status)
      if container_running; then
        echo "$NAME: running"
      elif container_exists; then
        echo "$NAME: stopped (mount-ns gone)"
      else
        echo "$NAME: not created"
      fi
      echo "shell user: $SHELL_USER"
      echo "storage:    $STORAGE"
      echo "nix store:  $(store_summary)"
      if [ "$HOST_NIX_DAEMON" = "1" ]; then
        echo "  host /nix mounted ro (store + db + daemon socket)"
        if [ -d "$SESSION_GCROOTS" ]; then
          echo "session gcroots:"
          for d in "$SESSION_GCROOTS"/*; do
            [ -d "$d" ] || continue
            # `|| n=0` keeps errexit from aborting status if the count
            # pipeline ever fails (e.g. a torn-down session mid-listing).
            n=$(find "$d" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d '[:space:]') || n=0
            echo "  $(basename "$d") ($n roots)"
          done
        fi
      elif [ "$HOST_NIX_STORE" = "1" ]; then
        echo "  farm:       $NIX_STORE_LOWER"
        echo "  redirect:   $REDIRECT_ROOT"
        echo "  fuse bin:   $FUSE_BIN"
        if [ -e "$NIX_STORE_LOWER_GCROOT" ]; then
          echo "  gc root:    planted ($NIX_STORE_LOWER_GCROOT)"
        else
          echo "  gc root:    absent"
        fi
      fi
      echo "rootfs:     $ROOTFS"
      echo "state dir:  $STATE_DIR"
      if [ -d "$WORK_SHARED" ]; then
        echo "develop binds:"
        podman unshare ${tools.bash} -c "
          for d in '$WORK_SHARED'/*; do
            [ -d \"\$d\" ] && mountpoint -q \"\$d\" && \
              echo '  /work/'\$(basename \"\$d\")
          done
        " 2>/dev/null || true
      fi
      if [ -d "$STATE_DIR" ]; then
        du -sh "$UPPER" "$NIX_UPPER" 2>/dev/null || true
      fi
      ;;
    logs)
      pm logs -f "$NAME"
      ;;
    check-host-compat)
      # Probe whether this host is ready to run the container. Useful
      # before `up` on a fresh / unfamiliar machine. The probe script
      # itself is self-contained — no container is touched.
      exec ${checkHostCompatPath} "$@"
      ;;
    *)
      cat >&2 <<EOF
  usage: $(basename "$0") {up|down|enter|develop|wayland-attach|wayland-detach|exec|boot|status|logs|purge} [args]

  subcommands:
    up [--gpu] [--opengl]       start the persistent container (idempotent).
                                --gpu     nvidia/CUDA passthrough (CDI via
                                          host's nvidia-container-toolkit if
                                          mkContainer was set with
                                          hostHasNvidiaContainerToolkit = true,
                                          else manual /dev/nvidia* + host
                                          lib bind).
                                --opengl  OpenGL / DRI passthrough (works for
                                          Intel/AMD/Mesa and nvidia-GL alike):
                                          binds /dev/dri/* and the host's
                                          libGL.so* directory.
                                Both must be set at up time; auto-up from
                                enter/develop never enables either.
    down/stop [--force]         stop + remove container; state in $STATE_DIR persists.
                                Refuses while develop sessions are live
                                (they would lose everything outside the
                                project dir); --force does it anyway.
    enter [-A] [-S name=path]   open a login shell as $SHELL_USER;
                                auto-runs up if not running.
      shell                     alias for enter.
    develop [-A] [-S name=path] [hostpath]
                                run it again on a path that already has a
                                live session and you get ANOTHER shell in
                                that same session (see "sessions and
                                shells" below), not an error.
                                bind-mount <hostpath> (default: the current
                                working directory) at /develop-home/<user>/dev
                                (~/dev) in the running container, exec nix
                                develop there as a per-session user. The
                                session HOME (/develop-home/<user>) is a
                                separate writable dir for home-level files.
                                Re-running on the same hostpath reuses the user.
                                When HOST_NIX_DAEMON the session auto-manages
                                GC roots: host store paths used by the
                                session are protected from
                                nix-collect-garbage for the session
                                lifetime, and a .nixct/ dir is created in
                                the project home for the dev-shell profile.
    wayland-attach <hostpath>    start (or reuse) a host-side wprsc viewer
                                for a develop session started with --wprs.
                                Requires wprsc on the host's \$PATH.
    wayland-detach <hostpath>    stop the wprsc viewer for that session;
                                the session's apps and wprsd keep running.
    exec -- CMD...              run CMD inside the container as $SHELL_USER.
    boot [--force]              ephemeral foreground systemd (debugging);
                                wipes any existing persistent container first.
    status                      show container state and disk usage.
    logs                        tail container logs.
    purge [--force]             down + wipe \$STATE_DIR. Same live-session
                                refusal as down.
    check-host-compat           probe host for required binaries,
                                kernel features, fuse, rootless setup.

  sessions and shells (develop):
    A SESSION is per project path: the session user, its HOME, the project
    bind, templates, forwards and watchdogs. Each \`develop\` on that path
    adds a SHELL to it (its own scope), so you can open a second one while
    the first is running - and give the new one different flags. Forwards
    belong to the session, not the shell that asked: adding -A later sets
    \$SSH_AUTH_SOCK for that shell only (shells already running can still
    reach the socket by path, ssh-style), and exiting it leaves the socket
    up for the others. The session tears down when its LAST shell exits;
    joining and tearing down are serialized, so a shell arriving as a
    session ends either keeps it alive or waits and gets a fresh one.

  forwarding flags (enter and develop):
    -A, --forward-agent         forward the host \$SSH_AUTH_SOCK.
                                Sets SSH_AUTH_SOCK in the session env.
    --x11                       trusted X11 forwarding (ssh -Y style):
                                forwards the socket for \$DISPLAY and
                                injects the host's cookie. Sets DISPLAY
                                and XCOOKIE; the container's shell-init
                                registers the cookie under DISPLAY.
    --x11-untrusted             untrusted X11 forwarding (ssh -X style):
                                generates a fresh SECURITY-extension
                                cookie on the host (requires the host
                                X server to support SECURITY).
    --wayland                   forward \$WAYLAND_DISPLAY (\$XDG_RUNTIME_DIR/
                                wayland-0 by default). Sets WAYLAND_DISPLAY
                                to the in-container proxied path.
    -S, --socket name=hostpath  generic socket forward. Container side
                                path is /run/sockets/<ns>/<name>; no
                                env is auto-set (do it in your shell).

  develop-only flags:
    --host-port PORT            make the HOST's 127.0.0.1:PORT reachable at
                                the same address inside the session, bridged
                                through a unix socket so the connection to
                                the service is opened by a host process
                                owned by you. Loopback services that
                                authenticate the caller by uid (via
                                /proc/net/tcp) therefore still accept it -
                                a plain network route would be refused.
                                Repeatable. Shared by all sessions of the
                                container, so anything in it can use the
                                port.
    --share hostpath[:name][:ro|:rw|:native]
                                bind a host directory into the session
                                HOME at ~/<name> (default: its basename),
                                as the REAL directory: writes go through
                                to the host and outlive the session.
                                Default rw. Repeatable. For state a
                                session should accumulate across runs
                                (cargo registry, build caches). \`:native\`
                                is rw on the real filesystem rather than
                                through bindfs - see --native for what
                                that buys and what it costs. Use
                                --template instead when the session must
                                not be able to change it.
    -D, --develop-arg ARG       extra argument for the session's
                                \`nix develop\` (e.g. -D --impure).
                                Repeatable; appended after any the
                                container itself declares.
    --template hostpath[:name]  hand a host directory to the session at
                                ~/<name> (default: its basename) as a
                                frozen template: the host dir is the
                                read-only lower of an overlay whose upper
                                lives only as long as the session. The
                                session can write freely; nothing reaches
                                the host copy and nothing survives the
                                session. Use for state a disposable
                                container must INHERIT (browser profiles,
                                tool logins, caches). Repeatable: different
                                names give separate templates, the same
                                name twice stacks the host dirs as overlay
                                lowers (earlier wins).
    --env KEY=VALUE             set KEY in the session shell. Repeatable.
                                \$HOME in the value expands to the session
                                HOME - the only way to name it, since the
                                session user comes from the project path.
    --native                    mount the project directly instead of
                                through bindfs, so the session gets the
                                real filesystem: reflinks (FICLONE), native
                                mmap, and no FUSE handle ceiling. A FUSE
                                ioctl cannot carry the fd that FICLONE
                                needs, so a copy-on-write filesystem
                                silently degrades to whole-file copies
                                without this. Access comes from an ACL
                                granting the host uid the session user maps
                                to, so ownership is untouched and the host
                                keeps rwx on what a session leaves behind.
                                Probed per directory: without reflink and
                                ACL support it falls back to bindfs on its
                                own, so it is safe to leave on. Costs the
                                bindfs --perms=\"og=\" screen - a plain bind
                                shows the real host permissions - and files
                                a session creates are owned on the host by
                                the mapped subuid. --no-native overrides it.
    --mount-bashrc              copy the host \$HOME/.bashrc into the
                                session HOME as ~/.bashrc.user (0444),
                                sourced by the framework ~/.bashrc.
    --mount-gitconfig           copy the host git config into the session
                                HOME at the same place it sits on the host
                                - ~/.gitconfig or ~/.config/git/config
                                (0444). git reads both as global scope, so
                                the framework takes whichever is left for
                                its own stanza (see --native). Both skip
                                silently if the host file is absent.
    --translate-gitconfig       like --mount-gitconfig, but rewrite the
                                forwarded agent socket path on the way in:
                                a host config naming the socket by path
                                (an IdentityAgent in a core.sshCommand, a
                                signing helper pointed at it) carries a
                                path the session does not have, where the
                                same agent lives at
                                /run/sockets/<id>/ssh-agent. Needs -A or
                                --agent; a config using \$SSH_AUTH_SOCK is
                                already correct and is left alone.
    --wprs                      run wprsd INSIDE the session instead of
                                sharing the real Wayland socket (what
                                --wayland does): the untrusted session
                                user only ever talks to its own proxied
                                compositor. Requires a wprs package
                                (wprsd) in this container's package set.
                                Mutually exclusive with --wayland. View
                                with \`wayland-attach <hostpath>\` from
                                another terminal once the session is up.
                                Native-Wayland apps only for now (XWayland
                                is disabled to avoid a wprsd hard-crash
                                when it's not on the container's \$PATH).
    --dbus                      start a per-session D-Bus session daemon
                                and set DBUS_SESSION_BUS_ADDRESS. Many
                                GUI apps assume a working session bus
                                and misbehave without one in ways that
                                don't look like a D-Bus error (e.g.
                                broken keyboard/IME handling). Requires
                                a dbus package (dbus-daemon) in this
                                container's package set.

  env:
    NAME             container name              (default $DEFAULT_NAME)
    STATE_DIR        host state directory        (default \$XDG_STATE_HOME/nix-dev-container/\$NAME)
    The /nix provisioning is driven by three ORTHOGONAL axes. STORAGE and
    HOST_NIX_STORE are runtime-overridable; HOST_NIX_DAEMON is fixed at
    build time (coupled to the NixOS host-daemon profile).
    STORAGE          ephemeral|overlay|directory (build default: $STORAGE)
                       ephemeral - rootfs overlay upper/work on tmpfs
                                   (wiped on stop)
                       overlay   - rootfs overlay upper/work on disk
                                   (persists across stop/start)
                       directory - no overlay; \$MERGED is a materialized
                                   writable real copy of the rootfs
    HOST_NIX_STORE   0|1 (build default: $BUILT_HOST_NIX_STORE). When 1, the
                       host store is served through the nix-store-shared-fuse
                       symlink farm (RO) with a writable fuse-overlayfs upper
                       (RO bind in directory mode). Requires FUSE_BIN +
                       NIX_STORE_LOWER. Ignored when HOST_NIX_DAEMON=1.
    HOST_NIX_DAEMON  0|1 (build default: $BUILT_HOST_NIX_DAEMON, FIXED). When 1,
                       the whole host /nix is rbind-mounted read-only (store +
                       db + daemon socket) and builds delegate to the host
                       daemon. Coupled to the NixOS host-daemon module profile
                       (no in-container daemon / nixbld users); cannot be
                       toggled at runtime.
    FUSE_BIN         absolute path to nix-store-shared-fuse (HOST_NIX_STORE).
    REDIRECT_ROOT    physical store root the FUSE reads from (default $REDIRECT_ROOT).
    NIX_STORE_LOWER  symlink-farm store path = FUSE bind_target and GC-root
                       target (HOST_NIX_STORE; empty otherwise).
    NIXCT_IDLE_TIMEOUT idle-stop timeout in seconds (build default: $BUILT_IDLE_TIMEOUT,
                       0 = disabled). When > 0 the container auto-stops
                       after that many seconds with no active develop session.
  EOF
      exit 2
      ;;
  esac''
