# prison

Default-deny confinement for services. Each service runs in its own container,
and all containers of a prison share one network namespace. Ports, egress,
capabilities and writable paths are denied unless declared.

`mkPrison` and `mkPrisonService` declare a service's command, user, ports,
egress, capabilities and writable paths. `podman-backend.nix` turns them into
podman command lines.

## Layers

```
default.nix          what a prison and its services are
capabilities.nix     the 41 Linux capabilities as typed fields, all false
podman.nix           the podman option model and the only code producing argv
podman-backend.nix   intent -> podman, including container names
module.nix           systemd units
ruleset.nix          the nftables policy
rootfs.nix           the toolless filesystem
no-shell.nix         refuses a store view that contains a shell
```

## Shape

`infra-net` owns the prison's network namespace, and every other service joins
it with `--network=container:<n>-infra-net`. `infra-net` is an ordinary service
that runs a pause process, so it gets the same rootfs, store view and denials as
the others.

There is no supervisor inside a prison. systemd on the host restarts a
container, and the init inside only forwards signals and reaps children. A
service's `/nix/store` holds only its own closure, so it has no shell, coreutils
or package manager unless the service depends on them.

## Denied by default

| | |
|---|---|
| network | loopback and IPv6 link control, shared across the prison |
| listen | only the ports declared per protocol are bound |
| egress | `mode = "none"`: only loopback, replies and IPv6 link control |
| capabilities | all dropped, `no-new-privileges` |
| root filesystem | read-only |
| writable paths | none unless declared, always `noexec,nosuid,nodev` |
| binaries | the service's own closure |

## Egress modes

```nix
egress.mode = "none";          # default
egress.mode = "targets";       # only egress.targets = [ { address; port; protocol; } ]
egress.mode = "internet";      # public addresses only; RFC1918/CGNAT/ULA/link-local dropped
egress.mode = "internet";      # ...plus egress.lan = [ "192.168.176.0/24" ] to allow a LAN range
egress.mode = "internet";      # ...limited to public ports: egress.ports = [ { port = 25; } { port = 443; protocol = "tcp"; } ]
egress.mode = "unrestricted";  # no egress filter
```

Explicit `targets` and `lan` entries match before the private-range drops, so a
named private destination is allowed.

IPv6 Neighbor Discovery and router messages with hop limit 255 are allowed on
the prison link so the kernel can keep its next-hop route. They allow no
application traffic.

## Usage

```nix
let
  prison = import ./nix/prison { inherit pkgs; };

  web = prison.mkPrisonService {
    name = "web";
    exec = [ "${pkgs.caddy}/bin/caddy" "run" "--config" "/config/Caddyfile" ];
    uid = 1000;
    capabilities.netBindService = true;
    state = [ { path = "/var/lib/caddy"; size = "128M"; } ];
    config = { Caddyfile = ./Caddyfile; };
  };
in {
  services.prisons.web = prison.mkPrison {
    name = "web";
    services = { inherit web; };
    listen = { tcp = [ 80 443 ]; };
    egress = { mode = "targets"; targets = [ { address = "198.51.100.2"; port = 443; } ]; };
  };
}
```

`exec[0]` must be an absolute store path, because a prison has no `$PATH` and no
shell to look a name up.

The NixOS module lists the generated files copied into service `/config`
directories in `services.nixDevContainer.generatedConfigFiles`.
`generatedConfigFilesByService` groups the same store paths by prison and
service name. Both are read-only and come from the config trees each service
unit's start and reload commands use. They do not include package closures or
other store inputs.

A capability is a named field, so a misspelled one fails evaluation instead of
granting nothing.

## Loopback policy

Services in one prison share a loopback, so by default any of them can open
any loopback port. `loopback` makes every new loopback connection a
declaration, judged by the uid of the socket that opens it:

```nix
services.prisons.edge = prison.mkPrison {
  name = "edge";
  services = { inherit caddy kanidm stalwart; };
  listen.tcp = [ 80 443 ];
  loopback = {
    ports = [
      { port = 8443; clients = [ "caddy" "kanidm" ]; }
      { port = 18081; clients = [ "stalwart" ]; }
    ];
    # Only caddy may send from 127.0.0.2, so kanidm can trust that address
    # as caddy for X-Forwarded-For.
    sources = [ { address = "127.0.0.2"; clients = [ "caddy" ]; } ];
  };
};
```

Clients are service names, resolved to their uids. A declared port rejects
everyone else. The prison's own `listen` ports stay open to every service,
because they are published anyway. Undeclared ports are rejected. uid 0 in the
namespace is the prison's host user, the one pasta uses to splice host-loopback
clients into published ports, so it is always allowed. A service can never run
as uid 0.

Uids are only distinct inside one user namespace, so a prison that `joins`
another may not declare `loopback`.

The policy covers TCP and UDP. Abstract unix sockets also belong to the netns,
and nftables does not see them.

## Sharing one netns between prisons

Services in one prison share a loopback, and one prison runs as one host user.
When a front door and its backends must run as different host users but still
talk over loopback, put them in two prisons and let one join the other's
namespace:

```nix
services.prisons.caddy = prison.mkPrison {
  name = "caddy";            # user `caddy` owns 80/443 and the policy
  services = { inherit caddy; };
  listen.tcp = [ 80 443 ];
  egress.mode = "internet";
};
services.prisons."octoai-git" = prison.mkPrison {
  name = "octoai-git";       # user `octoai-git`, same loopback
  joins = "caddy";
  services = { inherit forgejo; };
};
```

The joining prison keeps its own user, store views, state and units and shares
only the network namespace, so `reverse_proxy 127.0.0.1:3000` works across the
two users. The owner's ruleset is the only policy in that namespace, so a
joining prison may not declare `listen` or `egress`; everything reachable there
is declared on the owner, and a declaration on the joiner fails evaluation. A
prison that joins another cannot itself be joined.

Every `state` entry is a `noexec,nosuid,nodev` tmpfs. Its root is owned by the
service's `uid` and `gid` by default, so a non-root daemon can create sockets,
pid files and cache entries right away. Podman sets that owner from the service
user through its `chown=true` tmpfs option. Other per-mount owners are rejected
because Podman does not support them for tmpfs mounts.

A separate FUSE daemon unit serves each service's restricted `/nix/store`.
Linux requires `CAP_SYS_ADMIN` to register passthrough backing files, so only
that daemon gets it. The prison setup unit, Podman and the service containers
do not.

## Units

```
<n>.service         oneshot + RemainAfterExit: the store views, the namespace
                    owner, and the nftables ruleset loaded into its netns
<n>-<svc>.service   one per service, BindsTo <n>.service
```

A service's store view is exactly its closure, so it contains whatever the
package references. A static binary needs a few paths, and anything that
depends on systemd brings coreutils and a shell with it.

No shell may be in that closure. `no-shell.nix` checks every service's closure
and the store farm is built from its output, so a closure with bash,
bash-interactive, another shell package, or any path that ships `bin/sh` (or
another shell name in `bin/` or `sbin/`) fails the build and names what refers
to it. There is no opt-out. The usual causes are a `writeShellScript` wrapper,
a package whose `bin/` also holds helper scripts (`curl-config`, `zstdgrep`),
and single-output libraries that propagate `-dev` outputs.
