# tests

```console
$ tests/run.sh              # everything
$ tests/run.sh --quick      # only what needs no container
$ tests/run.sh 20 30        # only cases whose filename matches
$ tests/run.sh --keep       # leave tests/scratch for inspection
```

The suite starts real containers. What makes that safe to run on a machine
that already has its own podman and its own nix-dev-container is that
`lib.sh` redirects every path a test could write to into `tests/scratch`
before anything runs:

| redirected | why it has to be |
| --- | --- |
| `STATE_DIR` | the framework's own tree; podman's `--root`/`--runroot` are derived from it, so this redirects podman too |
| `XDG_RUNTIME_DIR` | holds the pause process that owns the rootless user namespace — left alone, a test would join, or on an idle machine *create*, the user's |
| `XDG_CONFIG_HOME` | `containers.conf`, `storage.conf` |
| `XDG_DATA_HOME` | podman's default storage |
| `XDG_STATE_HOME` | the run script's default `STATE_DIR` |
| `XDG_CACHE_HOME` | nix's eval and fetcher caches |
| `TMPDIR` | podman and nix both scribble here |

`HOME` is deliberately not redirected — nix needs it, and nothing under it
is written once the four XDG vars point elsewhere. The last check verifies
that claim rather than trusting it.

## The last check

Teardown runs each container's own `down` and `purge` (they know about the
mounts, watchdogs and session users), kills the scratch pause process by
pid from its own pidfile, and removes the directory. Then:

- the scratch directory is gone
- git sees nothing left in the working tree
- the host's podman and state dirs are byte-identical to the snapshot
  taken before the run — read off the filesystem rather than by asking
  podman, since invoking the user's podman would itself start their pause
  process
- nothing is mounted under the scratch path
- no process is holding it
- no *live* gc root points into it (a purged state dir leaves its indirect
  roots dangling; those pin nothing and nix removes them on its next
  collection — a live one would mean the suite is still holding store
  paths)

## Cases

| case | what it covers |
| --- | --- |
| `00-eval.sh` | everything decidable without a container: the podman model's ordering and quoting rules, the prison's default-deny invariants and typed capabilities, and that every unsupported value fails with "not implemented" |
| `10-selfcontained.sh` | store baked into the rootfs, own nix-daemon inside, host store not visible |
| `20-hostdaemon.sh` | host `/nix` bind-mounted read-only, builds delegated to the host daemon, no daemon inside, and a real dev shell entered non-interactively |
| `30-nixct.sh` | `mkNixct`'s own choices — root shell user, ephemeral storage, idle timeout — and two sessions sharing one project |

Every variant runs the same lifecycle from `lib.sh`: up, status, exec,
`develop --command` on a project with no flake (which proves the session
path runs and returns an exit status rather than hanging on a pty), down,
status, purge, and that purge left no state dir.

## develop's flags

`40-develop-options.sh` covers all 26 flags `develop` accepts. Its first
check reads the flag list out of the argument loop in `dispatch.nix` and
fails if any of them is not named in the file — as covered, or as a skip
with a reason. A flag added later cannot quietly go untested.

The five that need something the machine may not have — `--x11`,
`--x11-untrusted`, `--wayland`, `--wprs`, `--dbus` — are attempted when the
host offers a display or a session bus and reported as skips, with the
reason, when it does not.

## What a run does leave behind

Store paths. Building a container realises derivations, and those stay in
`/nix/store` like any other build output — unrooted, so nix collects them
whenever it next runs a garbage collection. That is the only thing a run
adds outside `tests/scratch`, and the residue check verifies nothing else
does: no gc root of this suite's is still live, so nothing is pinned.

## A failing check is a finding, not noise

Several bugs turned up the first time these ran. All but one are fixed; that
one's checks are left failing on purpose rather than skipped, because a skipped
check is one nobody looks at again.

**Fixed — unix socket paths could exceed `sun_path`, in three places.**
`--host-port`, the `--agent-*` filter and `--git-serve` each create a socket
under `$STATE_DIR` named after the project path. A unix socket address is
capped at 108 bytes, so a deep project or a state dir anywhere but the default
pushed it past the limit. `bind` then failed, and the symptoms were a port that
simply never answered, "communication with agent failed", and "git server did
not come up" — none of which points at a path being too long. All three now
bind relative to the socket's own directory, where the name is a few bytes
whatever the directory is called. Two of the three only surfaced after the
first was fixed, which is the argument for having the suite at all.

**Open — only the first `develop` session on a container gets a working `-A`.**
Every session after it gets an `$SSH_AUTH_SOCK` that exists, is a socket, and
is served by an active in-container socat proxy — but the proxy's connect
target, `$WORK_SHARED/.sockets/<session>/ssh-agent`, is never created for it,
so the connection is accepted and then dies mid-protocol. `ssh-add` reports
"error fetching identities: communication with agent failed".

Reproduced on a fresh container, with the suite's own throwaway agent:

```console
$ develop -A --command 'ssh-add -l' /tmp/p1   # lists the key
$ develop -A --command 'ssh-add -l' /tmp/p2   # communication with agent failed
$ develop -A --command 'ssh-add -l' /tmp/p3   # and every one after
```

It is not a teardown race — a session started long after the previous one has
settled fails the same way — and not key count. The project bind for the later
session is made correctly; only the agent socket is unreachable.

`bind_socket` now asserts its own post-condition, and that assertion does *not*
fire here: the bind genuinely happens. It happens inside a `podman unshare`,
which is a fresh mount namespace each time, and for the second session onward
it does not propagate into the running container's namespace — where
`$WORK_SHARED` is a peer of the mount the unshare sees, `shared:N master:1`.
So the container has a socket to connect to and a proxy to serve it, and the
proxy's target is a bind that only exists somewhere else.

Four checks in `40-develop-options.sh` fail on this: `-A`, `--agent`,
`--agent-allow` and `--agent-deny`.
