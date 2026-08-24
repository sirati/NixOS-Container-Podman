# tests

```console
$ tests/run.sh              # everything
$ tests/run.sh --quick      # only what needs no container
$ tests/run.sh 20 30        # only cases whose filename matches
$ tests/run.sh --keep       # leave tests/scratch for inspection
```

The suite starts real containers. What makes that safe on a machine with its
own podman and its own nix-dev-container is that `lib.sh` redirects every path
a test could write to into `tests/scratch` first:

| redirected | why |
| --- | --- |
| `STATE_DIR` | the framework's own tree; podman's `--root`/`--runroot` derive from it |
| `XDG_RUNTIME_DIR` | holds the rootless pause process |
| `XDG_CONFIG_HOME` | `containers.conf`, `storage.conf` |
| `XDG_DATA_HOME` | podman's default storage |
| `XDG_STATE_HOME` | the run script's default `STATE_DIR` |
| `XDG_CACHE_HOME` | nix's eval and fetcher caches |
| `TMPDIR` | podman and nix both use it |

`HOME` is deliberately not redirected — nix needs it, and nothing under it is
written once the four XDG vars point elsewhere.

## The last check

Teardown runs each container's own `down` and `purge`, kills the scratch pause
process by pid, and removes the directory. Then it asserts:

- the scratch directory is gone
- git sees nothing left in the working tree
- the host's podman and state dirs match the snapshot taken before the run
- nothing is mounted under the scratch path
- no process is holding it
- no live gc root points into it

Realised store paths are the one thing a run leaves behind, unrooted and
collected by the next `nix-collect-garbage`.

## Cases

| case | covers |
| --- | --- |
| `00-eval.sh` | the podman model's ordering and quoting, the prison's default-deny invariants and typed capabilities, and that unsupported values fail with "not implemented" |
| `10-selfcontained.sh` | store baked into the rootfs, own nix-daemon, host store not visible |
| `20-hostdaemon.sh` | host `/nix` read-only, builds delegated to the host daemon, no daemon inside |
| `30-nixct.sh` | `mkNixct`'s own choices, and two sessions sharing one project |
| `40-develop-options.sh` | all 26 flags `develop` accepts |

Every variant runs the same lifecycle from `lib.sh`: up, status, exec,
`develop --command`, down, status, purge.

`40-develop-options.sh` reads the flag list out of the argument loop in
`dispatch.nix` and fails if a flag is not named in the file, as covered or as
an explicit skip — so a flag added later cannot go untested. The five needing a
display (`--x11`, `--x11-untrusted`, `--wayland`, `--wprs`, `--dbus`) are
attempted when the host offers one and reported as skips when it does not.
