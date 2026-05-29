# nix-dev-container

A framework for building **rootless podman containers that run a full NixOS
system**. You describe the container as an ordinary NixOS configuration and the
framework turns it into a podman-driven dev environment via
`lib.mkContainer { modules; shellUser; name; ... }`. The container boots real
systemd inside a rootless user namespace, mounts the host's `/nix/store`, and
gives you a persistent multi-user box you can enter, run commands in, or use as
a per-project `nix develop` sandbox.

## Quick start

```nix
# flake.nix (downstream)
inputs.nix-dev-container.url = "github:.../nix-dev-container";

outputs = { nixpkgs, nix-dev-container, ... }:
  let
    ct = nix-dev-container.lib.x86_64-linux.mkContainer {
      modules   = [ ./my-system-config.nix ];
      shellUser = "alice";
      name      = "myct";
    };
  in {
    packages.x86_64-linux.myct = ct.packages;
    # nix run .#myct.enter, .#myct.up, .#myct.develop ./path, ...
  };
```

This repo ships example containers: `.#testcontainer` (default overlay mode),
`.#testdaemon` (host-daemon mode), `.#testnvidia`, and `.#nixct-nvidia`.

## Subcommands

Invoke as `nix run .#<container>.<subcommand> -- [args]` (or build the combined
`run` package and call `nix-dev-container <subcommand>`):

- `up [--gpu] [--opengl]` — start the persistent container (idempotent).
  `--gpu` enables nvidia/CUDA passthrough, `--opengl` enables OpenGL/DRI
  passthrough. Both must be set at `up` time; auto-up never enables either.
- `down` / `stop` — stop and remove the container; state in `$STATE_DIR` persists.
- `enter` / `shell` — open a login shell as `shellUser`; auto-runs `up` if needed.
- `develop <hostpath>` — bind-mount `<hostpath>` into the running container and
  `nix develop` there as a fresh per-session user. Re-running on the same path
  reuses the user.
- `exec -- CMD...` — run `CMD` inside the container as `shellUser`.
- `boot` — ephemeral foreground systemd boot for debugging; wipes any existing
  persistent container first.
- `status` — show container state, store mode, and disk usage.
- `logs` — tail container logs.
- `purge` — `down` plus wipe of `$STATE_DIR`.
- `check-host-compat` — probe the host for required binaries, kernel features,
  fuse, and rootless setup. Touches no container.

### Forwarding flags (`enter` and `develop`)

- `-A` / `--forward-agent` — forward the host `$SSH_AUTH_SOCK`.
- `--x11` — trusted X11 forwarding (ssh `-Y` style).
- `--x11-untrusted` — untrusted X11 forwarding (ssh `-X` style).
- `--wayland` — forward `$WAYLAND_DISPLAY`.
- `-S name=path` — generic socket forward; container side is
  `/run/sockets/<ns>/<name>` (no env auto-set).

## `nixStore.mode`

How the container's `/nix/store` is provided (`mkContainer { nixStore.mode = ...; }`):

- `overlay` (default) — host store mounted read-only as the lower layer plus a
  writable fuse-overlayfs upper; in-container installs land in the private
  upper and the host store stays untouched.
- `passthrough` — host store bind-mounted writable in place; container writes
  hit the host store directly.
- `ro` — host store bind-mounted read-only; no installs from inside.
- `host-daemon` — host store mounted read-only **and** the host nix-daemon
  socket bound in. The container runs no nix-daemon and has no nixbld build
  users; every build/query is delegated to the host daemon. This mode is
  coupled to build-time NixOS config and cannot be toggled at runtime.

For a relocated host store (e.g. nix-portable), set `nixStore.hostStore` (the
source for the `/nix/store` mount) and `nixStore.daemonSocket` (the host
nix-daemon socket bound in for host-daemon mode).

`overlay`, `passthrough`, and `ro` can also be switched at runtime via the
`NIX_STORE_MODE` env var; `host-daemon` cannot, since it depends on the
build-time module configuration.

### GC roots in host-daemon develop sessions

In `host-daemon` mode the store paths built during a `develop` session land in
the **host** store. To keep a concurrent host `nix-collect-garbage` from
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

## host-daemon mode

A `nixStore.mode = "host-daemon"` container builds with **no in-container
nix-daemon** and no nixbld users: the host `/nix/store` is mounted read-only and
the host's nix-daemon socket is bound in, so all builds and queries are
delegated to the host daemon. The container's closure must already be realised
in the host's `/nix/store` (it is, since the container is built against it). The
`.#testdaemon` flake attribute is a ready-made example host-daemon container:

```sh
nix run .#testdaemon.enter
nix run .#testdaemon.develop -- ./my-project
```

## Portable tarball

`nix build .#<container>.portable` produces a **self-contained tarball** that
runs on non-NixOS hosts which have nix and podman available. Run
`check-host-compat` first to probe whether a target host meets the
prerequisites before building or deploying the tarball.
