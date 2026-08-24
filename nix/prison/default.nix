# mkPrison / mkPrisonService: a default-deny podman jail for services.
#
# A prison is a podman *pod*; each service in it is a container in that pod.
# That is a deliberate departure from "several services in one container", and
# the reason is mechanical rather than stylistic: running N processes inside
# one container requires a supervisor, every supervisor worth using (s6,
# runit) needs a writable scan directory, and the rootfs here is a read-only
# store path with no shell and no coreutils to populate one at startup. A pod
# gets the same property -- services sharing one loopback interface and
# nothing else -- with each service confined to its own mount namespace and
# its own store view, and no supervisor anywhere: systemd on the host restarts
# a container, and catatonit inside it does nothing but forward signals and
# reap, because PID 1 in a namespace ignores every signal it has no handler
# for (pid_namespaces(7)).
#
# What each service can see of /nix/store is its own closure and nothing more,
# served by nix-store-shared-fuse over the symlink farm from nix-store-lower.
# There is no shell, no coreutils and no package manager in any of it, so a
# process that achieves code execution has no second binary to reach for.
#
# Everything is denied by default and opened by name:
#   * no network at all beyond the pod's own loopback
#   * every listening port declared explicitly, per protocol
#   * every egress destination declared explicitly, or a named blanket mode
#   * no capabilities, no privilege escalation, read-only root
#   * writable state only where asked for, always noexec,nosuid,nodev
#
# The pod's network namespace is owned by its infra container and policed
# from the HOST with nftables, following nix/net-gateway.nix: nothing inside
# the pod can read or replace the ruleset that governs it.

{ pkgs
, lib ? pkgs.lib
}:

let
  inherit (lib) mkOption types;

  nixStoreLower = import ../nix-store-lower.nix;
  mkRootfs = import ./rootfs.nix;
  mkRuleset = import ./ruleset.nix;
  fuse = import ../fuse.nix { inherit pkgs; };

  # A service's entry point is argv, and argv[0] must be a store path. There
  # is no $PATH in a prison to resolve a bare name against, and a bare name
  # would be resolved against whatever the store view happens to contain.
  assertAbsolute = svc: argv:
    let a0 = builtins.head argv; in
    lib.throwIf (argv == [ ]) "prison: service ${svc} has an empty `exec`."
      (lib.throwIf (!lib.hasPrefix "/" a0) ''
        prison: service ${svc} has exec[0] = "${a0}", which is not an absolute path.

        A prison has no $PATH and no shell to resolve a name against. Give the
        store path: "''${pkgs.knot-dns}/bin/knotd".
      ''
        argv);

  # ---------------------------------------------------------------------
  # mkPrisonService: one confined process.
  # ---------------------------------------------------------------------
  mkPrisonService =
    { name
    , exec                     # argv; exec[0] must be an absolute store path
    , uid ? 1000
    , gid ? uid
    , user ? name              # account name inside the container
    , packages ? [ ]           # extra closure roots visible in the store view
    , environment ? { }
    , state ? [ ]              # [ { path; size ? "64M"; } ] writable tmpfs mounts
    , persist ? [ ]            # [ { path; host; } ] writable host directories
    , capabilities ? [ ]       # capability names to ADD back; default none
    , readOnlyRoot ? true
    # PID 1 in a namespace only receives signals it has installed a handler
    # for -- pid_namespaces(7): "a process in an ancestor namespace can send
    # signals to the init process of a child PID namespace only if the init
    # process has established a handler for that signal". So `podman stop`
    # sends SIGTERM, the kernel drops it, and every stop degrades to the
    # SIGKILL that follows the timeout. PID 1 also inherits orphans and must
    # reap them.
    #
    # catatonit is podman's own answer to both: a few KB of C that forwards
    # signals to the real process and reaps whatever it is handed. It is
    # bind-mounted by podman from the host, so it does not enter the store
    # view and the closure does not grow. Turn this off only for a service
    # that is genuinely its own init.
    , init ? true
    , tmpfsSize ? "16M"
    , extraPodmanArgs ? [ ]
    }:
    assert lib.assertMsg (uid != 0) "prison: service ${name} must not run as uid 0; that is what the container root account exists to avoid.";
    let
      argv = assertAbsolute name exec;

      # The store view is exactly this service's closure. Not the prison's,
      # not the host's -- a service cannot reach a sibling's binaries.
      roots = [ (builtins.head argv) ] ++ packages;
      rootsDrv = pkgs.runCommand "prison-${name}-roots" { } ''
        printf '%s\n' ${lib.escapeShellArgs roots} > $out
      '';
      closure = pkgs.closureInfo { rootPaths = roots; };
      storeFarm = nixStoreLower {
        inherit pkgs closure;
        toplevel = rootsDrv;
      };

      rootfs = mkRootfs {
        inherit pkgs lib name;
        users = [ { inherit uid gid; name = user; } ];
        extraDirs = map (s: s.path) state ++ map (p: p.path) persist;
      };
    in
    {
      inherit name uid gid user argv environment state persist capabilities
        readOnlyRoot init tmpfsSize extraPodmanArgs rootfs storeFarm closure;
      __prisonService = true;
    };

  # ---------------------------------------------------------------------
  # mkPrison: the pod, its network policy, and the host driver.
  # ---------------------------------------------------------------------
  mkPrison =
    { name
    , services                 # attrset or list of mkPrisonService results
    , listen ? { tcp = [ ]; udp = [ ]; }
    , egress ? { mode = "none"; targets = [ ]; lan = [ ]; }
    , user ? name  # unprivileged host account podman runs as
    , stateDir ? "/var/lib/${name}"
    }:
    let
      svcList =
        if builtins.isList services then services
        else lib.mapAttrsToList (n: s: s // { name = s.name or n; }) services;

      _check = lib.throwIf (svcList == [ ]) "prison: ${name} has no services."
        (lib.throwIf (!(builtins.all (s: s.__prisonService or false) svcList))
          "prison: ${name} was given something that is not a mkPrisonService result."
          null);

      ruleset = mkRuleset { inherit pkgs lib listen egress; };

      # No declared port and no declared egress means the pod needs no
      # interface at all: --network=none leaves it with loopback only, which
      # is the documented default rather than a firewall that happens to drop
      # everything.
      wantsNetwork = (listen.tcp or [ ]) != [ ] || (listen.udp or [ ]) != [ ]
        || (egress.mode or "none") != "none";

      publishArgs = lib.concatMap
        (p: [ "--publish" "${toString (if builtins.isInt p then p else p.port)}:${toString (if builtins.isInt p then p else p.port)}/tcp" ])
        (listen.tcp or [ ])
        ++ lib.concatMap
        (p: [ "--publish" "${toString (if builtins.isInt p then p else p.port)}:${toString (if builtins.isInt p then p else p.port)}/udp" ])
        (listen.udp or [ ]);
    in
    builtins.seq _check {
      inherit name svcList ruleset wantsNetwork publishArgs user stateDir listen egress;
      fuse = fuse;
      __prison = true;
    };
in
{
  inherit mkPrison mkPrisonService;
  ruleset = mkRuleset;
  rootfs = mkRootfs;
}
