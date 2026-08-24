# NixOS-Container-Podman

Primitives for running **NixOS systems, and NixOS-built containers, under
rootless podman** — real systemd in a user namespace, described as an ordinary
NixOS configuration. Everything is assembled from nix primitives: a closure, a
symlink farm, a squashfs, a rootfs directory. **There is no OCI image anywhere**
— nothing is pulled, nothing is layered, nothing is tagged.

Most of this repo is meant to be consumed by other nix projects: each primitive
is a flake output you can take on its own, and `mkContainer` is the one that
ties them together.

- **Runs on NixOS, and on any other Linux distribution.** Elsewhere the
  [portable tarball](#portable-tarball) carries its own store and needs no nix
  on the host.
- **Shares the host's `/nix`** — store, database and daemon socket — so a
  container builds through the host's nix-daemon and adds nothing to disk.
- **Or serves a restricted store view** through `nix-store-shared-fuse`: a
  symlink farm of whatever paths you choose, needing no daemon, so a
  single-user nix install can share its store too.
- **Podman command lines are generated from a nix model and validated at eval
  time.** None are written by hand.
- **`mkPrison` builds deny-by-default services**, and is backend agnostic.

`nixct`, a develop container with per-project throwaway users and forwarded
sockets, is one preset built on all of this — see [nixct.md](nixct.md).

## What this repo provides

**1. `lib.mkContainer` — a NixOS system as a rootless podman container.**
NixOS modules in, a rootfs plus a run script out (`up`, `enter`, `exec`,
`boot`, `status`, `logs`, `down`, `purge`). Configured along
[orthogonal axes](#configuration-axes). Nothing about it is dev-container
specific.

**2. `lib.mkPrison` / `lib.mkPrisonService` — deny-by-default confinement.**
Backend agnostic: says what a service may do, never how to run it. See
[`nix/prison/README.md`](nix/prison/README.md).

**3. Layer derivations, separately consumable.** `systemLower`,
`nixStoreLower`, `rootfsFolder` / `rootfsSquashfs`, and a
[portable tarball](#portable-tarball) that runs on a host with no nix at all.

**4. `nix-store-shared-fuse` — a read-only FUSE for a host `/nix/store`.**
Serves a symlink-farm view, so a container sees its own closure and nothing
else. A standalone binary; the `hostNixStore` axis is the framework wiring it
up.

**5. `ssh-agent-filter` — a filtering proxy for the SSH agent protocol.**
Forwards only the keys a policy names; adding, removing and locking are always
refused. A standalone binary, not tied to containers.

**6. `nix/podman.nix` — the podman option model.** Typed nix in, argv out,
validated at eval time. Needs only `lib`, so the portable tarball is generated
from the same model as the NixOS target.

Also included: `check-host-compat`, a standalone probe that tells you whether a
host can run any of this (binaries, kernel features, fuse, rootless setup).

And built on top: [`nixct`](nixct.md), the develop-container preset.

## Quick start

```nix
# flake.nix (downstream)
inputs.nixos-container-podman.url = "github:sirati/NixOS-Container-Podman";

outputs = { nixpkgs, nixos-container-podman, ... }:
  let
    ct = nixos-container-podman.lib.x86_64-linux.mkContainer {
      modules   = [ ./my-system-config.nix ];
      shellUser = "alice";
      name      = "myct";
    };
  in {
    packages.x86_64-linux.myct = ct.packages;
    # nix run .#myct.enter, .#myct.up, .#myct.develop ./path, ...
  };
```

`lib.x86_64-linux` exports `mkContainer`, `mkNixct` and the `overlay` helper.
Example containers: `.#testcontainer` (persistent overlay), `.#testdaemon`
(host nix-daemon), `.#testnvidia`, `.#nixct-nvidia`.

`mkNixct` adds `modules`, `runName`, `sessionTemplates`, `sessionShares` and
`developArgs` — the extension points out-of-tree presets build on.
`nixct-chrome` is one: a separate flake shipping Google Chrome with the Claude
in Chrome extension preinstalled.

## Subcommands

Invoke as `nix run .#<container>.<subcommand> -- [args]` (or build the combined
`run` package and call it as `<runName> <subcommand>`, `nix-dev-container`
by default):

- `up [--gpu] [--opengl]` — start the persistent container (idempotent).
  `--gpu` enables nvidia/CUDA passthrough, `--opengl` enables OpenGL/DRI
  passthrough. Both must be set at `up` time; auto-up never enables either.
- `down` / `stop` `[--force]` — stop and remove the container; state in
  `$STATE_DIR` persists. Refuses while `develop` sessions are live — tearing
  the container down kills them and (with ephemeral storage) takes their
  session HOMEs with it — and names the projects involved. `--force` proceeds
  anyway. Same for `purge` and `boot`.
- `enter` / `shell` — open a login shell as `shellUser`; auto-runs `up` if needed.
- `develop [hostpath]` — bind-mount `<hostpath>` into the running container and
  `nix develop` there as a fresh per-session user. Defaults to the current
  working directory. Re-running on the same path opens another shell in the
  same session (see [sessions and shells](nixct.md#sessions-and-shells)).
- `wayland-attach <hostpath>` — start (or reuse) a host-side `wprsc` viewer for
  a `develop` session started with `--wprs`. Requires `wprsc` on the host's
  `$PATH`.
- `wayland-detach <hostpath>` — stop that viewer; the session's apps and
  `wprsd` keep running untouched.
- `exec -- CMD...` — run `CMD` inside the container as `shellUser`.
- `boot` — ephemeral foreground systemd boot for debugging; wipes any existing
  persistent container first.
- `status` — show container state, store source, and disk usage.
- `logs` — tail container logs.
- `purge` — `down` plus wipe of `$STATE_DIR`.
- `switch` / `upgrade` — activate this build's system inside the **running**
  container, keeping it and its develop sessions up. Host-nix-daemon
  containers only; see
  [rebuilds upgrade in place](nixct.md#nixos-rebuild-switch-upgrades-the-container-in-place).
- `check-host-compat` — probe the host for required binaries, kernel features,
  fuse, and rootless setup. Touches no container.

## Configuration axes

`mkContainer` is configured along **orthogonal axes** — each controls one
independent concern. All are optional; the defaults reproduce the historical
persistent-overlay behavior of the example containers.

### `storage` — writable strategy for the rootfs

How the writable layer over the immutable base is provided:

- `lib.overlay { lower ? "squashfs"; }` **(default)** — overlay with a
  persistent **on-disk** upper under `$STATE_DIR`; in-container changes survive
  across runs.
- `"ephemeral"` — overlay with a **tmpfs** upper under `$XDG_RUNTIME_DIR`; state
  is lost when the container is removed.
- `"directory"` — a materialized writable rootfs with **no overlay** at all.

### `lower` — packaging of the immutable base

`"squashfs"` (default) | `"folder"`. squashfs is the smallest but needs
squashfuse on the host; folder ships plain files. Only meaningful for the
`ephemeral` / overlay storage strategies, and it also selects the portable
tarball format.

### `hostNixStore` / `hostNixDaemon` — where `/nix/store` comes from

By default the container is **self-contained**: its closure is baked into the
immutable lower. Two booleans change the source of `/nix/store`:

- `hostNixStore = true` — `/nix/store` is served from the **host** at runtime by
  a host-side Rust FUSE (`nix-store-shared-fuse`) over a GC-pinned, exact-closure
  symlink farm, instead of being baked into the lower. A writable overlay upper
  is stacked over it so in-container builds still work (in `directory` storage
  the FUSE store is mounted read-only — no overlays). A per-instance host GC root
  pins the closure for the container's lifetime and is released at teardown.
  **Requires `user_allow_other` in the host's `/etc/fuse.conf`** (the FUSE is
  mounted `--allow-other`); `check-host-compat` probes this.
- `hostNixDaemon = true` — delegate every build and query to the **host
  nix-daemon**: the whole host `/nix` is rbind-mounted read-only (store +
  `/nix/var` db + daemon socket), the container runs **no in-container daemon**
  and has **no nixbld users**. The closure must already be realised in the host
  store (it is, since the container is built against it). When this is on,
  `hostNixStore` is ignored. This is what `mkNixct` uses.

The three store sources — self-contained (baked) / `hostNixStore` (FUSE) /
`hostNixDaemon` (rbind) — compose with all three storage strategies. `status`
reports the active source as `self-contained`, `host-store`, or `host-daemon`.

`storage` (the `STORAGE` env) and `hostNixStore` (the `HOST_NIX_STORE` env) can
be switched at runtime; `hostNixDaemon` (`HOST_NIX_DAEMON`) is **fixed at build
time**, since it is coupled to the in-container NixOS host-daemon profile.

### Other axes

- `gpu.hostHasToolkit` — `up --gpu` uses the host nvidia-container-toolkit (CDI,
  `--device nvidia.com/gpu=all`) instead of manual `/dev/nvidia*` binds.
- `keepId.enable` / `keepId.uid` / `keepId.gid` — `--userns=keep-id` so
  `shellUser` maps 1:1 to the invoking host user (uid/gid default `1000`/`100`).
- `modules`, `shellUser`, `name`, `runName`, `idleTimeout` — as in the quick
  start; `idleTimeout` (seconds, `0` disables) stops the container after no
  active `develop` session.

### Example: host nix-daemon container

```nix
ct = nixos-container-podman.lib.x86_64-linux.mkContainer {
  modules       = [ ./my-system-config.nix ];
  shellUser     = "alice";
  name          = "myct";
  hostNixDaemon = true;          # /nix from the host daemon, no nixbld users
};
```

The `.#testdaemon` flake attribute is a ready-made example:

```sh
nix run .#testdaemon.enter
nix run .#testdaemon.develop -- ./my-project
```


### GC roots in host-daemon develop sessions

A `develop` session in a host-daemon container registers the store paths it
uses as gc roots for its lifetime, so a host `nix-collect-garbage` cannot
collect the shell out from under it. See
[nixct.md](nixct.md#gc-roots-in-host-daemon-develop-sessions).
### `isolateLan` (build-time) — no route to the local network

A rootless container gets its network from **pasta**, which hands the
namespace a *copy* of the host interface — same address, same on-link route.
So by default a session can open a connection to anything the host can reach
locally. With a forwarded ssh-agent that is a way out: the agent cannot be
aimed at the host itself (loopback is not mapped), but it can be aimed at
every other machine on the LAN that trusts those keys.

```nix
mkNixct { isolateLan = true; }        # or programs.nixct.isolateLan = true;
```

**The filter is not in the container.** A second, near-empty container — the
gateway — owns the network namespace and runs nothing but `sleep`. The dev
container joins that namespace with `--network=container:<name>-net`, so it
has no namespace of its own to reconfigure, and the host loads the ruleset
into the namespace with `nsenter` before anything joins it. Neither container
polices itself.

What makes it hold is the capability set, which is decided by the host and
cannot be widened from inside: with `isolateLan` the dev container is started
**without `CAP_NET_ADMIN`**. A process that unshares a fresh user namespace
becomes root only over what *that* namespace owns, which is not this network
namespace. Measured inside a running container:

```
CapEff = 00000000802425fb     → NET_ADMIN absent
# ip link add dummy0 type dummy
RTNETLINK answers: Operation not permitted
```

The ruleset refuses RFC1918, CGNAT/tailnet (`100.64.0.0/10`), link-local and
IPv6 ULA; loopback and the public internet stay reachable. `reject`, not
`drop`, so a blocked connect fails at once instead of hanging until the TCP
timeout. `isolateLan.allow` / `.allow6` punch holes; `.resolver` (default
`169.254.1.1`, pasta's own DNS forwarder) is permitted ahead of the
link-local refusal, since refusing it would take DNS down with the LAN:

```
LAN gateway 192.168.176.1:80   -> blocked
LAN host    192.168.176.38:22  -> blocked
tailnet   100.100.100.100:53   -> blocked
public          1.1.1.1:443    -> REACHABLE
DNS                            -> OK
```

## Portable tarball

`nix build .#<container>.portable` produces a **self-contained tarball** that
runs on non-NixOS hosts with rootless podman + fuse-overlayfs (and squashfuse
for the squashfs layout) — no Nix required on the host. The `lower` axis
selects its layout (`"squashfs"`, default — needs squashfuse on the host — or
`"folder"`, plain files). Run `check-host-compat` first to probe whether a
target host meets the prerequisites before building or deploying the tarball.

A portable tarball is **self-contained only**: `hostNixStore` and
`hostNixDaemon` containers have no portable target (they rely on the host's
`/nix`), so building `.portable` for one fails with a clear message.

## `mkPrison` — deny-by-default services

One container per service, sharing a single network namespace, with nothing
allowed until it is named. Backend agnostic: the definition says what a service
may do, never how to run it.

```nix
let prison = nixos-container-podman.lib.x86_64-linux; in
prison.mkPrison {
  name = "web";
  listen.tcp = [ 80 443 ];
  services = [
    (prison.mkPrisonService {
      name = "caddy";
      exec = [ "${pkgs.caddy}/bin/caddy" "run" "--config" "/config/Caddyfile" ];
      uid  = 1000;
      capabilities.netBindService = true;     # ports 80 and 443, nothing else
      state  = [ { path = "/var/lib/caddy"; } ];
      config = { Caddyfile = ./Caddyfile; };
    })
  ];
}
```

Detail in [`nix/prison/README.md`](nix/prison/README.md).

## Tests

```console
$ tests/run.sh              # everything
$ tests/run.sh --quick      # only what needs no container
```

Real containers, with every path they could write to redirected into a
gitignored `tests/scratch`; the last check proves the cleanup was total. See
[`tests/README.md`](tests/README.md).

## `nixct`

The develop-container preset built on these primitives — per-project throwaway
users, forwarded sockets, shared or frozen host directories, and a NixOS module
that keeps it running and upgrades it in place: [nixct.md](nixct.md).
