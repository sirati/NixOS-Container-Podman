# prison

Default-deny confinement for services: one container per service, all sharing a
single network namespace, with nothing allowed until it is named.

`mkPrison` and `mkPrisonService` say what a service is and what it may do.
They are backend agnostic — nothing in them names a container runtime, a flag
or a command line; `podman-backend.nix` is what turns a prison into something
that runs.

## Layers

```
default.nix          what a prison and its services ARE
capabilities.nix     the 41 Linux capabilities as typed fields, all false
podman.nix           the podman option model and the only code producing argv
podman-backend.nix   intent -> podman, including container names
module.nix           systemd units
ruleset.nix          the nftables policy
rootfs.nix           the toolless filesystem
```

## Shape

A prison is a set of containers sharing one network namespace. `infra-net`
owns it and every other service joins with `--network=container:<n>-infra-net`.
It is an ordinary service whose exec happens to be a pause process, so it gets
the same rootfs, store view and denials as everything else.

Each service is its own container, so there is no supervisor: systemd on the
host restarts a container, and the init inside only forwards signals and reaps.
A service sees its own closure of `/nix/store` and nothing more — no shell, no
coreutils, no package manager.

## Denied by default

| | |
|---|---|
| network | loopback only, shared across the prison |
| listen | every port declared per protocol, or it is not bound |
| egress | `mode = "none"`; nothing leaves but loopback and replies |
| capabilities | all dropped, `no-new-privileges` |
| root filesystem | read-only |
| writable paths | none unless declared; always `noexec,nosuid,nodev` |
| binaries | the service's own closure, nothing else |

## Egress modes

```nix
egress.mode = "none";          # default
egress.mode = "targets";       # only egress.targets = [ { address; port; protocol; } ]
egress.mode = "internet";      # public addresses only; RFC1918/CGNAT/ULA/link-local dropped
egress.mode = "internet";      # ...plus egress.lan = [ "192.168.176.0/24" ] to carve LAN back in
egress.mode = "unrestricted";  # escape hatch
```

Explicit `targets` and `lan` are matched before the private-range drops, so a
named private destination beats the blanket rule.

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

`exec[0]` must be an absolute store path: a prison has no `$PATH` and no shell
to resolve a name against.

A capability is a named field, not a string, so an unknown one is an
evaluation error rather than a flag that grants nothing.

## Units

```
<n>.service         oneshot + RemainAfterExit: the store views, the namespace
                    owner, and the nftables ruleset loaded into its netns
<n>-<svc>.service   Type=exec, one per service, BindsTo <n>.service
```

A service's store view is exactly its closure, so it carries whatever the
package references — a static binary needs a handful of paths, while anything
pulling in systemd brings coreutils and a shell with it.
