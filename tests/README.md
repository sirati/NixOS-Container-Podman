# tests

```console
$ tests/run.sh              # everything
$ tests/run.sh --quick      # only what needs no container
$ tests/run.sh 20 30        # only cases whose filename matches
$ tests/run.sh --keep       # leave tests/scratch for inspection
```

The suite starts real containers. Before any test runs, `lib.sh` points every
path a test could write to at `tests/scratch`, so the machine's own podman and
nix-dev-container state are not touched:

| redirected | why |
| --- | --- |
| `STATE_DIR` | the framework's own tree; podman's `--root`/`--runroot` derive from it |
| `XDG_RUNTIME_DIR` | holds the rootless pause process |
| `XDG_CONFIG_HOME` | `containers.conf`, `storage.conf` |
| `XDG_DATA_HOME` | podman's default storage |
| `XDG_STATE_HOME` | the run script's default `STATE_DIR` |
| `XDG_CACHE_HOME` | nix's eval and fetcher caches |
| `TMPDIR` | podman and nix both use it |

`HOME` stays unchanged because nix needs it, and nothing writes under it once
the four XDG variables point elsewhere.

## The last check

Teardown runs each container's own `down` and `purge`, kills the scratch pause
process by pid and removes the directory. It then checks that:

- the scratch directory is gone
- git sees no leftover files in the working tree
- the host's podman and state directories match the snapshot taken before the
  run
- nothing is mounted under the scratch path
- no process holds it open
- no live GC root points into it

A run leaves only realized store paths behind. They are not rooted, so the
next `nix-collect-garbage` deletes them.

## Cases

| case | covers |
| --- | --- |
| `00-eval.sh` | the podman model's ordering and quoting, the prison's default-deny rules and typed capabilities, and that unsupported values fail with "not implemented" |
| `05-podman-tmpfs.sh` | Podman accepts the rendered tmpfs options and creates a writable `noexec,nosuid,nodev` mount owned by the service |
| `10-selfcontained.sh` | store baked into the rootfs, own nix-daemon, host store not visible |
| `20-hostdaemon.sh` | host `/nix` read-only, builds delegated to the host daemon, no daemon inside |
| `30-nixct.sh` | `mkNixct`'s own settings, and two sessions sharing one project |
| `40-develop-options.sh` | all 26 flags `develop` accepts |

Each variant runs the same lifecycle from `lib.sh`: up, status, exec,
`develop --command`, down, status, purge.

`40-develop-options.sh` reads the flag list from the argument loop in
`dispatch.nix` and fails if the file does not name a flag, either as covered or
as an explicit skip. A newly added flag therefore fails the test until it is
covered. The five flags that need a display (`--x11`, `--x11-untrusted`,
`--wayland`, `--wprs`, `--dbus`) run when the host has one and are reported as
skipped otherwise.
