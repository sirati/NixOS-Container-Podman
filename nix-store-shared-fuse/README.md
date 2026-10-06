# nix-store-shared-fuse

A read-only FUSE filesystem that serves a Nix store symlink farm. Symlinks in
the farm that point into the store are shown as the store paths they point at,
read from a backing store that may live somewhere other than `/nix/store`.

## What it does

A store symlink farm is a directory of symlinks named like store paths that
point at them:

```
/some/farm/
  k3v…-htop   -> /nix/store/k3v…-htop
  9ab…-glibc  -> /nix/store/9ab…-glibc
```

The FUSE mounts the farm as its root and serves each qualifying symlink as the
real store directory. This avoids one bind mount per closure entry and avoids
mounting the whole host `/nix/store`. The daemon handles metadata and directory
listings. Regular-file reads, mmap and splice use the kernel's FUSE passthrough
API, so file contents never pass through the daemon. The backing store can be
relocated, for example a `nix-portable` store.

A process namespaced onto the mount sees a `/nix/store` that contains exactly
the farm's closure and nothing else from the host store.

## The three roots

| Argument | Role | Example |
| --- | --- | --- |
| `--bind-target <DIR>` | The directory served as the filesystem root (the symlink farm). Real files and directories in it are served read-only as they are. | the symlink farm |
| `--resolution-root <DIR>` | The logical prefix a farm symlink's target must be under to qualify. It is only compared as a path prefix and used to compute the relative subpath, and is never opened. | `/nix/store` |
| `--redirect-root <DIR>` | The physical directory the content is read from. Defaults to `--resolution-root`. | a relocated nix-portable store, e.g. `$HOME/.nix-portable/store` |

The mount point is the positional `<MOUNTPOINT>` argument.

### Why resolution-root and redirect-root are separate

A relocated store such as `nix-portable` still writes `/nix/store/...` into its
symlinks and metadata, while the files live elsewhere on disk. A farm symlink
then points at `/nix/store/k3v…-htop` (matched against
`--resolution-root /nix/store`), but the content is read from
`$HOME/.nix-portable/store/k3v…-htop`
(`--redirect-root $HOME/.nix-portable/store`). For a store that is not
relocated the two are the same and `--redirect-root` can be omitted.

## Realization rule

A symlink in the `bind_target` tree with target `T` is served as the directory
or regular file it points at if all of these hold:

1. `T`, normalized and absolute, is inside `resolution_root`.
2. `T` is not inside `bind_target`. A farm symlink that points back into the
   farm stays a symlink, which prevents loops.
3. The realized location is a directory or regular file.

The realized location is `redirect_root / (T relative to resolution_root)`.
Any other symlink is shown as a normal symlink with its original target.

Everything under a realized node is served from `redirect_root` unchanged.
Symlinks inside a realized store path stay ordinary symlinks; the kernel
resolves their absolute `/nix/store/…` targets against the mount root, which
works for a complete closure. Only symlinks in the `bind_target` tree are
realized, never symlinks inside `redirect_root` content.

## Safety model

* All filesystem I/O goes through [`cap-std`](https://docs.rs/cap-std) `Dir`
  handles opened once on `bind_target` and `redirect_root`. Every access
  (`open`, `read_dir`, `symlink_metadata`, `read_link_contents`) is a `*at`
  call relative to one of those handles, so a symlink target with `..` or an
  absolute path cannot reach outside the two roots.
* Regular files are opened read-only through their capability handle with
  `O_NOFOLLOW` and registered with the safe `BackingId` /
  `ReplyOpen::opened_passthrough` API of [`fuser`](https://docs.rs/fuser). The
  crate sets `unsafe_code = "forbid"` and has no ioctl or raw-fd `unsafe` of its
  own. `fuser` is built without default features, so it uses its pure Rust mount
  code instead of linking libfuse, and the ioctl `unsafe` stays inside `fuser`.
* `resolution_root` is only a path prefix for membership and relative-path
  checks and is never opened.
* Only read operations are implemented. `write`, `create`, `mkdir`, `unlink`,
  `rmdir`, `rename`, `link`, `symlink`, `mknod`, `setattr` and `setxattr` return
  `EROFS`. The mount is always `ro` and `nodev` (a store has no device nodes).
  It is `nosuid` only with `--nosuid`, so set-uid binaries in the store work by
  default.
* Permission bits and mtimes come from the backing files, so store paths keep
  their `0444` / `0555` modes. A realized directory is reported as `S_IFDIR`
  with the mode, uid, gid and mtime of the real target directory, read through
  the redirect root.

## FUSE operations implemented

`lookup`, `getattr`, `readlink`, `opendir`, `readdir`, `releasedir`, `open`,
`release`, `statfs` and `access`. Every successful `open` uses passthrough. The
daemon's `read` callback returns `EIO`, since the kernel only calls it if
passthrough failed. All mutating operations return `EROFS`.

## Kernel requirements

The host kernel needs `CONFIG_FUSE_PASSTHROUGH` and must negotiate the
`FUSE_PASSTHROUGH` capability. Registering a backing file also requires
`CAP_SYS_ADMIN`, and the daemon refuses to mount without it. The prison NixOS
module runs each daemon in its own store-view unit and gives only that unit the
ambient capability. Prison setup, Podman and the service containers do not get
it, and the containers still drop all capabilities.

Kernel backing references do not count against the daemon's `RLIMIT_NOFILE`, so
the daemon enforces `--max-open-files` itself (default `65536`) and returns
`EMFILE` at that limit.

## Example invocation

```sh
nix-store-shared-fuse \
  --bind-target   /run/nix-farm \
  --resolution-root /nix/store \
  --redirect-root "$HOME/.nix-portable/store" \
  --allow-other \
  /mnt/store
```

This mounts the farm at `/run/nix-farm` on `/mnt/store`, serves every
`… -> /nix/store/…` farm symlink from the relocated store under
`$HOME/.nix-portable/store`, and lets other users read the mount.

For a store that is not relocated, omit `--redirect-root`:

```sh
nix-store-shared-fuse \
  --bind-target /run/nix-farm \
  --resolution-root /nix/store \
  /mnt/store
```

### Flags

* `--allow-other` sets FUSE `allow_other`, so users other than the one who
  mounted it (such as container session users) can read the mount. Off by
  default.
* `--nosuid` mounts with `nosuid`. Off by default so set-uid binaries in the
  store work. Unprivileged and user-namespace FUSE mounts are often `nosuid`
  regardless.
* `--foreground` / `-f` runs in the foreground. The daemon always does; the flag
  is accepted for launchers that pass it.
* `--max-open-files <N>` limits concurrent passthrough handles. Defaults to
  `65536` and must be greater than zero.

## Building and testing

```sh
nix shell nixpkgs#cargo nixpkgs#rustc nixpkgs#rustfmt nixpkgs#pkg-config \
  nixpkgs#fuse3 nixpkgs#clippy \
  -c bash -lc 'cargo fmt --check && cargo test --all-targets && \
    cargo test --all-targets -- --ignored && cargo clippy --all-targets -- -D warnings'
```

Unit tests in `src/realize.rs` cover target normalization, the
inside-`resolution_root` and outside-`bind_target` checks, and the redirect
path mapping. `tests/realize_cap.rs` tests the realization decision against a
real farm and store on disk through `cap-std`. It is `#[ignore]` because it
writes to the filesystem; run it with `cargo test -- --ignored`. Unit tests for
opening capability handles check that absolute paths, `..` and symlinks that
escape at the last or an intermediate component are refused. A full passthrough
mount test needs `/dev/fuse`, a kernel with `CONFIG_FUSE_PASSTHROUGH` and
`CAP_SYS_ADMIN`, so it does not run in the unprivileged build sandbox.
