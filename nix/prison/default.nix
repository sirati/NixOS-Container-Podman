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

{
  pkgs,
  lib ? pkgs.lib,
}:

let
  mkRootfs = import ./rootfs.nix;
  mkRuleset = import ./ruleset.nix;

  # Configuration lives at one fixed path in every container, so that changing
  # it never changes anything the container was created with.
  configDir = "/config";

  mkPrisonService = import ./service.nix {
    inherit
      pkgs
      lib
      mkRootfs
      configDir
      ;
    nixStoreLower = import ../nix-store-lower.nix;
    capsLib = import ./capabilities.nix { inherit lib; };
  };

  # ---------------------------------------------------------------------
  # mkPrison: the namespace owner, the policy, and the service list.
  # ---------------------------------------------------------------------
  mkPrison =
    {
      name,
      services,
      listen ? {
        tcp = [ ];
        udp = [ ];
      },
      egress ? {
        mode = "none";
        targets = [ ];
        lan = [ ];
      },
      pastaOptions ? [ ],
      resolvers ? [ ],
      user ? name,
      stateDir ? "/var/lib/${name}",
      # Share another prison's network namespace instead of owning one. The
      # prison keeps its own host user, store views, state directory and
      # units; only the netns -- and with it the shared loopback, the
      # published ports and the nftables policy -- comes from the named
      # prison, whose `<name>-infra-net` container every service here joins.
      # This is how two prisons run as different host users yet still talk
      # over loopback, e.g. a reverse proxy in front of its backends.
      #
      # A prison that joins must not declare `listen` or `egress` of its
      # own: the namespace owner's ruleset is the only policy in that
      # netns, so the union of everything reachable there is declared on
      # the owner. The module rejects a join target that does not exist or
      # that itself joins another prison (one hop only, no chains).
      joins ? null,
    }:
    let
      svcList =
        if builtins.isList services then
          services
        else
          lib.mapAttrsToList (n: s: s // { name = s.name or n; }) services;

      joining = joins != null;

      _check = lib.throwIf (svcList == [ ]) "prison: ${name} has no services." (
        lib.throwIf (!(builtins.all (s: s.__prisonService or false) svcList))
          "prison: ${name} was given something that is not a mkPrisonService result."
          (
            lib.throwIf (builtins.any (s: s.name == "infra-net") svcList)
              "prison: ${name} declares a service called infra-net, which is the name of the namespace owner."
              (
                lib.throwIf (joining && joins == name) "prison: ${name} joins itself." (
                  lib.throwIf (joining && ((listen.tcp or [ ]) != [ ] || (listen.udp or [ ]) != [ ]))
                    ''
                      prison: ${name} joins ${joins} and also declares listen ports.

                      The namespace owner's ruleset is the only policy in that
                      netns. Declare the ports on ${joins} instead.
                    ''
                    (
                      lib.throwIf
                        (
                          joining
                          && (
                            (egress.mode or "none") != "none" || (egress.targets or [ ]) != [ ] || (egress.lan or [ ]) != [ ]
                          )
                        )
                        ''
                          prison: ${name} joins ${joins} and also declares egress.

                          The namespace owner's ruleset is the only policy in that
                          netns. Declare the egress on ${joins} instead.
                        ''
                        (
                          lib.throwIf (
                            joining && pastaOptions != [ ]
                          ) "prison: ${name} joins ${joins} and also declares pastaOptions." null
                        )
                    )
                )
              )
          )
      );

      ruleset =
        if joining then
          null
        else
          mkRuleset {
            inherit
              pkgs
              lib
              listen
              egress
              resolvers
              ;
          };

      # The namespace owner, built exactly like any other service. catatonit
      # comes from its own store view, so nothing is copied into a rootfs and
      # nothing is bind-mounted for it. A prison that joins another's netns
      # has no owner of its own.
      infraNet =
        if joining then
          null
        else
          mkPrisonService {
            name = "infra-net";
            exec = [
              "${pkgs.catatonit}/bin/catatonit"
              "-P"
            ];
            uid = 65000;
            # It has no init of its own: catatonit IS the init, and wrapping it in
            # another copy of itself would be silly.
            init = false;
          };

      wantsNetwork =
        (!joining)
        && (
          (listen.tcp or [ ]) != [ ]
          || (listen.udp or [ ]) != [ ]
          || (egress.mode or "none") != "none"
          || pastaOptions != [ ]
        );

      toPublish =
        proto: p:
        if builtins.isInt p then
          {
            port = p;
            protocol = proto;
          }
        else
          {
            inherit (p) port;
            protocol = proto;
          }
          // lib.optionalAttrs (p ? hostPort) { inherit (p) hostPort; };

      publish =
        if joining then
          [ ]
        else
          map (toPublish "tcp") (listen.tcp or [ ]) ++ map (toPublish "udp") (listen.udp or [ ]);
    in
    builtins.seq _check {
      inherit
        name
        svcList
        ruleset
        wantsNetwork
        publish
        pastaOptions
        resolvers
        user
        stateDir
        listen
        egress
        infraNet
        joins
        configDir
        ;
      # Everything that needs a store view mounted, owner included. A
      # prison that joins has no owner, so only its own services.
      allServices = (if joining then [ ] else [ infraNet ]) ++ svcList;
      __prison = true;
    };
in
{
  inherit mkPrison mkPrisonService configDir;
  ruleset = mkRuleset;
  rootfs = mkRootfs;
}
