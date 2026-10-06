# `nixct`, the develop container

`nixct` is a container built with `lib.mkContainer`. It uses the host
nix-daemon, is meant only for development, and its entry point is
`nixct develop`. See the [README](README.md) for the functions it is built
from.

```nix
inputs.nixos-container-podman.url = "github:sirati/NixOS-Container-Podman";

# your own nixct
nixos-container-podman.lib.x86_64-linux.mkNixct {
  name     = "nixct";
  packages = [ pkgs.ripgrep ];
}
```

## `nixct develop` sessions

This section describes how a develop session is set up and every flag it takes.
All of it works for any `mkContainer` container; `nixct` only differs in having
`develop` as its sole entry point.

### Sessions and shells

A session belongs to one project path. The session user, its HOME, the project
bind, any templates, the forwards and the watchdogs all belong to the session.

The session is named after the path with a reversible encoding: `/` becomes `-`
and a literal `-` is doubled, so `/a/b-c` (`a-b--c`) and `/a-b/c` (`a--b-c`)
get different sessions. A short hash is appended only when the path contains a
character outside `[A-Za-z0-9._-]` or is too long for a 255-character user name.

Each `develop` on a path adds a shell to that path's session, in its own scope.
Running `develop` again while a shell is live opens a second shell, and the new
shell can use different flags:

```sh
nixct develop ~/project        # shell 1
nixct develop -A ~/project     # shell 2, this one with agent forwarding
```

Forwards belong to the session, not to the shell that asked for them. This
works like logging into a machine twice with ssh, once with `-A`:

- Only the shell started with `-A` gets `$SSH_AUTH_SOCK` set. Other shells run
  as the same user and can use the socket by its path.
- Exiting the `-A` shell does not remove the socket while other shells still
  run.
- The session, with its forwards, home and user, is removed when its last shell
  exits.

Joining and teardown take the same per-session lock. A shell that arrives while
the last one leaves either keeps the session alive, so teardown aborts, or waits
for teardown to finish and gets a new session.

### Forwarding flags (`enter` and `develop`)

- `-A` / `--forward-agent` forwards the host `$SSH_AUTH_SOCK`.
- `--x11` is trusted X11 forwarding, like ssh `-Y`.
- `--x11-untrusted` is untrusted X11 forwarding, like ssh `-X`.
- `--wayland` forwards `$WAYLAND_DISPLAY`.
- `-S name=path` forwards any socket to `/run/sockets/<ns>/<name>` in the
  container and sets no environment variable.

### `--native` (`develop` only), the real filesystem instead of FUSE

```sh
nixct develop --native ~/project
```

This mounts the project with a plain bind instead of bindfs, so reflinks work.
`FICLONE` cannot pass through a FUSE ioctl. The session user's mapped host uid
gets access through an ACL, and ownership does not change. If a directory fails
the probe, `develop` falls back to bindfs and prints that it did. `--no-native`
always uses bindfs.

| | bindfs (default) | `--native` |
|---|---|---|
| reflink / `FICLONE` | no | yes |
| open-file limit | shared by the FUSE daemons | none |
| files a session creates | owned by you | owned by a mapped subuid, you keep `rwx` |
| hidden from other sessions | yes (`--perms="og="`) | no, host permissions apply |

The host user still owns a native mount, so each one is added to git's
`safe.directory`. Without that, git and libgit2 refuse the repository
(CVE-2022-24765) and nix cannot evaluate its flake.

Shares can use the same mode with `--share hostpath[:name]:native` or
`mode = "native"` in `sessionShares`.

### `--share hostpath[:name][:ro|:rw|:native]` (`develop` only), a shared directory

This binds a host directory into the session HOME at `~/<name>`. `name`
defaults to the directory's basename. Writes go to the host directory and remain
after the session ends. The flag can be repeated and defaults to `rw`.

```sh
nixct develop --share ~/.cache/cargo:.cargo ~/project
```

Use it for state that sessions should build up across runs, such as a cargo
registry, a compiler cache or a shared artifact directory. For anything a
throwaway session must not be able to damage, use `--template` below. `:ro`
shares the directory read-only, and `:native` is `rw` with a plain bind instead
of bindfs (see `--native` above).

A container can declare shares that every session gets in `mkContainer`:

```nix
sessionShares = [{
  host = "$HOME/.cache/cargo";   # expanded at run time, created if missing
  name = ".cargo";
  mode = "rw";                   # default
}];
```

If the host directory does not exist, declared shares and templates create it,
while `--share` and `--template` exit with code 2 before setting up the session.

`name` is the target in the session HOME and can differ from the source:

```sh
nixct develop --share ~/.claudeB:.claude    # host ~/.claudeB is ~/.claude inside
```

`name` must be a single path component (`.claude`, not `.config/claude`). It
cannot be one of the entries the framework manages (`dev`, `.bashrc`,
`.bashrc.user`, `.gitconfig`, `.nixct`), and one name cannot be both a share
and a template.

### Terminal capabilities

`enter` and `develop` sessions get the host's `TERM`, `COLORTERM` and
`TERM_PROGRAM*`, as ssh does. The container has a full terminfo database for
them. `LANG` and `LC_*` are not forwarded; the container has its own locale
archive and defaults to UTF-8.

### `--git-serve BRANCH[:PUSH-GLOB]` (`develop` only), a git remote instead of a mount

This serves the project to the session as a git remote instead of mounting it:

```sh
nixct develop --git-serve 'main:main-*' ~/project
```

`~/dev` is a clone, not the project directory. The session can only read
`BRANCH`, since every other ref is hidden, and can only push branches that match
`PUSH-GLOB`. `PUSH-GLOB` defaults to `BRANCH`.

| | mechanism |
|---|---|
| read | `uploadpack.hideRefs` hides every ref except `BRANCH` |
| write | a `pre-receive` hook checks the branch against `PUSH-GLOB` |

Both are set through `GIT_CONFIG_SYSTEM`, so the served repository keeps its
own config and hooks. The git daemon runs on the host, the container reaches it
through a bound unix socket, and it stops with the session.

The container package set needs `git`. git itself refuses pushes to the branch
checked out on the host (`receive.denyCurrentBranch`), so a glob such as
`main-*` is the useful form.

### `--agent-allow` / `--agent-deny` (`develop` only), a filtered agent

`-A` forwards the whole agent and gives the session every key you hold. A
policy forwards only some of the keys:

```sh
nixct develop -A --agent-allow 'Github*' ~/project
nixct develop -A --agent-deny 'Sudo*'   ~/project
```

A spec is a SHA256 fingerprint as `ssh-add -l` prints it, with or without the
`SHA256:` prefix, or a key comment where `*` is a glob. Both flags can be
repeated, but they cannot be combined.

Filtered keys are left out of identity listings and refused for signing, and
the refusals never reach the upstream agent. Requests that change the agent
(adding or removing identities, smartcard keys, locking) are always refused.
Extensions are refused too unless the binary runs with `--allow-extensions`.

[`ssh-agent-filter`](ssh-agent-filter/) runs on the host, one per session, and
the container only gets the socket it serves. It stops with the session.

### `--host-port PORT` (`develop` only), a host loopback service in the session

This makes the host's `127.0.0.1:PORT` reachable at the same address in the
session. The flag can be repeated.

```sh
nixct develop --host-port 8787 ~/project
```

The bridge goes through a unix socket, not a network route, so the TCP
connection the service sees comes from a host process running as you. Services
that check the caller through `/proc/net/tcp` accept it.

```
session → 127.0.0.1:PORT in the container   (socat, container side)
        → unix socket under $SOCKET_MOUNTS  (crosses the namespace)
        → 127.0.0.1:PORT on the host        (socat, host side, as you)
```

There is one bridge per port, shared by every session of the container, so
anything in the container can reach that port. The bridge stops with the
container.

### `--env KEY=VALUE` (`develop` only), session environment

This sets `KEY` in the session shell and can be repeated. `$HOME` in the value
expands to the session HOME, which is the only way to refer to it because the
session user's name comes from the project path. Nothing else is expanded.

```sh
nixct develop --env 'CLAUDE_CONFIG_DIR=$HOME/.claude' ~/project
```

A container can set it with `sessionEnv = { CLAUDE_CONFIG_DIR = "$HOME/.claude"; }`.

This example is for tools that keep state in a directory and a dotfile next to
it. `--share` only carries directories. A file cannot be shared instead if the
tool replaces it by rename, because the rename changes the inode and a bind
mount or symlink keeps pointing at the old one. Pointing the tool at one
directory puts both inside the share.

### `-D, --develop-arg ARG` (`develop` only), arguments for `nix develop`

This appends an argument to the `nix develop` the session starts with and can be
repeated.

```sh
nixct develop -D --impure ~/project
```

A container can set defaults for every session; CLI arguments come after them:

```nix
developArgs = [ "--impure" ];
```

### `--template hostpath[:name]` (`develop` only), read-only inherited state

This gives the session a host directory it can read and appear to write without
changing the host copy. Use it for state a throwaway session needs, such as tool
logins, browser profiles or caches:

```
lower  = the host directory, bound in read-only
upper  = a new per-session directory on the container's own filesystem
         (tmpfs, with ephemeral storage)
mount  = fuse-overlayfs at ~/<name>
```

The session sees a writable directory, but every write goes to the upper and is
deleted when the session ends.

```sh
nixct develop --template ~/.local/state/mytool:.mytool ~/project
```

The flag can be repeated. Different names give separate templates, and the same
name given twice stacks both host directories as overlay lowers, with the
earlier one on top. That lets a specific template sit over a base one. Names of
framework-managed entries (`dev`, `.bashrc`, `.nixct`, …) are rejected.
Teardown unmounts every mount under the home, including dot-named ones, before
deleting it.

A container can declare templates that every session gets in `mkContainer`:

```nix
sessionTemplates = [{
  host = "\${XDG_STATE_HOME:-$HOME/.local/state}/mytool";  # expanded at run time
  name = ".mytool";
}];
```

A develop session cannot update a template. To change one, start a session
whose project is the state directory itself, which uses the normal read-write
project bind.

### `--wprs` (`develop` only), proxied Wayland instead of a shared socket

`--wayland` shares the host's real compositor socket with the session. `--wprs`
runs `wprsd` from [wprs](https://github.com/wayland-transpositor/wprs) in the
session as its own compositor and forwards only wprsd's protocol, so the session
never gets the real socket.

This flake does not depend on wprs. You provide it on both sides:

- The container needs a package with `wprsd` in its package set, for example
  `programs.nixct.packages = [ pkgs.wprs ];` for `nixct`, or through `modules`
  for a plain `mkContainer`.
- The host needs `wprsc` on `$PATH`.

```sh
nixct develop --wprs ~/project     # inside: WAYLAND_DISPLAY=wprs-0
nixct wayland-attach ~/project     # from another terminal: view it
nixct wayland-detach ~/project     # stop viewing; session keeps running
```

wprsd's built-in XWayland support is off by default, so only native Wayland
apps work.

The current wprs snapshot only supports shared-memory buffers and has no
`linux-dmabuf`, so GPU-accelerated clients may be unstable even with `--gpu` or
`--opengl`.

### `--dbus` (`develop` only), a per-session D-Bus bus

This starts a per-session `dbus-daemon --session` and sets
`DBUS_SESSION_BUS_ADDRESS`. Many GUI apps expect a session bus and fail without
one in ways that do not point at D-Bus; Chrome's keyboard and IME handling is
one example. The container package set needs a package with `dbus`. It is often
used with `--wprs`:

```sh
nixct develop --wprs --dbus ~/project
```

## `nixct` (installable package and NixOS module)

The `nixct` package ships the `nixct` command. It is built with
`hostNixDaemon = true` and `storage = "ephemeral"` and only supports develop
sessions. All builds go to the host nix-daemon, and the overlay upper and work
directories are on tmpfs under `$XDG_RUNTIME_DIR`, so nothing survives a
reboot. There is no dev user. `nixct develop` creates a throwaway user per
session, binds the project at `~/dev` and gives the session its own writable
HOME with a `~/.bashrc` that enables direnv.

### Installing

In a NixOS system flake, add this flake as an input. You can put the package in
`environment.systemPackages`:

```nix
inputs.nixos-container-podman.url = "github:sirati/NixOS-Container-Podman";

# in your configuration:
environment.systemPackages = [
  inputs.nixos-container-podman.packages.x86_64-linux.nixct
];
```

The module is configurable, so it is the better choice:

```nix
imports = [ inputs.nixos-container-podman.nixosModules.nixct ];

programs.nixct = {
  enable = true;
  idleTimeoutSeconds = 600;   # stop after 10 min idle; 0 disables
  gpu.enable = true;          # service runs `nixct up --gpu --opengl`
  gpu.hostHasToolkit = true;  # use host nvidia-container-toolkit (CDI)
  # service.enable = true;    # keep it up for the login session instead
};
```

The `programs.nixct` options:

- `enable` installs the `nixct` binary system-wide.
- `name` is the container name (default `nixct`).
- `idleTimeoutSeconds` stops the container after this many seconds without an
  active `nixct develop` session. It defaults to `600`, `0` disables it, and it
  is ignored with `service.enable = true`.
- `gpu.enable` enables GPU and OpenGL passthrough; the user service runs
  `nixct up --gpu --opengl`.
- `gpu.hostHasToolkit` uses the host's nvidia-container-toolkit (CDI) for
  `--gpu`.
- `service.enable` runs a per-user systemd service that starts nixct at login
  and keeps it running, which disables idle shutdown.
- `service.upgradeOnSwitch` makes `nixos-rebuild switch` activate the new system
  in the running container (default `true`, see below).
- `service.restartOnSwitch` makes a switch stop and start the container
  instead, which kills live sessions (default `false`).
- `package` is the nixct package, built from the options above by default.

### `nixos-rebuild switch` upgrades the container in place

By default a rebuild upgrades the running container without stopping it.
Nothing restarts and live `nixct develop` sessions keep running.

`nixct` takes its whole `/nix` from the host daemon, so the container system
built during the rebuild is already in the container's store and can be
activated, as `nixos-rebuild` does on a real machine. The unit has
`X-ReloadIfChanged`, so the switch reloads it, which runs:

```sh
nixct switch      # activate this build inside the running container
```

Activation runs `switch-to-configuration test`. The container has no bootloader
and its `/nix/var` is the host's profile directory mounted read-only, so no
system profile changes. Develop sessions run in transient scopes, which
activation does not restart. `nixct switch` does nothing if the container is not
running or already runs that system.

Only host nix-daemon containers support this. A container with its system in
the rootfs must restart to use a new build, and `nixct switch` says so and exits
non-zero.

- `service.upgradeOnSwitch = false` leaves a running container alone; the new
  system applies at its next start.
- `service.restartOnSwitch = true` restores the old behaviour, where a switch
  stops and starts the container and kills live sessions.

### Lifecycle

The first `nixct` call starts the container. By default it stops after
`idleTimeoutSeconds` without an active `nixct develop` session; the
`NIXCT_IDLE_TIMEOUT` environment variable overrides this at runtime. With
`programs.nixct.service.enable = true`, a `systemd --user` service
(`Type=oneshot`, `RemainAfterExit`) starts it at login, keeps it running for the
login session and disables idle shutdown.

### Dotfile mounts

`nixct develop` can copy host dotfiles into the session. All of these are
opt-in:

- `--mount-bashrc` copies the host `~/.bashrc` into the session as read-only
  `~/.bashrc.user`, which the framework `~/.bashrc` sources. The framework
  `~/.bashrc` sets up direnv either way.
- `--mount-gitconfig` copies the host git config read-only to the same path it
  has on the host. git reads both `~/.gitconfig` and `$XDG_CONFIG_HOME/git/config`
  as global config, so the framework uses the other one for its
  `safe.directory` entry (see
  [`--native`](#--native-develop-only-the-real-filesystem-instead-of-fuse)).
- `--translate-gitconfig` does the same and rewrites the `-A` agent socket path
  to the session's path (`/run/sockets/<id>/ssh-agent`), for a config that names
  the agent by path instead of using `$SSH_AUTH_SOCK`.

Each is skipped without a message if the host file does not exist.

### Usage

```sh
nixct develop ~/some/project
```

## GC roots in host-daemon develop sessions

With `hostNixDaemon = true`, store paths built in a `develop` session go to the
host store. So that a host `nix-collect-garbage` does not delete paths a live
session still uses, the framework registers GC roots that the host daemon sees
for these symlinks:

- `./result*` build outputs
- `.direnv/*-link` direnv result links
- the dev-shell profile under `.nixct/devshell`
- `nix profile` generations

A process in the container running as container root creates these roots, while
the session user keeps building under its own uid. The roots are in a host
directory bind-mounted at the same absolute path, so the host daemon treats
them as real GC roots. The per-session host watchdog removes them at teardown.
The matching `gcroots/auto/*` entries then point nowhere and nix prunes them at
its next GC, so the paths can be collected once the session ends.

`develop` creates a `.nixct/` directory in the project for the dev-shell
profile.
