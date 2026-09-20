# Build one confined prison service and its exact store/rootfs inputs.
{
  pkgs,
  lib,
  nixStoreLower,
  mkRootfs,
  capsLib,
  configDir,
}:

let
  assertAbsolute =
    svc: argv:
    let
      a0 = builtins.head argv;
    in
    lib.throwIf (argv == [ ]) "prison: service ${svc} has an empty `exec`." (
      lib.throwIf (!lib.hasPrefix "/" a0) ''
        prison: service ${svc} has exec[0] = "${a0}", which is not an absolute path.

        A prison has no $PATH and no shell to resolve a name against. Give the
        store path: "''${pkgs.caddy}/bin/caddy".
      '' argv
    );

  # ---------------------------------------------------------------------
  # mkPrisonService: one confined process.
  # ---------------------------------------------------------------------
  mkPrisonService =
    {
      name,
      exec,
      uid ? 1000,
      gid ? uid,
      user ? name,
      packages ? [ ],
      environment ? { },
      state ? [ ],
      # Host paths bound into the container:
      #
      #   persist = [
      #     { host = "/var/lib/knot"; path = "/var/lib/knot"; }
      #     { host = "/var/lib/secrets/tsig.conf"; path = "/secrets/tsig.conf";
      #       readOnly = true; file = true; }
      #   ]
      #
      # `readOnly` is what a credential wants; `file` binds a single file rather
      # than the directory holding it, so a service is given one secret and not
      # everyone else's. `host` is a string, never a path literal -- nix copies
      # path literals into the store when they are interpolated, and the store is
      # world-readable.
      persist ? [ ],
      # A typed capability set: one named field per Linux capability, every one
      # defaulting to false. Not a list of strings -- a misspelled string
      # renders a flag that grants nothing while reading as though it granted
      # something, whereas an unknown field is an evaluation error.
      capabilities ? { },
      readOnlyRoot ? true,
      init ? true,
      tmpfsSize ? "16M",
      # Files placed in the container's /config, keyed by name relative to it.
      # Values are store paths or derivations. Their CONTENTS are copied to a
      # host directory that is bind-mounted in, rather than the store path being
      # mounted directly, because a store path changes identity whenever the
      # content does -- and then the mount, and so the container, would have to
      # be recreated to pick up a new config. A directory the host rewrites in
      # place is visible immediately, so a reload stays a reload.
      config ? { },
      # How to tell the service its configuration changed. `signal` is enough
      # for anything that reloads on SIGHUP; `exec` runs a command in the
      # container, which needs that binary in `packages`.
      reload ? null,
      # Maximum concurrent files opened through this service's passthrough store
      # view. The kernel's backing-file references bypass RLIMIT_NOFILE, so the
      # FUSE daemon enforces this ceiling itself. Null uses its safe default.
      openFiles ? null,
    }:
    assert lib.assertMsg (uid != 0)
      "prison: service ${name} must not run as uid 0; that is what the container root account exists to avoid.";
    let
      argv = assertAbsolute name exec;

      # Kernel names of the capabilities this service was granted.
      grantedCaps =
        capsLib.granted
          (lib.evalModules {
            modules = [
              { options = capsLib.options; }
              capabilities
            ];
          }).config;

      # Every persistent path is a host path bind-mounted in, so all of them
      # are checked the same way -- read-only or not, credential or not.
      checkedPersist = map (
        pm:
        let
          h = toString pm.host;
        in
        lib.throwIf (!lib.hasPrefix "/" h)
          ''
            prison: service ${name} persists host = "${h}", which is not an absolute path.

            It is bound from the host filesystem at run time, so a relative
            path has nothing to resolve against.
          ''
          (
            lib.throwIf (lib.hasPrefix builtins.storeDir h)
              ''
                prison: service ${name} persists a path in the Nix store: ${h}

                The store is read-only, so it is the wrong side of this mount for
                state, and world-readable, so it is unsafe for a credential. A
                path literal is the usual way in, since nix copies those into the
                store when they are interpolated. Quote it, and deploy the file by
                some means nix does not see.
              ''
              (
                lib.throwIf (
                  !lib.hasPrefix "/" pm.path
                ) "prison: service ${name} mounts a persistent path at \"${pm.path}\", which is not absolute." pm
              )
          )
      ) persist;

      # Podman can safely make a tmpfs root belong to the container process
      # user, but does not accept arbitrary uid=/gid= tmpfs mount options.
      # Refuse an ownership promise the backend cannot keep.
      checkedState = map (
        st:
        lib.throwIf (st ? uid || st ? gid) ''
          prison: service ${name} state ${st.path} sets uid or gid.

          Ephemeral state always belongs to the service identity (${toString uid}:${toString gid}).
          Podman cannot assign an arbitrary owner to a tmpfs mount.
        '' st
      ) state;

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
        inherit
          pkgs
          lib
          name
          configDir
          ;
        users = [
          {
            inherit uid gid;
            name = user;
          }
        ];
        extraDirs =
          map (s: s.path) checkedState ++ map (p: p.path) (lib.filter (p: !(p.file or false)) checkedPersist);
        # A single file is bound onto a file: crun can mount a file over an
        # existing one in a read-only rootfs, but cannot create the target.
        extraFiles = map (p: p.path) (lib.filter (p: p.file or false) checkedPersist);
      };

      # The configuration as a store tree. The host copies its contents out;
      # it is never mounted directly.
      configTree = pkgs.runCommand "prison-${name}-config" { } (
        ''
          mkdir -p $out
        ''
        + lib.concatStrings (
          lib.mapAttrsToList (rel: src: ''
            install -Dm0444 ${src} "$out/${rel}"
          '') config
        )
      );
    in
    {
      inherit
        name
        uid
        gid
        user
        argv
        environment
        readOnlyRoot
        init
        tmpfsSize
        openFiles
        rootfs
        storeFarm
        closure
        config
        configTree
        reload
        ;
      state = checkedState;
      persist = checkedPersist;
      capabilities = grantedCaps;
      hasConfig = config != { };
      __prisonService = true;
    };

in
mkPrisonService
