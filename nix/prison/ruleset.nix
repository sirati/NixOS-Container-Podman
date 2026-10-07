# The prison's network policy, as an nftables ruleset in the store.
#
# Loaded by the HOST into the netns-owner container's namespace before
# anything joins it, exactly as nix/lan-ruleset.nix is. Nothing inside the
# prison reads, writes or can replace it, and the prison holds no capability
# to change what was loaded -- it is on the wrong side of the namespace
# boundary, which is the whole point of a separate namespace owner.
#
# Differs from lan-ruleset.nix in polarity: that one is default-accept with
# private ranges carved out, this one is default-drop with everything carved
# in. A prison that fails to load its ruleset is a prison with no network,
# not a prison with an open one.

{
  pkgs,
  lib ? pkgs.lib,
  listen ? {
    tcp = [ ];
    udp = [ ];
  },
  egress ? {
    mode = "none";
    targets = [ ];
    lan = [ ];
  },
  resolvers ? [ ],
  # null leaves loopback open to every service in the netns. Otherwise each
  # new loopback connection must be declared, by the socket owner's uid:
  #   ports   = [ { port; protocol ? "tcp"; clients = [ uid ... ]; } ]
  #   sources = [ { address; clients = [ uid ... ]; } ]
  # A source entry reserves a loopback address to its clients, so a server
  # can trust that address as their identity.
  loopback ? null,
}:

let
  inherit (lib) concatMapStringsSep concatStringsSep optionalString;

  set = xs: "{ " + concatStringsSep ", " (map toString xs) + " }";

  validUid = uid: builtins.isInt uid && uid > 0;
  checkClients =
    what: clients:
    if !(builtins.isList clients) || clients == [ ] then
      throw "prison: loopback ${what} needs a non-empty list of client uids"
    else if !(builtins.all validUid clients) then
      throw "prison: loopback ${what} clients must be positive uids; uid 0 is the namespace root and always allowed"
    else
      lib.unique clients;

  loopbackPorts = map (
    p:
    let
      proto = p.protocol or "tcp";
      what = "${proto} port ${toString (p.port or "?")}";
    in
    if !(builtins.isInt (p.port or null)) || p.port < 1 || p.port > 65535 then
      throw "prison: loopback ports need a port between 1 and 65535"
    else if proto != "tcp" && proto != "udp" then
      throw "prison: loopback port protocol must be tcp or udp, not ${proto}"
    else
      {
        inherit (p) port;
        protocol = proto;
        clients = checkClients what (p.clients or [ ]);
      }
  ) (if loopback == null then [ ] else loopback.ports or [ ]);

  loopbackSources = map (
    s:
    let
      address = s.address or "";
    in
    if !(lib.hasPrefix "127." address) || lib.hasInfix "/" address then
      throw "prison: loopback sources must be single 127.0.0.0/8 addresses, not ${address}"
    else if address == "127.0.0.1" then
      throw "prison: 127.0.0.1 is every service's default source and cannot be reserved"
    else
      {
        inherit address;
        clients = checkClients "source ${address}" (s.clients or [ ]);
      }
  ) (if loopback == null then [ ] else loopback.sources or [ ]);

  portKeys = map (p: "${p.protocol}/${toString p.port}") loopbackPorts;
  _uniquePorts = lib.throwIf (lib.length portKeys != lib.length (lib.unique portKeys))
    "prison: a loopback port is declared twice; list every client in one entry" null;

  # Ranges that are, by definition, not the public internet. `mode =
  # "internet"` rejects these so that "may talk to the internet" cannot be
  # quietly read as "may talk to the machine next to it".
  privateV4 = [
    "0.0.0.0/8"
    "127.0.0.0/8"
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "169.254.0.0/16"
    "100.64.0.0/10"
    # Documentation ranges are also used as synthetic pasta links. Treating
    # them as internet would let an internet-mode prison reach every host
    # service through its mapped gateway instead of only declared targets.
    "192.0.2.0/24"
    "198.51.100.0/24"
    "203.0.113.0/24"
    "224.0.0.0/4"
    "240.0.0.0/4"
  ];
  privateV6 = [
    "fc00::/7"
    "fe80::/10"
  ];

  isV6 = a: lib.hasInfix ":" a;

  # An egress target is one address and one port. Both are required: a rule
  # naming only a host would permit every service on it, which is the kind of
  # allowance that gets written once and never revisited.
  targetRule =
    t:
    let
      fam = if isV6 t.address then "ip6" else "ip";
      proto = t.protocol or "tcp";
    in
    "    ${fam} daddr ${t.address} ${proto} dport ${toString t.port} accept";

  listenRule =
    proto: p:
    if builtins.isInt p then
      "    ${proto} dport ${toString p} accept"
    else
      "    ${
            optionalString (p.address or null != null)
              "${if isV6 p.address then "ip6" else "ip"} daddr ${p.address} "
          }${proto} dport ${toString p.port} accept";

  tcpListens = listen.tcp or [ ];
  udpListens = listen.udp or [ ];

  mode = egress.mode or "none";
  targets = egress.targets or [ ];
  lanAllow = egress.lan or [ ];
  # Internet mode may be narrowed to the public ports a service needs; an
  # empty list keeps every port.
  publicPorts = map (
    p:
    let
      proto = p.protocol or "tcp";
    in
    if !(builtins.isInt (p.port or null)) || p.port < 1 || p.port > 65535 then
      throw "prison: egress.ports entries need a port between 1 and 65535"
    else if proto != "tcp" && proto != "udp" then
      throw "prison: egress.ports protocol must be tcp or udp, not ${proto}"
    else
      { port = p.port; protocol = proto; }
  ) (egress.ports or [ ]);
  publicAccept =
    fam: any:
    if publicPorts == [ ] then
      "${fam} daddr ${any} accept"
    else
      concatMapStringsSep "\n        " (
        p: "${fam} daddr ${any} ${p.protocol} dport ${toString p.port} accept"
      ) publicPorts;

  lanV4 = lib.filter (a: !(isV6 a)) lanAllow;
  lanV6 = lib.filter isV6 lanAllow;

  egressBody =
    if publicPorts != [ ] && mode != "internet" then
      throw "prison: egress.ports only narrows egress.mode = \"internet\""
    else if mode == "none" then
      "    # egress.mode = \"none\": only loopback, replies, and IPv6 link control."
    else if mode == "targets" then
      concatMapStringsSep "\n" targetRule targets
    else if mode == "internet" then
      concatMapStringsSep "\n" targetRule targets
      + optionalString (targets != [ ]) "\n"
      + optionalString (lanV4 != [ ]) "    ip daddr ${set lanV4} accept\n"
      + optionalString (lanV6 != [ ]) "    ip6 daddr ${set lanV6} accept\n"
      + ''
        # Everything that is not a private range. The drops come first so an
        # `accept` below cannot be reached by a private destination.
        ip daddr ${set privateV4} drop
        ip6 daddr ${set privateV6} drop
        ${publicAccept "ip" "0.0.0.0/0"}
        ${publicAccept "ip6" "::/0"}''
    else if mode == "unrestricted" then
      ''
        # egress.mode = "unrestricted": the escape hatch. Everything the
            # host can reach, the prison can reach.
            ip daddr 0.0.0.0/0 accept
            ip6 daddr ::/0 accept''
    else
      throw "prison: unknown egress.mode ${mode} (expected none, targets, internet or unrestricted)";

  # Every new loopback flow is judged by the uid owning the sending socket,
  # as seen from the netns owner's user namespace. A prison's services share
  # that namespace with distinct uids, so a uid is a service identity here.
  loopbackChain = ''
    chain loopback {
      # The namespace root is the prison's host user: pasta splicing
      # host-loopback clients into published ports. No service runs as uid 0.
      meta skuid 0 accept
  ${concatMapStringsSep "\n" (
    s: "    ip saddr ${s.address} meta skuid != ${set s.clients} reject"
  ) loopbackSources}
  ${concatMapStringsSep "\n" (
    p:
    "    ${p.protocol} dport ${toString p.port} meta skuid ${set p.clients} accept\n"
    + "    ${p.protocol} dport ${toString p.port} reject${
      optionalString (p.protocol == "tcp") " with tcp reset"
    }"
  ) loopbackPorts}
      # A port published to the world is no secret from a neighbour.
  ${optionalString (tcpListens != [ ]) (concatMapStringsSep "\n" (listenRule "tcp") tcpListens)}
  ${optionalString (udpListens != [ ]) (concatMapStringsSep "\n" (listenRule "udp") udpListens)}
      meta l4proto tcp reject with tcp reset
      reject
    }
  '';
in
builtins.seq _uniquePorts pkgs.writeText "prison-ruleset.nft" ''
  # Generated by mkPrison. Loaded into the netns-owner container from the
  # host; unreachable and unmodifiable from inside the prison.
  table inet prison {
    chain input {
      type filter hook input priority filter; policy drop;
      iif "lo" accept
      # IPv6 cannot use its next-hop route without Neighbor Discovery.
      # These messages are link-local control traffic, not application ingress.
      # Pasta can inherit the host uplink name; match names without resolving
      # an interface index while the namespace network is still starting.
      iifname != "lo" ip6 hoplimit 255 icmpv6 type { nd-router-advert, nd-neighbor-solicit, nd-neighbor-advert } accept
      ct state established,related accept
      ct state invalid drop
  ${optionalString (tcpListens != [ ]) (concatMapStringsSep "\n" (listenRule "tcp") tcpListens)}
  ${optionalString (udpListens != [ ]) (concatMapStringsSep "\n" (listenRule "udp") udpListens)}
    }

    chain output {
      type filter hook output priority filter; policy drop;
  ${optionalString (loopback != null) "    oif \"lo\" ct state new jump loopback"}
      oif "lo" accept
      oifname != "lo" ip6 hoplimit 255 icmpv6 type { nd-router-solicit, nd-neighbor-solicit, nd-neighbor-advert } accept
      ct state established,related accept
      ct state invalid drop
  ${optionalString (resolvers != [ ])
    "    ip daddr ${set resolvers} udp dport 53 accept\n    ip daddr ${set resolvers} tcp dport 53 accept"
  }
  ${egressBody}
    }

    # Nothing is routed through a prison.
    chain forward {
      type filter hook forward priority filter; policy drop;
    }
  ${optionalString (loopback != null) loopbackChain}
  }
''
