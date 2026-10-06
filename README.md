# NixOS-Container-Podman

Nix functions for running NixOS systems and NixOS-built containers under
rootless podman, with real systemd in a user namespace and the system described
as an ordinary NixOS configuration. Every container is built from a closure, a
symlink farm, a squashfs or a rootfs directory, without OCI images.

Each part is a flake output that other nix projects can use on its own, and
`mkContainer` combines them.

- It runs on NixOS and on other Linux distributions. Elsewhere, the
  [portable tarball](#portable-tarball) carries its own store and needs no nix
  on the host.
- A container can share the host's `/nix` (store, database and daemon socket),
  so it builds through the host's nix-daemon and adds nothing to disk.
- A container can instead get a restricted store view from
  `nix-store-shared-fuse`. The view is a symlink farm of chosen paths and needs
  no daemon, so a single-user nix install can share its store too.
- Podman command lines are generated from a nix model and validated at eval
  time.
- `mkPrison` builds services that get no network ports, egress, capabilities or
  writable paths unless they declare them.

`nixct` is a develop container with per-project throwaway users and forwarded
sockets, built on these parts. See [nixct.md](nixct.md).

## What this repo provides

**1. `lib.mkContainer`, a NixOS system as a rootless podman container.** It
takes NixOS modules and returns a rootfs and a run script with `up`, `enter`,
`exec`, `boot`, `status`, `logs`, `down` and `purge`. It is configured through
[independent settings](#configuration-axes).

**2. `lib.mkPrison` and `lib.mkPrisonService`, deny-by-default confinement.**
They declare a service's ports, egress, capabilities and writable paths, and
`podman-backend.nix` runs it with podman. See
[`nix/prison/README.md`](nix/prison/README.md).

**3. Layer derivations.** `systemLower`, `nixStoreLower`, `rootfsFolder`,
`rootfsSquashfs`, and a [portable tarball](#portable-tarball) that runs on a
host with no nix. Each can be used on its own.

**4. `nix-store-shared-fuse`, a read-only FUSE filesystem for a host
`/nix/store`.** It serves a symlink-farm view, so a container sees only its
own closure. It is a standalone binary; the `hostNixStore` setting
mounts it for a container.

**5. `ssh-agent-filter`, a filtering proxy for the SSH agent protocol.** It
forwards only the keys a policy names and always refuses adding, removing and
locking keys. It is a standalone binary and does not need containers.

**6. `nix/podman.nix`, the podman option model.** It turns typed nix values into
an argv and validates them at eval time. It needs only `lib`, so the portable
tarball and the NixOS target use the same model.

`check-host-compat` is a standalone probe that reports whether a host has the
binaries, kernel features, fuse and rootless setup this repo needs.

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
The example containers are `.#testcontainer` (persistent overlay),
`.#testdaemon` (host nix-daemon), `.#testnvidia` and `.#nixct-nvidia`.

`mkNixct` adds `modules`, `runName`, `sessionTemplates`, `sessionShares` and
`developArgs` for presets kept in other repositories. `nixct-chrome` is one such
preset, a separate flake that ships Google Chrome with the Claude in Chrome
extension installed.

## Subcommands

Run `nix run .#<container>.<subcommand> -- [args]`, or build the combined `run`
package and call `<runName> <subcommand>`. `runName` defaults to
`nix-dev-container`.

- `up [--gpu] [--opengl]` starts the persistent container and does nothing if
  it already runs. `--gpu` passes nvidia/CUDA through and `--opengl` passes
  OpenGL/DRI through. Both must be given to `up`; an automatic `up` enables
  neither.
- `down` / `stop` `[--force]` stops and removes the container and keeps
  `$STATE_DIR`. While `develop` sessions are live it lists their projects and
  refuses, because stopping the container kills them and, with ephemeral
  storage, deletes their session HOMEs. `--force` stops it anyway. `purge` and
  `boot` behave the same way.
- `enter` / `shell` opens a login shell as `shellUser` and runs `up` first if
  needed.
- `develop [hostpath]` bind-mounts `<hostpath>` into the running container and
  runs `nix develop` there as a new per-session user. It defaults to the
  current directory. Running it again on the same path opens another shell in
  the same session (see [sessions and shells](nixct.md#sessions-and-shells)).
- `wayland-attach <hostpath>` starts a host-side `wprsc` viewer for a `develop`
  session started with `--wprs`, or reuses a running one. It needs `wprsc` on
  the host's `$PATH`.
- `wayland-detach <hostpath>` stops that viewer. The session's apps and `wprsd`
  keep running.
- `exec -- CMD...` runs `CMD` in the container as `shellUser`.
- `boot` boots systemd in the foreground in a throwaway container for
  debugging. It removes any persistent container first.
- `status` shows the container state, store source and disk usage.
- `logs` follows the container log.
- `purge` runs `down` and deletes `$STATE_DIR`.
- `switch` / `upgrade` activates this build's system in the running container
  and keeps it and its develop sessions up. It only works for host nix-daemon
  containers; see
  [rebuilds upgrade in place](nixct.md#nixos-rebuild-switch-upgrades-the-container-in-place).
- `check-host-compat` checks the host for the binaries, kernel features, fuse
  and rootless setup it needs. It does not touch any container.

## Configuration axes

Each setting below controls one concern and can be combined freely with the
others. All are optional, and the defaults give the persistent overlay the
example containers use.

### `storage`, the writable layer

- `lib.overlay { lower ? "squashfs"; }` (default) is an overlay with an on-disk
  upper under `$STATE_DIR`, so changes made in the container survive restarts.
- `"ephemeral"` is an overlay with a tmpfs upper under `$XDG_RUNTIME_DIR`. Its
  state is lost when the container is removed.
- `"directory"` is a writable rootfs directory with no overlay.

### `lower`, the read-only base

`"squashfs"` (default) or `"folder"`. squashfs is smaller but needs squashfuse
on the host, and folder ships plain files. It only applies to the `ephemeral`
and overlay storage settings, and it also picks the portable tarball format.

### `hostNixStore` and `hostNixDaemon`, the source of `/nix/store`

By default the container is self-contained and its closure is part of the
read-only base. Two booleans change where `/nix/store` comes from:

- `hostNixStore = true` serves `/nix/store` from the host at runtime through
  `nix-store-shared-fuse`, over a symlink farm of exactly the container's
  closure. A writable overlay upper sits over it so builds in the container
  still work; with `directory` storage the store is mounted read-only with no
  overlay. A host GC root keeps the closure alive while the container exists
  and is removed at teardown. The host's `/etc/fuse.conf` needs
  `user_allow_other` because the FUSE mount uses `--allow-other`;
  `check-host-compat` checks for it.
- `hostNixDaemon = true` sends every build and query to the host nix-daemon.
  The whole host `/nix` (store, `/nix/var` database and daemon socket) is
  bind-mounted read-only, and the container has no nix-daemon and no nixbld
  users. The closure is already in the host store because the container is
  built there. This setting overrides `hostNixStore`, and `mkNixct` uses it.

Each store source works with each storage setting. `status` reports the source
as `self-contained`, `host-store` or `host-daemon`.

`storage` (env `STORAGE`) and `hostNixStore` (env `HOST_NIX_STORE`) can change
at runtime. `hostNixDaemon` (env `HOST_NIX_DAEMON`) is fixed at build time
because the container's NixOS configuration depends on it.

### Other settings

- `gpu.hostHasToolkit` makes `up --gpu` use the host's
  nvidia-container-toolkit (CDI, `--device nvidia.com/gpu=all`) instead of
  binding `/dev/nvidia*` by hand.
- `keepId.enable`, `keepId.uid` and `keepId.gid` use `--userns=keep-id`, so
  `shellUser` maps to the invoking host user. uid and gid default to `1000` and
  `100`.
- `modules`, `shellUser`, `name`, `runName` and `idleTimeout` are as in the
  quick start. `idleTimeout` is in seconds and stops the container once no
  `develop` session has been active for that long; `0` disables it.

### Example: host nix-daemon container

```nix
ct = nixos-container-podman.lib.x86_64-linux.mkContainer {
  modules       = [ ./my-system-config.nix ];
  shellUser     = "alice";
  name          = "myct";
  hostNixDaemon = true;          # /nix from the host daemon, no nixbld users
};
```

`.#testdaemon` is a ready-made example:

```sh
nix run .#testdaemon.enter
nix run .#testdaemon.develop -- ./my-project
```

### GC roots in host-daemon develop sessions

A `develop` session in a host-daemon container registers the store paths it
uses as GC roots while it runs, so a host `nix-collect-garbage` cannot delete
them. See [nixct.md](nixct.md#gc-roots-in-host-daemon-develop-sessions).

### `isolateLan` (build time), no route to the local network

pasta gives a rootless container a copy of the host interface, with the same
address and on-link route. By default a session can therefore connect to
anything the host reaches on the LAN. With a forwarded ssh-agent, that means a
session can use the agent's keys against every LAN machine that trusts them.
Loopback is not mapped, so the host itself is out of reach.

```nix
mkNixct { isolateLan = true; }        # or programs.nixct.isolateLan = true;
```

A separate gateway container owns the network namespace and only runs
`sleep`. The host loads the nftables ruleset into that namespace with `nsenter`
before the dev container joins it with `--network=container:<name>-net`.

The dev container runs without `CAP_NET_ADMIN`, so it cannot change the
ruleset. A process that creates a new user namespace inside it still has no
`CAP_NET_ADMIN` over this network namespace. Inside a running container:

```
CapEff = 00000000802425fb     → NET_ADMIN absent
# ip link add dummy0 type dummy
RTNETLINK answers: Operation not permitted
```

The ruleset rejects RFC1918, CGNAT and tailnet (`100.64.0.0/10`), link-local
and IPv6 ULA destinations, and allows loopback and the public internet. It
uses `reject` instead of `drop`, so a blocked connect fails at once instead of
waiting for the TCP timeout. `isolateLan.allow` and `.allow6` add exceptions.
`.resolver` (default `169.254.1.1`, pasta's DNS forwarder) is allowed before
the link-local rule so DNS keeps working:

```
LAN gateway 192.168.176.1:80   -> blocked
LAN host    192.168.176.38:22  -> blocked
tailnet   100.100.100.100:53   -> blocked
public          1.1.1.1:443    -> REACHABLE
DNS                            -> OK
```

## Portable tarball

`nix build .#<container>.portable` builds a self-contained tarball for non-NixOS
hosts with rootless podman and fuse-overlayfs, plus squashfuse for the squashfs
layout. The host needs no nix. The `lower` setting picks the layout:
`"squashfs"` (default) or `"folder"`. Run `check-host-compat` on the target
host first.

Only self-contained containers have a portable tarball. `hostNixStore` and
`hostNixDaemon` containers need the host's `/nix`, so building `.portable` for
them fails with an error.

## `mkPrison`, deny-by-default services

Each service runs in its own container. The containers of a prison share one
network namespace. Ports, egress, capabilities and writable paths are denied
unless the service declares them.

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

See [`nix/prison/README.md`](nix/prison/README.md) for details.

## Tests

```console
$ tests/run.sh              # everything
$ tests/run.sh --quick      # only what needs no container
```

The tests start real containers and redirect every path they write to into the
gitignored `tests/scratch`. The last check verifies that teardown removed
everything. See [`tests/README.md`](tests/README.md).

## `nixct`

`nixct` is the develop container built on this repo. It has per-project
throwaway users, forwarded sockets, shared or frozen host directories, and a
NixOS module that keeps it running and upgrades it in place. See
[nixct.md](nixct.md).
