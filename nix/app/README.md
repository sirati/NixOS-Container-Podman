# app

`mkApp` runs a desktop program in a rootless podman container and presents it to
the host as an ordinary Wayland application, much as snap does.

The host sees what an installed program shows. `bin/<entry>` is on `PATH`, and
the package's `share/` (desktop entries, icons, MIME types) is carried over
unchanged, so the menu, the file manager and `xdg-open` find it as they would any
other program. Run it and the window is a native Wayland client of the host
compositor, with the GPU, clipboard, input method and audio, because the
container is given those sockets and device nodes and nothing else.

What the program cannot see is the rest of the machine: your dotfiles, other
processes, the host's loopback and the session bus.

```nix
# with the NixOS module (`appSandbox.enable = true`), which fills in the users,
# the GPU nodes, the fonts and podman from the configuration:
config.appSandbox.mkApp {
  name = "photocraft";
  package = pkgs.photocraft;
  homeVisible = true;          # snap's `home`
  audio = true;
  entries = {
    photocraft     = { exec = "bin/photocraft"; display = true; };
    photocraft-cli = { exec = "bin/photocraft-cli"; stdio = true; tty = "auto"; cwd = true; };
  };
}
```

## Layers

```
default.nix       what an app may reach ("plugs"); renders one plan per user and entry
../podman.nix     the typed podman model; the only code producing a command line
plan.nix          serialises that argv, plus what is only known at launch
runner.rs         the launcher; reads a plan, fills in the launch-time parts
rootfs.nix        the smallest tree podman accepts, with the user in it
nixos-module.nix  users, GPU nodes and fonts, read from the NixOS configuration
```

The runner is Rust (standard library only, built with `rustc`, unit tests run as
part of the build) because it decides what the confined process can see. A path
that reaches `--mount` is rejected if it could be read as more than one option,
and nothing goes through a shell.

## What an app is given

| plug | what it is | default |
|---|---|---|
| `display` (per entry) | the compositor socket, GPU, audio, fonts, cursor theme, a filtered session bus | off |
| `gpu` | `/dev/dri` (or the nodes in `gpu.dri`), `gpu.devices` globs, the host's driver directory | none |
| `audio` | the PipeWire and PulseAudio sockets, and an ALSA configuration that routes to them | off |
| `fonts` / `icons` | host directories served read-only as `/usr/share/fonts` and `/usr/share/icons` | none |
| `dbus` | `xdg-dbus-proxy` in filter mode: portals, notifications, the tray, the file manager | on |
| `homeVisible` | every non-hidden entry of the home directory, read-write | off |
| `userDirs`, `paths` | named folders or absolute paths, read-write or `ro`; the same path inside | none |
| `state` | `~/.var/app/<name>/{config,data,cache,state}` as the app's XDG directories | on |
| `network` | the shared namespace gets `pasta` (internet) or `none` | `pasta` |

The home directory inside is a scratch tmpfs. Only the four XDG directories above
persist, and they belong to the app alone. Paths are identical inside and out, so a
file passed on the command line or from a file manager needs no translation.

## One private loopback per app

Every entry of one app joins a network namespace held by a small pause container
(`<prefix>-<name>-net`), the way a prison's services join theirs. A program that
opens a control port on `127.0.0.1` opens it there. The host and every other
program cannot reach it; the app's own CLI and MCP-server entries can, because
they are in the same namespace. An entry with `joinNetwork = false` gets a
namespace with nothing in it.

The holder exists only while the app is running. Each entry takes a shared
`flock` on `$XDG_RUNTIME_DIR/<holder>.lease` for as long as it runs, and the
last entry to end removes the holder. Nothing is left running when the last
window closes, and a reboot or logout leaves no container behind.

- A launch that finds no entry running looks at a holder that exists and asks
  whether it can be joined: podman has it running *and* the process it names
  (`catatonit`) is there. podman's record outlives that process when something
  kills it (a logout, a crash, the OOM killer), and joining the holder then fails
  on `open /proc/<pid>/ns/net` while `podman ps` says it is up. A holder that
  cannot be joined is removed together with every container that had joined it,
  which are leftovers too and would otherwise keep it from being removed, and is
  made again from the launch's own plan. A holder that is alive is used as it is.
  One from before an update points at the old root filesystem and could not be
  started once that store path was collected; it is not running, so it is replaced.
- A runner that is killed loses its claim with the process, so there is nothing
  to go stale.
- If the holder is still not running after that, the launch stops with an error
  saying so, instead of starting an app that cannot reach its own loopback.
- The runner stays as the parent of podman while it holds a claim, so it can
  clean up afterwards, and passes SIGTERM (and, outside a terminal, SIGHUP, SIGINT
  and SIGQUIT) on to it. An entry with no holder and no D-Bus proxy still replaces
  the runner with podman.

## A podman storage of its own

An app's containers are not in the user's default podman storage. They live in
`$XDG_RUNTIME_DIR/<prefix>-<name>-podman`, which is tmpfs, with `vfs` (the
containers run from a root filesystem in the Nix store and have no image layers)
and file locks. Every podman call of the app carries those options (the plan's
`[podman]` section), so `podman ps` does not list the app's containers; ask with
the same `--root`, `--runroot`, `--tmpdir` and `--storage-driver vfs`.

The reason is locking. podman keeps container locks in one shared-memory pool per
user, `/dev/shm/libpod_rootless_lock_<uid>`, and every storage the user has
shares it: their own containers, a `nixct` session, each app. Storages do not
know about each other's locks. When one refreshes after a login, its containers
ask for the lock ids they had, and one that another storage already holds is
refused (`acquiring lock 0 for container …: file exists`). A podman call that
waits on a lock nobody will release hangs without an error, which is how an app
ends up unable to start. A storage with file locks does not touch the pool.

`privateStorage = false` puts the app's containers in the user's default storage
again.

A podman call that prepares or removes the holder gets 30 seconds, and a launch
waits up to 75 seconds for another launch of the same app that is doing the same.
After that the runner says which call stalled and fails, instead of hanging.

## Per-user plans

Paths inside are the host's own, so the plan is rendered for each user ahead of
time (`<uid>.plan`) and the runner picks the one for the invoking uid. A user
without a plan gets a clear error, not a half-working app. The NixOS module needs
a fixed uid for each user for this reason.

## Entries

| field | meaning |
|---|---|
| `exec`, `args`, `env` | what runs; `{home}`, `{user}`, `{uid}`, `{runtime_dir}` are the user's |
| `display` | give it a window: compositor, GPU, audio, fonts, cursors, the bus |
| `stdio`, `tty` | keep stdin open; `"auto"` allocates a terminal when both ends are one |
| `cwd` | start in the caller's directory, where the sandbox can see it |
| `joinNetwork` | join the app's shared namespace (default) or get an empty one |
| `paths`, `ensureDirs` | more visible paths, and directories the runner creates first (mode `0700`) |

## What it does not do yet

- Accessibility (AT-SPI) is not bridged; the bus filter does not allow `org.a11y.Bus`.
- The document portal is not used. File dialogs return host paths, which work because
  paths are identical inside, but a file outside the visible paths is invisible to the app.
- A filtered view of `/nix/store` (as a prison has) would show the app only its own
  closure. It sees the whole read-only store today.
