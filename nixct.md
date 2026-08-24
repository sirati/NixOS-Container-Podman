# `nixct` — the develop container

`nixct` is one preset built on the primitives in this repo: a host-nix-daemon,
develop-only container whose entry point is `nixct develop`. It is a product of
`lib.mkContainer`, not what the repo is for — see the [README](README.md) for
the primitives themselves.

```nix
inputs.nixos-container-podman.url = "github:sirati/NixOS-Container-Podman";

# your own nixct
nixos-container-podman.lib.x86_64-linux.mkNixct {
  name     = "nixct";
  packages = [ pkgs.ripgrep ];
}
```

## `nixct develop` sessions

How a develop session is put together, and every flag it takes. All of
this works for any `mkContainer` container; `nixct` is just the preset
whose only entry point is this.

### Sessions and shells

A **session** is per project path — the session user, its HOME, the project
bind, any templates, the forwards and the watchdogs all belong to it. It is
named after the path, encoded so it stays reversible: `/` becomes `-` and a
real `-` doubles, so `/a/b-c` (`a-b--c`) and `/a-b/c` (`a--b-c`) cannot land on
the same session. A short hash is appended only for a path that will not
survive the encoding — one holding a character outside `[A-Za-z0-9._-]`, or
too long for a 255-character user name. Each
`develop` on that path adds a **shell** to that session, in its own scope. So
running `develop` again while one is live opens a second shell rather than
failing, and the new shell may carry different flags:

```sh
nixct develop ~/project        # shell 1
nixct develop -A ~/project     # shell 2, this one with agent forwarding
```

Forwards belong to the session, not to the shell that requested them — the
same shape as sshing into a box twice, once with `-A`:

- only the shell that passed `-A` gets `$SSH_AUTH_SOCK` set; shells already
  running can still reach the socket by path if they want it (same user);
- exiting the `-A` shell does **not** take the socket down — it stays for the
  shells still running;
- the session (and with it the forwards, the home and the user) is torn down
  when its **last** shell exits.

Joining and tearing down are serialized against each other under a per-session
lock: a shell arriving just as the last one leaves either pins the session
(teardown aborts) or waits for teardown to finish and gets a clean new
session. It can never land in one that is being dismantled.

### Forwarding flags (`enter` and `develop`)

- `-A` / `--forward-agent` — forward the host `$SSH_AUTH_SOCK`.
- `--x11` — trusted X11 forwarding (ssh `-Y` style).
- `--x11-untrusted` — untrusted X11 forwarding (ssh `-X` style).
- `--wayland` — forward `$WAYLAND_DISPLAY`.
- `-S name=path` — generic socket forward; container side is
  `/run/sockets/<ns>/<name>` (no env auto-set).

### `--native` (`develop` only) — the real filesystem, not FUSE

bindfs rewrites ownership so a session user can write the project. A FUSE
`ioctl` cannot carry the fd `FICLONE` needs, so reflinks are impossible through
it and a copy-on-write filesystem degrades to whole-file copies.

```sh
nixct develop --native ~/project
```

Mounts the project as a plain bind instead. Access comes from an ACL rather
than rewritten ownership: the container id map already gives the session user a
real host uid, so granting *that* uid `rwx` — plus default entries, so you keep
access to what the session creates — lets it in with ownership untouched. An
idmapped mount would be the obvious alternative; the kernel refuses it rootless
(`CAP_SYS_ADMIN` in the superblock's user namespace).

Probed, not assumed: one 4 KiB file, an ioctl, an ACL. A directory failing
either falls back to bindfs and says so, so turning it on cannot break a
session. `--no-native` forces bindfs.

| | bindfs (default) | `--native` |
|---|---|---|
| reflink / `FICLONE` | ✗ | ✓ |
| open-file ceiling | shared FUSE daemon pool | none |
| files a session creates | owned by you | mapped subuid (you keep `rwx`) |
| hidden from other sessions | ✓ (`--perms="og="`) | ✗ — host permissions apply |

Ownership stays with the host, so git and libgit2 reject the repository
(CVE-2022-24765) and nix fetches flakes through libgit2. Each native mount is
therefore recorded as a `safe.directory` in whichever global config
`--mount-gitconfig` did not take. Chowning instead is not an option: a bind
shares the inode, so it would chown your host directory.

Shares take the same mode — `--share hostpath[:name]:native`, or
`mode = "native"` in `sessionShares`.

### `--share hostpath[:name][:ro|:rw|:native]` (`develop` only) — a real shared dir

Binds a host directory into the session HOME at `~/<name>` (default: its
basename) as the **real** directory: writes go through to the host and
outlive the session. Repeatable, `rw` by default.

```sh
nixct develop --share ~/.cache/cargo:.cargo ~/project
```

Use it for state a session should *accumulate* across runs — a cargo
registry, a compiler cache, a shared artifact dir. Do not use it for anything
you would mind a throwaway session corrupting; that is what `--template`
below is for. `:ro` shares the live directory read-only; `:native` is `rw` on the real
filesystem rather than through bindfs (see `--native` above).

A container can declare shares every session gets, via `mkContainer`:

```nix
sessionShares = [{
  host = "$HOME/.cache/cargo";   # expanded at run time, created if missing
  name = ".cargo";
  mode = "rw";                   # default
}];
```

**If the host directory does not exist**, the two forms differ on purpose:

- **declared** (`sessionShares`, `sessionTemplates`) — created for you. It is a
  provisioning statement, so requiring you to pre-create it by hand would be
  friction for nothing.
- **CLI** (`--share`, `--template`) — hard error, exit 2, before any session
  setup: nothing is created and no session starts. Silently creating a
  mistyped path would hand you an empty directory that looks like your cache
  and quietly loses what you expected to find in it.

The source and target are independent — `name` is the target *inside* the
session HOME, and defaults to the source's basename only when omitted:

```sh
nixct develop --share ~/.claudeB:.claude    # host ~/.claudeB is ~/.claude inside
```

`name` must be a single path component (`.claude`, not `.config/claude`), must
not collide with a framework-managed entry (`dev`, `.bashrc`, `.bashrc.user`,
`.gitconfig`, `.nixct`), and the same name cannot be both a share and a
template.

### Terminal capabilities

`TERM`, `COLORTERM` and `TERM_PROGRAM*` are forwarded from the invoking
terminal into `enter` and `develop` sessions, the way ssh does it. Without
that, `podman exec -t` hands the session a bare `TERM=xterm` whatever the
real terminal is, and full-screen TUIs drop to 16 colours and no truecolor.
The container carries a full terminfo database, so the forwarded value
resolves.

`LANG`/`LC_*` are deliberately **not** forwarded: the container has its own
locale archive, and a host locale it does not carry would make every program
warn. Its default is UTF-8 already, which is what TUI drawing needs.

### `--git-serve BRANCH[:PUSH-GLOB]` (`develop` only) — a remote, not a mount

Instead of mounting the project, serve it to the session as a git remote:

```sh
nixct develop --git-serve 'main:main-*' ~/project
```

`~/dev` becomes a **clone**, not the real tree. The session reads only
`BRANCH` — every other ref is hidden, so the rest of the history is not
merely unwritable but invisible — and can push only branches matching
`PUSH-GLOB` (default: `BRANCH` itself). Nothing it does can touch a ref
outside that, and a mistake lands in its own clone rather than in your
working tree.

Both halves are git's own, and neither writes to the served repository:

| | mechanism |
|---|---|
| read | `uploadpack.hideRefs` — hides every ref but `BRANCH` |
| write | a `pre-receive` hook matching the branch against `PUSH-GLOB` |

The split is forced: git refuses to update a *hidden* ref at all, so
`hideRefs` cannot express a push policy wider than one exact branch, and the
hook does that job instead. Both arrive through `GIT_CONFIG_SYSTEM` on the
daemon, so the repository keeps its own config and hooks untouched.

The daemon runs on the **host** and is reached through a unix socket bound
into the container, with a TCP proxy on the far side because `git://` has no
unix-socket form. The container has its own netns, so `127.0.0.1:9418` there
is reachable by nothing else. It is torn down with the session.

Needs `git` in the container package set. Pushing to the branch that is
checked out on the host is refused by git itself (`receive.denyCurrentBranch`),
which is why a postfix glob is the useful shape: the session works on
`main-something` and you merge it yourself.

### `--agent-allow` / `--agent-deny` (`develop` only) — a filtered agent

`-A` forwards the whole agent, which hands a session every key you hold. A
policy forwards a *view* of it instead:

```sh
nixct develop -A --agent-allow 'Github*' ~/project
nixct develop -A --agent-deny 'Sudo*'   ~/project
```

A spec is a SHA256 fingerprint (as `ssh-add -l` prints it, with or without
the `SHA256:` prefix) or a key comment, where `*` globs. Repeatable; the two
are mutually exclusive — with both lists it would be unreadable which way an
unlisted key falls, and that is not a good thing to guess about an ssh key.

Filtered keys are removed from identity listings **and** refused for signing,
so a client that already knows a key blob cannot use it by asking directly.
Refusals never reach the upstream agent, so a key behind a confirmation
prompt does not even flash one up.

Independently of any policy, everything that would *change* the agent is
refused: adding and removing identities, smartcard keys, and locking. A
sandbox with borrowed keys has no business adding one, and locking would be a
denial of service against the agent's real owner. Extensions are refused too
(their semantics cannot be policed); `--allow-extensions` on the binary opts
in.

The filter — [`ssh-agent-filter`](ssh-agent-filter/), a small Rust proxy —
runs **on the host**, one per session, and the container is handed only the
socket it serves. A filter inside the container would sit on the wrong side
of the boundary it enforces. It is torn down with the session by the host
watchdog, so the grant does not outlive what it was granted to.

### `--host-port PORT` (`develop` only) — a host loopback service in the session

Makes the host's `127.0.0.1:PORT` reachable at the same address inside the
session. Repeatable.

```sh
nixct develop --host-port 8787 ~/project
```

Deliberately **not** a network route. Loopback-only services often
authenticate the caller by looking it up in the host's `/proc/net/tcp` and
reading the socket's owner uid — and fail closed when the peer is not there.
A connection made from the container's netns is not in that table at all, so
it would be refused however the packets arrived. So the bridge goes through a
unix socket instead:

```
session → 127.0.0.1:PORT in the container   (socat, container side)
        → unix socket under $SOCKET_MOUNTS  (crosses the namespace)
        → 127.0.0.1:PORT on the host        (socat, host side, as you)
```

The TCP connection the service sees is opened by a host process owned by the
invoking user, which is what such a check asks about.

One bridge per port, shared by every session of the container — it has a
single netns, so the port can only be bound once. Anything running in the
container can therefore reach that port: it is exactly as trusted as the
service behind it. The host side is torn down with the container.

### `--env KEY=VALUE` (`develop` only) — session environment

Sets `KEY` in the session shell. Repeatable. `$HOME` in the value expands to
the session HOME — the only way to name it, since the session user is derived
from the project path. Nothing else is expanded.

```sh
nixct develop --env 'CLAUDE_CONFIG_DIR=$HOME/.claude' ~/project
```

A container can declare it: `sessionEnv = { CLAUDE_CONFIG_DIR = "$HOME/.claude"; }`.

That example is the useful one for a tool that splits its state between a
directory and a dotfile beside it: a `--share` carries directories, and a file
cannot be shared in its place if the tool rewrites it by rename (which replaces
the inode, so a bind mount or symlink of the file stops tracking it). Pointing
the tool at one directory puts both inside the share.

### `-D, --develop-arg ARG` (`develop` only) — arguments for `nix develop`

Appends an argument to the `nix develop` the session starts with; repeatable.

```sh
nixct develop -D --impure ~/project
```

The container can set defaults that every session gets, with CLI arguments
appended after them:

```nix
developArgs = [ "--impure" ];
```

### `--template hostpath[:name]` (`develop` only) — inherited state, frozen

A session HOME is wiped when the session ends, and with ephemeral storage the
whole container goes with it. So state that a *disposable* container must
**inherit** — tool logins, browser profiles, caches — has to live on the host.
Handing it over as a plain read-write bind would be the easy answer and the
wrong one: every throwaway session would get a writable channel into shared,
credential-bearing state, able to corrupt it for later sessions or persist
into it.

`--template` hands it over frozen instead:

```
lower  = the host directory, bound in read-only
upper  = a fresh per-session dir on the container's own filesystem
         (tmpfs, with ephemeral storage)
mount  = fuse-overlayfs at ~/<name>
```

The session sees an ordinary writable directory — which is what a browser
profile or a tool's state dir needs — but every write lands in the upper and
is discarded when the session ends. Two sessions never see each other's
writes, and the host copy cannot be modified at all.

```sh
nixct develop --template ~/.local/state/mytool:.mytool ~/project
```

Repeatable: different names give separate templates; **the same name twice
stacks** the host dirs as overlay lowers (earlier wins), so a base template
can be layered with a more specific one. Names colliding with
framework-managed entries (`dev`, `.bashrc`, `.nixct`, …) are rejected, and
teardown unmounts every mount under the home — dot-named ones included —
before wiping it.

A container can also declare templates every session gets, via `mkContainer`:

```nix
sessionTemplates = [{
  host = "\${XDG_STATE_HOME:-$HOME/.local/state}/mytool";  # expanded at run time
  name = ".mytool";
}];
```

Writing the template is deliberately *not* something a dev session can do —
that is a separate, explicit act (e.g. a session whose project **is** the
state dir, where the normal read-write project bind applies).

### `--wprs` (`develop` only) — proxied Wayland instead of a raw socket share

`--wayland` shares the host's real compositor socket directly with the
session — full protocol access (SCM_RIGHTS fd-passing, and whatever else the
compositor exposes to any client) granted to a throwaway, untrusted
per-session user. `--wprs` avoids that: it runs
[wprs](https://github.com/wayland-transpositor/wprs)'s `wprsd` **inside** the
session as its own tiny compositor, and only forwards wprsd's own wire
protocol out to the host — the session never touches the real socket.

wprs is **not** a dependency of this flake; it's optional and BYO on both
ends:

- the container needs a `wprsd`-providing package in its own package set
  (e.g. `programs.nixct.packages = [ pkgs.wprs ];` for `nixct`, or via
  `modules` for a plain `mkContainer`);
- the host needs `wprsc` on `$PATH`.

Usage:

```sh
nixct develop --wprs ~/project     # inside: WAYLAND_DISPLAY=wprs-0
nixct wayland-attach ~/project     # from another terminal: view it
nixct wayland-detach ~/project     # stop viewing; session keeps running
```

wprsd's embedded XWayland/X11 support is disabled by default (it otherwise
hard-crashes if the container doesn't also have an Xwayland binary on
`$PATH`) — native-Wayland apps only, for now.

**Known limitation**: the current wprs snapshot only supports shared-memory
buffers — it has no `linux-dmabuf`/hardware-rendering support (this is
documented upstream). Simple Wayland clients work fine; complex GUI apps that
lean on GPU-accelerated compositing or D-Bus-dependent subsystems (e.g.
keyboard/IME handling) may be unstable regardless of `--gpu`/`--opengl` on the
container — that's the client or wprs itself, not this framework's plumbing.
`--dbus` (below) fixes the D-Bus-shaped half of that.

### `--dbus` (`develop` only) — per-session D-Bus session bus

Starts a per-session `dbus-daemon --session` and sets
`DBUS_SESSION_BUS_ADDRESS`. Many GUI apps assume a working session bus and
misbehave without one in ways that don't look like a D-Bus problem on the
surface — Chrome's keyboard/IME handling is one example. Requires a
`dbus`-providing package in the container's package set. Commonly combined
with `--wprs`:

```sh
nixct develop --wprs --dbus ~/project
```

## `nixct` (installable package + NixOS module)

`nixct` is a ready-to-install variant of this framework that ships the `nixct`
command. It is built with `hostNixDaemon = true` and `storage = "ephemeral"` and
is **develop-only**: all builds go to the host nix-daemon and it keeps **no
permanent state** — the overlay upper/work live on tmpfs under
`$XDG_RUNTIME_DIR`, so nothing survives a reboot. There is **no dev user**; the
only entry point is `nixct develop`, which spins up an ephemeral per-session
user. Your project is bind-mounted at `~/dev`, with a separate writable HOME
carrying a framework `~/.bashrc` that enables direnv.

### Installing

From a NixOS system flake, add this flake as an input and either drop the
package in `environment.systemPackages`:

```nix
inputs.nixos-container-podman.url = "github:sirati/NixOS-Container-Podman";

# in your configuration:
environment.systemPackages = [
  inputs.nixos-container-podman.packages.x86_64-linux.nixct
];
```

or — preferred, since it is configurable — import the module and enable it:

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

- `enable` — install the `nixct` binary system-wide.
- `name` — container name (default `nixct`).
- `idleTimeoutSeconds` — stop the container after this many seconds with no
  active `nixct develop` session (default `600`; `0` disables; ignored when
  `service.enable = true`).
- `gpu.enable` — GPU/OpenGL passthrough (the user service runs
  `nixct up --gpu --opengl`).
- `gpu.hostHasToolkit` — use the host's nvidia-container-toolkit (CDI) for
  `--gpu`.
- `service.enable` — run a per-user systemd service that starts nixct on login
  and keeps it up (disables idle shutdown).
- `service.upgradeOnSwitch` — `nixos-rebuild switch` activates the new system
  inside the running container (default `true`, see below).
- `service.restartOnSwitch` — let a switch stop and start it instead, killing
  live sessions (default `false`).
- `package` — the built nixct package; defaults to one built from the options
  above.

### `nixos-rebuild switch` upgrades the container in place

By default a rebuild **upgrades the running container without stopping it**.
Nothing restarts, and every live `nixct develop` session keeps running.

This works because `nixct` takes its whole `/nix` from the host daemon: a
container system built during the rebuild is already realised inside the
container, so it can simply be activated — the same thing `nixos-rebuild` does
on a real machine. The unit is marked `X-ReloadIfChanged`, so the switch
reloads it, which runs:

```sh
nixct switch      # activate this build inside the running container
```

Activation is `switch-to-configuration test`: the container has no bootloader,
and its `/nix/var` is the host's profile directory mounted read-only, so no
system profile is touched. Develop sessions live in transient scopes, which
activation does not restart. A no-op if the container is not running, or is
already on that system.

Only host-nix-daemon containers can do this; anything with a baked rootfs has
nothing to swap under a live container and must be restarted to pick up a new
build (`nixct switch` says so and exits non-zero).

- `service.upgradeOnSwitch = false` — leave a running container strictly alone;
  the new system then applies at its next start.
- `service.restartOnSwitch = true` — the old behaviour: switch stops and starts
  it, killing live sessions.

### Lifecycle

The container auto-starts on the first `nixct` call. By default it auto-stops
after `idleTimeoutSeconds` once there is no active `nixct develop` session;
override at runtime with the `NIXCT_IDLE_TIMEOUT` env var. With
`programs.nixct.service.enable = true` a per-user `systemd --user` service
(`Type=oneshot`, `RemainAfterExit`) brings it up on login and keeps it running
for the login session, disabling idle shutdown.

### Dotfile mounts

`nixct develop` can pull in a couple of host dotfiles, both opt-in:

- `--mount-bashrc` copies the host `~/.bashrc` into the session as read-only
  `~/.bashrc.user`, which the framework `~/.bashrc` sources (it always sets up
  direnv regardless).
- `--mount-gitconfig` copies the host git config in read-only, to the same place
  it sits on the host. git reads `~/.gitconfig` and `$XDG_CONFIG_HOME/git/config`
  both as global scope, so the framework takes whichever is left for its
  `safe.directory` stanza (see
  [`--native`](#--native-develop-only--the-real-filesystem-not-fuse)).
- `--translate-gitconfig` does the same and rewrites the `-A` agent socket path
  to the one the session has (`/run/sockets/<id>/ssh-agent`) — for a config that
  names the agent by path rather than by `$SSH_AUTH_SOCK`.

Both skip silently if the host file is absent.

### Usage

```sh
nixct develop ~/some/project
```

## GC roots in host-daemon develop sessions


With `hostNixDaemon = true` the store paths built during a `develop` session
land in the **host** store. To keep a concurrent host `nix-collect-garbage` from
deleting paths the live session still needs, the framework automatically
registers GC roots — visible to the host daemon — for the symlinks a session
produces:

- `./result*` build outputs,
- `.direnv/*-link` direnv result links,
- the dev-shell profile under `.nixct/devshell`,
- and `nix profile` generations.

These roots are created by an in-container orchestrator running as **container
root**, while the untrusted per-session user keeps building under its own uid.
The roots live in a host-visible directory bind-mounted at an identical
absolute path, so they are real GC roots from the host daemon's perspective.
When the session ends they are **removed automatically** (by the per-session
host watchdog at teardown); the corresponding `gcroots/auto/*` entries become
dangling and nix prunes them on its next GC, so the paths become collectable
again exactly when the session ends.

A `.nixct/` directory is created in the project to hold the dev-shell profile.

