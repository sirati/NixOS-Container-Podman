# prison

A default-deny podman jail for services, built on `nix-store-lower`,
`nix-store-shared-fuse` and the network-namespace-owner pattern from
`net-gateway.nix`.

## Layers

```
default.nix          what a prison and its services ARE. Names no runtime,
                     no flag, no command line.
podman.nix           the podman option model: types, defaults, validation,
                     and the only code that produces argv.
podman-backend.nix   intent -> podman. Container names live here.
module.nix           systemd units. Asks the backend for argv.
ruleset.nix          the nftables policy.
rootfs.nix           the toolless filesystem.
```

## Shape

`mkPrison` is a set of containers sharing one network namespace. `<n>-net`
owns it and every service joins with `--network=container:<n>-net`.

No podman pod: a pod's infra container comes from podman's image machinery,
and whether that pulls an OCI image is decided by `infra_image` in the host's
`containers.conf` rather than by anything declared here. `<n>-net` is a
`--rootfs` container from the store running one statically linked binary --
catatonit copied in at `/pause`, no bind mounts, no `/nix/store`, no libc.

Several services in one *container* would need a supervisor, every supervisor
worth using (s6, runit) needs a writable scan directory, and this rootfs is a
read-only store path with no shell and no coreutils to populate one. A pod
gives the same property — services sharing one loopback interface and nothing
else — with crun as the only thing that ever forks, no init inside any
container, and each service in its own mount namespace with its own store view.

## Denied by default

| | |
|---|---|
| network | `--network=none`; loopback only, shared across the pod |
| listen | every port declared per protocol, or it is not bound and not accepted |
| egress | `mode = "none"`; nothing leaves but loopback and replies |
| capabilities | `--cap-drop=ALL`, `no-new-privileges` |
| root filesystem | `--read-only` |
| writable paths | none, unless declared; always `noexec,nosuid,nodev` |
| binaries | the service's own closure, nothing else |

## Egress modes

```nix
egress.mode = "none";          # default
egress.mode = "targets";       # only egress.targets = [ { address; port; protocol; } ]
egress.mode = "internet";      # public addresses only; RFC1918/CGNAT/ULA/link-local dropped
egress.mode = "internet";      # ...plus egress.lan = [ "192.168.176.0/24" ] to carve LAN back in
egress.mode = "unrestricted";  # escape hatch
```

Explicit `targets` and `lan` are accepted before the private-range drops, so a
named private destination beats the blanket rule.

## Usage

```nix
let
  prison = import ./nix/prison { inherit pkgs; };

  knotd = prison.mkPrisonService {
    name = "knotd";
    exec = [ "${pkgs.knot-dns}/bin/knotd" "--config" "/etc/knot.conf" "--no-daemon" ];
    uid = 1000;
    capabilities = [ "NET_BIND_SERVICE" ];
    state = [ { path = "/var/lib/knot"; size = "128M"; } ];
  };
in {
  services.prisons.dns = prison.mkPrison {
    name = "dns";
    services = { inherit knotd; };
    listen = { tcp = [ 53 ]; udp = [ 53 ]; };
    egress = { mode = "targets"; targets = [ { address = "198.51.100.2"; port = 53; } ]; };
  };
}
```

`exec[0]` must be an absolute store path: there is no `$PATH` in a prison and
no shell to resolve a name against.

## Units

```
prison-<n>.service        oneshot + RemainAfterExit: per-service FUSE store
                          views, the pod, and the nftables ruleset loaded into
                          the infra container's netns from the host
prison-<n>-<svc>.service  Type=exec, BindsTo the pod unit; systemd supervises
                          and restarts the container directly, because nothing
                          inside the pod can
```

## Measured

For a `knotd` service on this host:

```
host /nix/store                113628 paths
knotd store view                   83 paths, 262 executables, no shell
sibling service's view             10 paths
prison rootfs                       0 executables
```

`coreutils` is in that 83 because `knot-dns-bin → systemd → coreutils`: the
view is exactly the closure, so it contains whatever the package references.
Building the service against a systemd-less variant removes it.

## Runtime findings

Tested with rootless podman 5.8.6 + crun 1.27.1 (`nix shell nixpkgs#podman ...`).

**PID 1 needs an init.** `pid_namespaces(7)`: an ancestor namespace can signal
a child namespace's init "only if the init process has established a handler
for that signal". Same container, one flag apart:

| | PID 1 | `podman stop -t5` |
|---|---|---|
| no `--init` | the service | 5063 ms -- SIGTERM dropped, SIGKILL at timeout |
| `--init` | catatonit, service as PID 2 | 54 ms |

So `init = true` is the default. catatonit is bind-mounted at
`/run/podman-init`, so it never enters the store view.

**`--rootfs` is a boolean flag.** The path is the positional image argument and
must come last, immediately before argv. Emitting it earlier makes podman parse
the next flag as the command: ``executable file `--user` not found in ``.

**`/var/tmp` must exist in the rootfs.** podman's `--read-only-tmpfs` defaults
on and mounts tmpfs at `/run`, `/tmp` and `/var/tmp`; a read-only rootfs cannot
create the mount point, and crun fails before the service starts.

**The namespace owner runs with no image.** Verified on a live container:

```
image="" path=/pause args=["-P"] status=running
owner netns  : net:[4026533597]
service netns: net:[4026533597]
```

The host loads the ruleset into it with `podman unshare nsenter
--net=/proc/<pid>/ns/net nft -f`; listing it back from inside shows `policy
drop` with only the declared ports accepted.

**A static binary must be copied in, not bind-mounted.** crun has to create the
mount point before mounting, and cannot in a read-only rootfs: `mkdir
/nix/store/...-catatonit-0.2.1: Permission denied`. `/pause` is a build-time
copy instead, which is also why that container needs no `/nix/store`.

**The store view needs `--allow-other`.** The FUSE mount is owned by the
prison's host user; the container runs as a mapped subuid. Without it the
kernel denies access and crun reports ``failed to exec pid1: Permission
denied``, which reads like a missing binary. The module sets
`programs.fuse.userAllowOther`, without which `--allow-other` is refused.

## Not yet verified

A container booting against the narrowed FUSE view end to end. The view itself
is confirmed (10 paths, no shell, binaries resolve) and the container is
confirmed against the full host store, but joining the two needs
`user_allow_other`, which was off on the test host.
