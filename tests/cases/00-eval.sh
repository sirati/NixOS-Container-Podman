#!/usr/bin/env bash
#
# Everything that can be decided without starting a container.
#
# These are the checks that keep a mistake from being expressible at all,
# so they are also the ones that must fail loudly when someone loosens a
# type: a suite that only tested the happy path would pass just as well
# against a model that validates nothing.

# shellcheck source=../lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

echo "== eval: the podman model =="

PODMAN='let p = import (flake.outPath + "/nix/podman.nix") { inherit lib; }; in'

# --rootfs is a boolean flag whose path is the positional image argument,
# so the path and the command must be the last two things on the line.
# This is the bug that made podman parse `--user` as the command.
# shellcheck disable=SC2016 # not expanding is the property under test
eval_ends_with "renderRun puts --rootfs and the command last" \
  '--rootfs "$MERGED:O" /init' \
  "$PODMAN p.renderRunShell \"pm\" {
    name = \"c\"; command = [ \"/init\" ]; rootfs = p.rt \"MERGED\";
  }"

# A literal must not be re-expanded by the shell; a runtime value must be.
# One line shows both: a literal that LOOKS like an expansion stays a
# literal, and the runtime value next to it does not.
check_out "a literal that looks like an expansion is not expanded" \
  "--env 'FOO=\$HOME'" \
  nix_eval "$PODMAN p.renderRunShell \"pm\" {
    name = \"c\"; command = [ \"/init\" ]; rootfs = p.rt \"MERGED\";
    env.FOO = \"\$HOME\";
  }"

eval_fails "an empty command is a type error" "has an empty command" \
  "$PODMAN p.renderRunShell \"pm\" { name = \"c\"; command = [ ]; rootfs = \"/r\"; }"

eval_fails "a relative command[0] is a type error" "not an absolute path" \
  "$PODMAN p.renderRunShell \"pm\" { name = \"c\"; command = [ \"init\" ]; rootfs = \"/r\"; }"

# podman rejects this at runtime; here it never renders.
eval_fails "publishing a port while joining another namespace is a type error" \
  "publishes ports" \
  "$PODMAN p.renderRunShell \"pm\" {
     name = \"c\"; command = [ \"/init\" ]; rootfs = \"/r\";
     network = {
       mode = \"container\"; container = \"gw\";
       publish = [ { port = 53; protocol = \"tcp\"; } ];
     };
   }"

echo "== eval: prison =="

PRISON='let prison = import (flake.outPath + "/nix/prison") { inherit pkgs; };
        svc = args: prison.mkPrisonService ({ name = "s"; exec = [ "/bin/true" ]; } // args); in'

eval_is "a service is granted no capabilities by default" "" \
  "$PRISON toString (svc { }).capabilities"

eval_is "a granted capability renders its kernel name" "CAP_NET_BIND_SERVICE" \
  "$PRISON toString (svc { capabilities.netBindService = true; }).capabilities"

# The reason capabilities are a typed set and not a list of strings.
eval_fails "a misspelled capability is an evaluation error" "does not exist" \
  "$PRISON toString (svc { capabilities.netBindServic = true; }).capabilities"

# A credential in the store is readable by every user on the machine.
eval_fails "a persisted path in the nix store is refused" "in the Nix store" \
  "$PRISON toString (svc {
     persist = [ { host = \"\${builtins.storeDir}/aaaa-tsig.conf\"; path = \"/secrets/t\"; } ];
   }).persist"

eval_fails "a persisted path that is relative is refused" "not an absolute path" \
  "$PRISON toString (svc {
     persist = [ { host = \"secrets/tsig.conf\"; path = \"/secrets/t\"; } ];
   }).persist"

eval_is "a read-only persisted file is mounted where it was asked for" "/secrets/t.conf" \
  "$PRISON toString (map (x: x.path) (svc {
     persist = [ { host = \"/var/lib/secrets/t.conf\"; path = \"/secrets/t.conf\";
                   readOnly = true; file = true; } ];
   }).persist)"

eval_fails "a service may not run as uid 0" "must not run as uid 0" \
  "$PRISON toString (svc { uid = 0; }).uid"

eval_fails "a service exec must be an absolute path" "not an absolute path" \
  "$PRISON toString (svc { exec = [ \"caddy\" ]; }).argv"

eval_fails "an empty prison is an evaluation error" "has no services" \
  "$PRISON (prison.mkPrison { name = \"p\"; services = [ ]; }).name"

eval_fails "a prison rejects a service that is not one" "not a mkPrisonService result" \
  "$PRISON (prison.mkPrison { name = \"p\"; services = [ { name = \"x\"; } ]; }).name"

eval_fails "a prison rejects a service called infra-net" "namespace owner" \
  "$PRISON (prison.mkPrison {
      name = \"p\"; services = [ (svc { name = \"infra-net\"; }) ];
    }).name"

# Default deny: nothing declared means nothing is reachable, and the
# namespace owner is the only thing that exists.
eval_is "a prison wants no network until something asks for one" "false" \
  "$PRISON lib.boolToString (prison.mkPrison {
      name = \"p\"; services = [ (svc { }) ];
    }).wantsNetwork"

eval_is "the namespace owner is an ordinary service, not a special case" "infra-net" \
  "$PRISON (prison.mkPrison { name = \"p\"; services = [ (svc { }) ]; }).infraNet.name"

echo "== eval: unsupported values fail loud =="

# Every one of these must say "not implemented" -- the point is that an
# unsupported value stops the build rather than silently producing a
# tarball missing the feature that was asked for.
PORTABLE='let f = import (flake.outPath + "/nix/portable-tarball.nix");
          # Every argument is lazy, so only the ones the assertions look at
          # need a real value; deriving the rest from the signature keeps
          # this from breaking every time the argument list changes.
          base = lib.mapAttrs (_: _: null) (builtins.functionArgs f)
                 // { format = "squashfs"; hostNixStore = false;
                      hostNixDaemon = false; isolateLan = false; };
          with_ = extra: (f (base // extra)).drvPath; in'

eval_fails "portable tarball: an unknown format is not implemented" "not implemented" \
  "$PORTABLE with_ { format = \"tar\"; }"
eval_fails "portable tarball: hostNixStore is not implemented" "not implemented" \
  "$PORTABLE with_ { hostNixStore = true; }"
eval_fails "portable tarball: hostNixDaemon is not implemented" "not implemented" \
  "$PORTABLE with_ { hostNixDaemon = true; }"
eval_fails "portable tarball: isolateLan is not implemented" "not implemented" \
  "$PORTABLE with_ { isolateLan = true; }"

eval_fails "mkContainer rejects an unknown storage axis" "invalid" \
  "(ct.mkContainer { modules = [ ]; storage = \"bogus\"; }).run.drvPath"

finish
