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

eval_is "pasta options are rendered inside the network argument" \
  "pasta:--map-gw,--dns-forward,192.0.2.3" \
  "$PODMAN let argv = p.renderRun \"podman\" {
      name = \"c\"; command = [ \"/init\" ]; rootfs = \"/r\";
      network = {
        mode = \"pasta\";
        pastaOptions = [ \"--map-gw\" \"--dns-forward\" \"192.0.2.3\" ];
      };
    }; i = lib.lists.findFirstIndex (x: x == \"--network\") null argv;
    in builtins.elemAt argv (i + 1)"

eval_fails "pasta options require pasta mode" "sets pastaOptions" \
  "$PODMAN p.renderRunShell \"pm\" {
     name = \"c\"; command = [ \"/init\" ]; rootfs = \"/r\";
     network.pastaOptions = [ \"--map-gw\" ];
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

eval_fails "ephemeral state cannot promise an unsupported arbitrary owner" \
  "cannot assign an arbitrary owner" \
  "$PRISON toString (svc {
      state = [ { path = \"/run/service\"; uid = 42; } ];
    }).state"

eval_is "tmpfs renders owner, mode and hardening flags" \
  "type=tmpfs,destination=/run/service,chown=true,rw,noexec,nosuid,nodev,tmpfs-size=8M,tmpfs-mode=0750" \
  "$PODMAN let argv = p.renderRun \"podman\" {
      name = \"c\"; command = [ \"/bin/true\" ]; rootfs = \"/root\";
      mounts = [ { type = \"tmpfs\"; destination = \"/run/service\";
                   readOnly = false; size = \"8M\"; mode = \"0750\";
                   chown = true; } ];
    }; i = lib.lists.findFirstIndex (x: x == \"--mount\") null argv;
    in builtins.elemAt argv (i + 1)"

# Evaluate the final NixOS units, not only the intermediate service model.
# The passthrough ioctl needs CAP_SYS_ADMIN for every backing-file open, but
# that capability must stop at its dedicated FUSE daemon.
PRISON_SYSTEM='let
  prison = import (flake.outPath + "/nix/prison") { inherit pkgs; };
  svc = prison.mkPrisonService {
    name = "s"; uid = 1234; exec = [ "/bin/true" ];
    config."nested/test.conf" = pkgs.writeText "prison-test.conf" "ok";
  };
  p = prison.mkPrison {
    name = "p"; services = [ svc ]; resolvers = [ "192.0.2.3" ];
    pastaOptions = [ "--map-gw" ];
  };
  system = lib.nixosSystem {
    modules = [
      (import (flake.outPath + "/nix/prison/module.nix") { inherit prison; })
      { services.prisons.p = p; system.stateVersion = "26.05";
        nixpkgs.hostPlatform = builtins.currentSystem; }
    ];
  };
in'

eval_is "config inventory names the exact file copied by the generated unit" "true" \
  "$PRISON_SYSTEM let
      files = system.config.services.nixDevContainer.generatedConfigFiles;
      grouped = system.config.services.nixDevContainer.generatedConfigFilesByService.p.s;
      unit = system.config.systemd.services.p-s.serviceConfig;
      expected = \"\${svc.configTree}/nested/test.conf\";
    in lib.boolToString
      (files == [ expected ] && grouped == files
       && lib.hasInfix
         (builtins.unsafeDiscardStringContext (toString svc.configTree))
         (builtins.unsafeDiscardStringContext (builtins.head unit.ExecStartPre)))"

eval_is "only the store daemon receives the passthrough capability" \
  "CAP_SYS_ADMIN:CAP_SYS_ADMIN:true:0:0" \
  "$PRISON_SYSTEM let
      store = system.config.systemd.services.p-store-s.serviceConfig;
      setup = system.config.systemd.services.p.serviceConfig;
      service = system.config.systemd.services.p-s.serviceConfig;
    in \"\${builtins.head store.AmbientCapabilities}:\${builtins.head store.CapabilityBoundingSet}:\${lib.boolToString store.NoNewPrivileges}:\${toString (builtins.length (setup.AmbientCapabilities or []))}:\${toString (builtins.length (service.AmbientCapabilities or []))}\""

eval_is "the generated service container drops every capability" "true" \
  "$PRISON_SYSTEM let
      argv = system.config.systemd.services.p-s.serviceConfig.ExecStart;
    in lib.boolToString
      (lib.hasInfix \"--cap-drop=ALL\" argv && !lib.hasInfix \"--cap-add\" argv)"

eval_is "only the namespace owner replaces a stale reboot remnant" "true:false" \
  "$PRISON let
      serviceModel = svc { };
      p = prison.mkPrison { name = \"p\"; services = [ serviceModel ]; };
      backend = import (flake.outPath + \"/nix/prison/podman-backend.nix\") { inherit pkgs lib; };
      owner = backend.runOwner p;
      service = backend.runService p serviceModel;
    in \"\${lib.boolToString (builtins.elem \"--replace\" owner)}:\${lib.boolToString (builtins.elem \"--replace\" service)}\""

eval_is "a prison mounts its explicit resolver configuration read-only" "true" \
  "$PRISON_SYSTEM let
      argv = system.config.systemd.services.p-s.serviceConfig.ExecStart;
    in lib.boolToString
      (lib.hasInfix \"destination=/etc/resolv.conf\" argv
       && lib.hasInfix \"source=/nix/store/\" argv)"

eval_is "a networked prison waits for the host network to be online" "true" \
  "$PRISON_SYSTEM let
      unit = system.config.systemd.services.p;
    in lib.boolToString
      (builtins.elem \"network-online.target\" unit.after
       && builtins.elem \"network-online.target\" unit.wants)"

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

eval_is "pasta options make a prison request a network" "true" \
  "$PRISON lib.boolToString (prison.mkPrison {
      name = \"p\"; services = [ (svc { }) ]; pastaOptions = [ \"--map-gw\" ];
    }).wantsNetwork"

eval_is "the namespace owner is an ordinary service, not a special case" "infra-net" \
  "$PRISON (prison.mkPrison { name = \"p\"; services = [ (svc { }) ]; }).infraNet.name"

# A prison can share another prison's netns while keeping its own host
# user: one loopback, two users. The joiner owns nothing networked.
eval_is "a joining prison wants no network of its own" "false" \
  "$PRISON lib.boolToString (prison.mkPrison {
      name = \"g\"; joins = \"caddy\"; services = [ (svc { }) ];
    }).wantsNetwork"

eval_is "a joining prison publishes nothing" "0" \
  "$PRISON toString (builtins.length (prison.mkPrison {
      name = \"g\"; joins = \"caddy\"; services = [ (svc { }) ];
    }).publish)"

eval_is "a joining prison mounts no owner store view" "1" \
  "$PRISON toString (builtins.length (prison.mkPrison {
      name = \"g\"; joins = \"caddy\"; services = [ (svc { }) ];
    }).allServices)"

eval_is "a joining service is placed in the owning prison's namespace" "caddy-infra-net" \
  'let prison = import (flake.outPath + "/nix/prison") { inherit pkgs; };
       backend = import (flake.outPath + "/nix/prison/podman-backend.nix") { inherit pkgs; };
   in (backend.serviceSpec
     { name = "g"; joins = "caddy"; stateDir = "/var/lib/g"; configDir = "/config"; }
     (prison.mkPrisonService { name = "s"; exec = [ "/bin/true" ]; })).network.container'

eval_fails "a joining prison may not declare listen ports" "joins" \
  "$PRISON (prison.mkPrison {
      name = \"g\"; joins = \"caddy\"; services = [ (svc { }) ];
      listen.tcp = [ 80 ];
    }).name"

eval_fails "a joining prison may not declare egress" "joins" \
  "$PRISON (prison.mkPrison {
      name = \"g\"; joins = \"caddy\"; services = [ (svc { }) ];
      egress.mode = \"internet\";
    }).name"

eval_fails "a prison may not join itself" "joins itself" \
  "$PRISON (prison.mkPrison {
      name = \"g\"; joins = \"g\"; services = [ (svc { }) ];
    }).name"

eval_is "internet mode blocks the synthetic host gateway unless targeted" "true" \
  'let prison = import (flake.outPath + "/nix/prison") { inherit pkgs; };
       rules = prison.ruleset {
         inherit pkgs;
         egress.mode = "internet";
         egress.targets = [ { address = "192.0.2.1"; port = 53; } ];
       };
   in lib.boolToString
     (lib.hasInfix "ip daddr 192.0.2.1 tcp dport 53 accept" (builtins.readFile rules)
      && lib.hasInfix "192.0.2.0/24" (builtins.readFile rules))'

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
