# nix-store-shared-fuse

A read-only FUSE filesystem that serves a Nix **store symlink-farm** directory,
transparently *realizing* qualifying farm symlinks into real directory content
read from a (possibly relocated) backing store.

## What it does

A "store symlink-farm" is a directory whose entries are symlinks named like
store paths and pointing at them, e.g.

```
/some/farm/
  k3v…-htop   -> /nix/store/k3v…-htop
  9ab…-glibc  -> /nix/store/9ab…-glibc
```

Instead of bind-mounting each individual store path (one mount per closure
entry) or mounting the whole host `/nix/store`, this FUSE presents the farm as
the filesystem root and serves each qualifying symlink **as if it were the real
store directory**. Metadata and directory traversal go through the daemon;
regular-file reads, mmap and splice are attached to the backing file with the
kernel's FUSE passthrough API and do not copy file contents through userspace.
The backing store may live at a different physical location (e.g. a
`nix-portable` relocated store).

The result: a process `chroot`/namespaced onto the mount sees a normal-looking
`/nix/store` populated with exactly the closure in the farm, with the real files
served on demand, and nothing else of the host store exposed.

## The three roots

| Argument | Role | Example |
| --- | --- | --- |
| `--bind-target <DIR>` | The directory served as the FS root (the symlink farm). Real files/subdirs here are served as-is, read-only. | the symlink farm |
| `--resolution-root <DIR>` | The **logical** prefix a farm symlink's target must lie within to qualify. Used only as a path prefix for the membership / loop check and to compute the relative subpath. Never opened for I/O. | `/nix/store` |
| `--redirect-root <DIR>` | The **physical** root the realized content is read from. Defaults to `--resolution-root` if omitted. | a nix-portable relocated store, e.g. `$HOME/.nix-portable/store` |

Plus a positional `<MOUNTPOINT>`.

### Why resolution-root and redirect-root are separate

A `nix-portable` (or otherwise relocated) store still records its *logical*
paths as `/nix/store/...` inside symlinks and store metadata, while the actual
bytes live somewhere else on disk. So a farm symlink's target reads
`/nix/store/k3v…-htop` (logical → `--resolution-root /nix/store`), but the
content must be read from `$HOME/.nix-portable/store/k3v…-htop`
(`--redirect-root $HOME/.nix-portable/store`). When the store is *not* relocated
the two are identical and `--redirect-root` may be omitted.

## Realization rule

For an entry in the `bind_target` tree that is a **symlink** with target `T`:

* **Realize it as a directory** (serve its contents) **iff**:
  1. `T` (normalized, absolute) is **inside** `resolution_root`, **and**
  2. `T` is **not inside** `bind_target` (loop guard — a farm symlink pointing
     back into the farm must stay a symlink), **and**
  3. the realized location is actually a directory.

  The realized location is `redirect_root / (T relative to resolution_root)`.

* **Otherwise**: present the symlink **as-is** (a normal symlink with its
  original target).

Content reached **through** a realized node (files/dirs under
`redirect_root/<rel>`) is served **verbatim** from `redirect_root`. In
particular, symlinks found *inside* a realized store path stay ordinary
symlinks — their absolute `/nix/store/…` targets get re-resolved by the kernel
against the mount root, which is correct for a complete closure. The
realize-as-directory treatment applies **only** to symlinks in the
`bind_target` tree, never to symlinks under `redirect_root` content.

## Safety model

* All filesystem I/O is performed through [`cap-std`](https://docs.rs/cap-std)
  capability `Dir` handles opened once on `bind_target` and `redirect_root`.
  Every access is a `*at`-style operation relative to one of those handles
  (`open`, `read_dir`, `symlink_metadata`, `read_link_contents`). The
  process is **physically unable** to read outside those two roots even if a
  symlink target tries to escape with `..` or an absolute path.
* Regular files are opened read-only through their capability handle with
  `O_NOFOLLOW`, then registered using upstream
  [`fuser`](https://docs.rs/fuser)'s safe `BackingId` /
  `ReplyOpen::opened_passthrough` API. This crate has `unsafe_code = "forbid"`;
  it contains no local ioctl or raw-fd unsafe block. `fuser` is built with
  default features disabled, so this uses its pure Rust mount backend rather
  than linking libfuse; the required ioctl unsafe remains encapsulated in the
  upstream crate.
* `resolution_root` is used purely as a logical path prefix for the
  membership / relative-path computation; it is never opened for I/O.
* **Read-only.** Only read operations are implemented; every mutating operation
  (`write`, `create`, `mkdir`, `unlink`, `rmdir`, `rename`, `link`, `symlink`,
  `mknod`, `setattr`, `setxattr`) is rejected with `EROFS`, and the filesystem
  is mounted with the `ro` option, always `nodev` (a store has no device
  nodes), and `nosuid` only when `--nosuid` is passed (off by default so
  set-uid binaries in the store keep working).
* Underlying permission bits and mtimes are preserved, so store paths keep their
  `0444` / `0555` modes. A realized directory node is reported as `S_IFDIR`
  with the **real target directory's** mode/uid/gid/mtime (the metadata is
  stat'd through the redirect root), not a synthesized mode.

## FUSE operations implemented

`lookup`, `getattr`, `readlink`, `opendir`, `readdir`, `releasedir`, `open`,
`release`, `statfs`, `access`. A successful `open` is always passthrough; the
daemon's `read` callback deliberately returns `EIO` because reaching it would
mean the kernel failed to honor that contract. All mutating ops return `EROFS`.

## Kernel requirements

The host kernel must provide `CONFIG_FUSE_PASSTHROUGH` and negotiate the
`FUSE_PASSTHROUGH` capability. Registering a backing file currently also
requires `CAP_SYS_ADMIN`; the daemon refuses to mount without it instead of
starting a filesystem whose file opens all fail. The prison NixOS module runs
each daemon in a dedicated store-view unit and grants that unit the one ambient
capability. Prison setup, Podman and service containers receive none of it; the
containers continue to drop all capabilities.

Kernel backing references bypass the daemon's `RLIMIT_NOFILE`. The daemon
therefore enforces `--max-open-files` itself (default `65536`) and returns
`EMFILE` at the ceiling.

## Example invocation

```sh
nix-store-shared-fuse \
  --bind-target   /run/nix-farm \
  --resolution-root /nix/store \
  --redirect-root "$HOME/.nix-portable/store" \
  --allow-other \
  /mnt/store
```

This serves the symlink farm at `/run/nix-farm` on `/mnt/store`, realizing
every `… -> /nix/store/…` farm symlink against the relocated store under
`$HOME/.nix-portable/store`, readable by other users (`--allow-other`).

If the store is not relocated, omit `--redirect-root`:

```sh
nix-store-shared-fuse \
  --bind-target /run/nix-farm \
  --resolution-root /nix/store \
  /mnt/store
```

### Flags

* `--allow-other` — pass FUSE `allow_other` so non-mounting users (e.g.
  container session users) can read the mount. Off by default.
* `--nosuid` — mount with `nosuid` (strip set-uid/set-gid). Off by default so
  set-uid binaries in the store keep working; opt in to harden. (Unprivileged /
  user-namespace FUSE mounts are often forced `nosuid` by the kernel anyway.)
* `--foreground` / `-f` — run in the foreground. This is the default behaviour
  (the process owns the mount session, suitable for `systemd` / launchers); the
  flag is accepted for explicit use.
* `--max-open-files <N>` — cap concurrent passthrough handles. Defaults to
  `65536`; must be greater than zero.

## Building & testing

The toolchain and `libfuse` are provided via a nix shell:

```sh
nix shell nixpkgs#cargo nixpkgs#rustc nixpkgs#rustfmt nixpkgs#pkg-config \
  nixpkgs#fuse3 nixpkgs#clippy \
  -c bash -lc 'cargo fmt --check && cargo test --all-targets && \
    cargo test --all-targets -- --ignored && cargo clippy --all-targets -- -D warnings'
```

The pure path/predicate logic (target normalization, the "inside
resolution_root" and "not inside bind_target" predicates, and the redirect
relative-path mapping) is covered by unit tests in `src/realize.rs`. An
integration test in `tests/realize_cap.rs` exercises the realization decision
against a real on-disk farm + store layout through `cap-std`; it is marked
`#[ignore]` (needs filesystem write access) — run it with
`cargo test -- --ignored`. Capability-opening unit tests also prove that
absolute paths, `..` escapes and final/intermediate symlink escapes are refused.
A full passthrough mount integration test additionally needs `/dev/fuse`, a
kernel built with `CONFIG_FUSE_PASSTHROUGH`, and `CAP_SYS_ADMIN`, so it is not
run in the unprivileged build sandbox.
