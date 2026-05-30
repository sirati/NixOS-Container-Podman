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
store directory** — reading the actual contents from a backing store that may
live at a different physical location (e.g. a `nix-portable` relocated store).

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
  (`open`, `read_dir`, `symlink_metadata`, `read_link_contents`, `read`). The
  process is **physically unable** to read outside those two roots even if a
  symlink target tries to escape with `..` or an absolute path.
* `resolution_root` is used purely as a logical path prefix for the
  membership / relative-path computation; it is never opened for I/O.
* **Read-only.** Only read operations are implemented; every mutating operation
  (`write`, `create`, `mkdir`, `unlink`, `rmdir`, `rename`, `link`, `symlink`,
  `mknod`, `setattr`, `setxattr`) is rejected with `EROFS`, and the filesystem
  is mounted with the `ro` option (plus `nodev`, `nosuid`).
* Underlying permission bits and mtimes are preserved, so store paths keep their
  `0444` / `0555` modes. Realized directory nodes (whose underlying object is a
  symlink) are reported as `S_IFDIR` with a `0555` mode.

## FUSE operations implemented

`lookup`, `getattr`, `readlink`, `opendir`, `readdir`, `releasedir`, `open`,
`read`, `release`, `statfs`, `access`. All mutating ops return `EROFS`.

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
* `--foreground` / `-f` — run in the foreground. This is the default behaviour
  (the process owns the mount session, suitable for `systemd` / launchers); the
  flag is accepted for explicit use.

## Building & testing

The toolchain and `libfuse` are provided via a nix shell:

```sh
nix shell nixpkgs#cargo nixpkgs#rustc nixpkgs#pkg-config nixpkgs#fuse3 nixpkgs#clippy \
  -c bash -lc 'cargo build && cargo test && cargo clippy -- -D warnings'
```

The pure path/predicate logic (target normalization, the "inside
resolution_root" and "not inside bind_target" predicates, and the redirect
relative-path mapping) is covered by unit tests in `src/realize.rs`. An
integration test in `tests/realize_cap.rs` exercises the realization decision
against a real on-disk farm + store layout through `cap-std`; it is marked
`#[ignore]` (needs filesystem write access) — run it with
`cargo test -- --ignored`. A full FUSE mount integration test is not run in the
sandbox because it requires `/dev/fuse`.
