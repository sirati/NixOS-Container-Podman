# prison

A default-deny podman jail for services, built on `nix-store-lower`,
`nix-store-shared-fuse` and the network-namespace-owner pattern from
`net-gateway.nix`.

## Shape

`mkPrison` is a podman **pod**; `mkPrisonService` is a container in it.

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

## Not yet done

No runtime test. The derivations build, the ruleset passes `nft -c`, and the
module evaluates; nothing here has yet started a pod.
