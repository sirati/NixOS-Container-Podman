# mkPrison / mkPrisonService: a default-deny jail for services.
#
# A prison is a set of containers sharing one network namespace. `infra-net`
# owns it and does nothing else; every other service is placed inside that
# namespace rather than getting one of its own. `infra-net` is not
# special-cased: it is an ordinary prison service whose exec happens to be
# a pause process, so it gets the same rootfs, the same store view and the
# same denials as everything else.
#
# This layer says WHAT, never HOW. Nothing here names a container runtime,
# a flag or a command line; nix/prison/podman-backend.nix is what turns
# this description into something that runs.
#
# Several services in one *container* would need a supervisor; every
# supervisor worth using needs a writable scan directory, and this rootfs is a
# read-only store path with no shell and no coreutils to populate one.
# Separate containers give the same property -- one shared loopback and
# nothing else -- with each service in its own mount namespace with its own
# store view, and no supervisor anywhere: systemd on the host restarts a
# container, and catatonit inside it only forwards signals and reaps, because
# PID 1 in a namespace ignores every signal it has no handler for
# (pid_namespaces(7)).
#
# What each service sees of /nix/store is its own closure and nothing more,
# served by nix-store-shared-fuse over the symlink farm from nix-store-lower.
# No shell, no coreutils, no package manager: a process that achieves code
# execution has no second binary to reach for.
#
# Everything is denied by default and opened by name: no network beyond
# loopback, every listening port declared per protocol, every egress
# destination declared or covered by a named mode, no capabilities, no
# privilege escalation, read-only root, and writable state only where asked
# for and always noexec,nosuid,nodev.

{ pkgs
, lib ? pkgs.lib
}:

let
  inherit (lib) mkOption types;

  nixStoreLower = import ../nix-store-lower.nix;
  mkRootfs = import ./rootfs.nix;
  mkRuleset = import ./ruleset.nix;
  capsLib = import ./capabilities.nix { inherit lib; };

  # Configuration lives at one fixed path in every container, so that changing
  # it never changes anything the container was created with.
  configDir = "/config";

  assertAbsolute = svc: argv:
    let a0 = builtins.head argv; in
    lib.throwIf (argv == [ ]) "prison: service ${svc} has an empty `exec`."
      (lib.throwIf (!lib.hasPrefix "/" a0) ''
        prison: service ${svc} has exec[0] = "${a0}", which is not an absolute path.

        A prison has no $PATH and no shell to resolve a name against. Give the
        store path: "''${pkgs.caddy}/bin/caddy".
      ''
        argv);

  # ---------------------------------------------------------------------
  # mkPrisonService: one confined process.
  # ---------------------------------------------------------------------
  mkPrisonService =
    { name
    , exec
    , uid ? 1000
    , gid ? uid
    , user ? name
    , packages ? [ ]
    , environment ? { }
    , state ? [ ]
    , persist ? [ ]
    # A typed capability set: one named field per Linux capability, every one
    # defaulting to false. Not a list of strings -- a misspelled string
    # renders a flag that grants nothing while reading as though it granted
    # something, whereas an unknown field is an evaluation error.
    , capabilities ? { }
    , readOnlyRoot ? true
    , init ? true
    , tmpfsSize ? "16M"
    # Files placed in the container's /config, keyed by name relative to it.
    # Values are store paths or derivations. Their CONTENTS are copied to a
    # host directory that is bind-mounted in, rather than the store path being
    # mounted directly, because a store path changes identity whenever the
    # content does -- and then the mount, and so the container, would have to
    # be recreated to pick up a new config. A directory the host rewrites in
    # place is visible immediately, so a reload stays a reload.
    , config ? { }
    # How to tell the service its configuration changed. `signal` is enough
    # for anything that reloads on SIGHUP; `exec` runs a command in the
    # container, which needs that binary in `packages`.
    , reload ? null
    # Hard RLIMIT_NOFILE for this service's store view.
    #
    # Every file held open behind the view costs a descriptor in the FUSE
    # process serving it, so this -- not the service's own limit -- is what
    # caps how many files the service can have open in the store at once.
    # Exceeding it surfaces as EMFILE from the service, a long way from the
    # cause. The FUSE raises its soft limit to this on startup; null inherits
    # whatever the prison unit was given.
    , openFiles ? null
    }:
    assert lib.assertMsg (uid != 0)
      "prison: service ${name} must not run as uid 0; that is what the container root account exists to avoid.";
    let
      argv = assertAbsolute name exec;

      # Kernel names of the capabilities this service was granted.
      grantedCaps = capsLib.granted
        (lib.evalModules {
          modules = [ { options = capsLib.options; } capabilities ];
        }).config;

      roots = [ (builtins.head argv) ] ++ packages;
      rootsDrv = pkgs.runCommand "prison-${name}-roots" { } ''
        printf '%s\n' ${lib.escapeShellArgs roots} > $out
      '';
      closure = pkgs.closureInfo { rootPaths = roots; };
      storeFarm = nixStoreLower { inherit pkgs closure; toplevel = rootsDrv; };

      rootfs = mkRootfs {
        inherit pkgs lib name configDir;
        users = [ { inherit uid gid; name = user; } ];
        extraDirs = map (s: s.path) state ++ map (p: p.path) persist;
      };

      # The configuration as a store tree. The host copies its contents out;
      # it is never mounted directly.
      configTree = pkgs.runCommand "prison-${name}-config" { } (''
        mkdir -p $out
      '' + lib.concatStrings (lib.mapAttrsToList
        (rel: src: ''
          install -Dm0444 ${src} "$out/${rel}"
        '')
        config));
    in
    {
      inherit name uid gid user argv environment state persist
        readOnlyRoot init tmpfsSize openFiles rootfs storeFarm closure
        config configTree reload;
      capabilities = grantedCaps;
      hasConfig = config != { };
      __prisonService = true;
    };

  # ---------------------------------------------------------------------
  # mkPrison: the namespace owner, the policy, and the service list.
  # ---------------------------------------------------------------------
  mkPrison =
    { name
    , services
    , listen ? { tcp = [ ]; udp = [ ]; }
    , egress ? { mode = "none"; targets = [ ]; lan = [ ]; }
    , user ? name
    , stateDir ? "/var/lib/${name}"
    }:
    let
      svcList =
        if builtins.isList services then services
        else lib.mapAttrsToList (n: s: s // { name = s.name or n; }) services;

      _check = lib.throwIf (svcList == [ ]) "prison: ${name} has no services."
        (lib.throwIf (!(builtins.all (s: s.__prisonService or false) svcList))
          "prison: ${name} was given something that is not a mkPrisonService result."
          (lib.throwIf (builtins.any (s: s.name == "infra-net") svcList)
            "prison: ${name} declares a service called infra-net, which is the name of the namespace owner."
            null));

      ruleset = mkRuleset { inherit pkgs lib listen egress; };

      # The namespace owner, built exactly like any other service. catatonit
      # comes from its own store view, so nothing is copied into a rootfs and
      # nothing is bind-mounted for it.
      infraNet = mkPrisonService {
        name = "infra-net";
        exec = [ "${pkgs.catatonit}/bin/catatonit" "-P" ];
        uid = 65000;
        # It has no init of its own: catatonit IS the init, and wrapping it in
        # another copy of itself would be silly.
        init = false;
      };

      wantsNetwork = (listen.tcp or [ ]) != [ ] || (listen.udp or [ ]) != [ ]
        || (egress.mode or "none") != "none";

      toPublish = proto: p:
        if builtins.isInt p then { port = p; protocol = proto; }
        else { inherit (p) port; protocol = proto; }
          // lib.optionalAttrs (p ? hostPort) { inherit (p) hostPort; };

      publish = map (toPublish "tcp") (listen.tcp or [ ])
        ++ map (toPublish "udp") (listen.udp or [ ]);
    in
    builtins.seq _check {
      inherit name svcList ruleset wantsNetwork publish user stateDir listen
        egress infraNet configDir;
      # Everything that needs a store view mounted, owner included.
      allServices = [ infraNet ] ++ svcList;
      __prison = true;
    };
in
{
  inherit mkPrison mkPrisonService configDir;
  ruleset = mkRuleset;
  rootfs = mkRootfs;
}
