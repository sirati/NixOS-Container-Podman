# nftables ruleset for isolateLan, as a store file.
#
# Loaded by the HOST into the gateway container's network namespace. It is
# a build-time artifact on purpose: nothing inside either container writes,
# reads or can replace it, and its content is fixed by the configuration
# rather than by anything the container does at runtime.
{ pkgs
, allow ? [ ]      # extra IPv4 destinations to permit
, allow6 ? [ ]     # extra IPv6 destinations to permit
, resolver ? [ "169.254.1.1" ]  # pasta's own DNS forwarder
}:

let
  set = xs: "{ " + pkgs.lib.concatStringsSep ", " xs + " }";
  optRule = xs: rule: pkgs.lib.optionalString (xs != [ ]) rule;
in
pkgs.writeText "nixct-isolate-lan.nft" ''
  table inet nixct-isolate-lan {
    chain output {
      type filter hook output priority filter; policy accept;
      oifname "lo" accept
      ${optRule resolver "ip daddr ${set resolver} accept"}
      ${optRule allow "ip daddr ${set allow} accept"}
      ${optRule allow6 "ip6 daddr ${set allow6} accept"}
      ip daddr ${set [
        "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16"
        "169.254.0.0/16" "100.64.0.0/10"
      ]} reject with icmp type admin-prohibited
      ip6 daddr ${set [ "fc00::/7" "fe80::/10" ]} \
        reject with icmpv6 type admin-prohibited
    }
  }
''
