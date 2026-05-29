{
  description = "NixOS multi-user systemd container, run via podman --rootfs + crun";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # mkContainer
      # ===========
      # Take a NixOS configuration and produce a rootfs derivation + run script.
      #
      #   modules    : list of NixOS modules; will be combined with the
      #                framework module (nix/container-module.nix).
      #   shellUser  : username (declared in `modules`) that the run script
      #                will `podman exec` into. Default "root".
      #   name       : default container name used by the run script. Default
      #                "nixct". Overridable at runtime via the NAME env.
      #
      # Returns { nixosSystem, toplevel, rootfs, run }:
      #   nixosSystem  - the full nixpkgs.lib.nixosSystem result
      #   toplevel     - config.system.build.toplevel
      #   rootfs       - directory derivation, layout below
      #   run          - writeShellApplication that drives podman
      #
      # rootfs layout (the derivation output):
      #
      #   /nix/store/HASH-nix-container-rootfs/
      #     ├── bin/  boot/  dev/  etc/{os-release,machine-id}
      #     ├── home/  mnt/  nix/{store/,var/}
      #     ├── opt/  proc/  root/  run/
      #     ├── sbin/init -> /init
      #     ├── srv/  sys/  tmp/  usr/  var/
      #     ├── init -> ${toplevel}/init            (NixOS stage-2-init.sh)
      #     └── nix-path-registration               (closure manifest)
      #
      # The closure itself is NOT copied. It is referenced via the toplevel
      # symlink (so Nix sees the closure as live for GC) and made available
      # inside the container at runtime by overlay-mounting the host's
      # /nix/store - see the run script.
      # mkContainer options are grouped into structured sub-attrsets so
      # each concern (portable packaging, gpu, keep-id, nix-store policy)
      # stays self-documenting and independently overridable. Every
      # sub-attrset and field is optional; defaults reproduce the old
      # flat-argument behavior.
      #
      #   portable.format         "squashfs" (default) | "folder" | "both"
      #                           Portable-tarball layout. squashfs is the
      #                           smallest but needs squashfuse on the host;
      #                           folder ships plain files; both ships each
      #                           and the run script picks at up time.
      #
      #   gpu.hostHasToolkit      false (default) | true
      #                           When true, `up --gpu` uses the host's
      #                           nvidia-container-toolkit (CDI):
      #                           `--device nvidia.com/gpu=all`. When false,
      #                           --gpu falls back to manual /dev/nvidia* +
      #                           /run/opengl-driver binds. Same result;
      #                           CDI is just cleaner / upstream-supported.
      #
      #   keepId.enable           false (default) | true
      #                           Run with --userns=keep-id:uid=<U>,gid=<G>
      #                           so $shellUser maps 1:1 to the invoking
      #                           host user (Wayland/X11 without world-
      #                           writable sockets). Cost: container root
      #                           maps to host first-subuid, so the rootfs
      #                           upper needs an in-place ownership
      #                           migration at up time.
      #   keepId.uid / keepId.gid In-container uid/gid the keep-id mapping
      #                           pins to the invoking user (default
      #                           1000/100; must match
      #                           configuration.nix users.users.<shellUser>).
      #
      #   nixStore.mode           "overlay" (default) | "passthrough" | "ro"
      #                             | "host-daemon"
      #                           How the container's /nix/store is provided:
      #                             overlay     host store RO + writable
      #                                         fuse-overlayfs upper.
      #                             passthrough host store, writable in place.
      #                             ro          host store, read-only.
      #                             host-daemon host store RO AND the host
      #                                         nix-daemon socket bound in;
      #                                         the container runs no daemon
      #                                         and has no nixbld users -
      #                                         every build/query is delegated
      #                                         to the host daemon. Requires
      #                                         the host's store prefix to be
      #                                         /nix/store and the container's
      #                                         closure to be realised there.
      #   nixStore.hostStore      Source path for the /nix/store mount
      #                           (default /nix/store). Override for a
      #                           relocated host store (e.g. nix-portable).
      #   nixStore.daemonSocket   Host nix-daemon socket bound in for
      #                           host-daemon mode (default
      #                           /nix/var/nix/daemon-socket/socket).
      mkContainer =
        { modules ? [ ]
        , shellUser ? "root"
        , name ? "nixct"
        , portable ? { }
        , gpu ? { }
        , keepId ? { }
        , nixStore ? { }
        }:
        let
          # Unpack the structured options into the flat names the rest of
          # mkContainer / run.nix already use.
          portableFormat              = portable.format or "squashfs";
          hostHasNvidiaContainerToolkit = gpu.hostHasToolkit or false;
          useKeepId                   = keepId.enable or false;
          keepIdUid                   = keepId.uid or 1000;
          keepIdGid                   = keepId.gid or 100;
          nixStoreMode                = nixStore.mode or "overlay";
          hostStore                   = nixStore.hostStore or "/nix/store";
          daemonSocket                = nixStore.daemonSocket or "/nix/var/nix/daemon-socket/socket";
          hostDaemon                  = nixStoreMode == "host-daemon";

          # Tool resolution attrset - full /nix/store paths for the NixOS
          # build. See nix/scripts/tools.nix for the contract.
          tools = (import ./nix/scripts/tools.nix).mkNixosTools pkgs;

          nixosSystem = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              ./nix/container-module.nix
              # Toggle the host-daemon NixOS profile (no in-container
              # daemon / nixbld users, store = daemon) to match the
              # selected nixStore.mode.
              { nixDevContainer.hostDaemon.enable = hostDaemon; }
            ] ++ modules;
          };

          toplevel = nixosSystem.config.system.build.toplevel;

          closure = pkgs.closureInfo { rootPaths = [ toplevel ]; };

          # The rootfs derivation is the IMMUTABLE lower layer. It contains:
          #   - NixOS-shaped FHS skeleton
          #   - /init -> ${toplevel}/init (stage-2-init.sh)
          #   - static /etc files (os-release, machine-id, mtab)
          #   - /nix/store/<HASH-path> as symlinks to the host store entries;
          #     these document the closure and serve as Nix GC references.
          #     They are *masked* at runtime by the fuse-overlayfs mount on
          #     /nix/store (hardlinks would be ideal but the sandbox builds
          #     on tmpfs which can't hardlink to the on-disk store).
          #   - /nix-path-registration (closure manifest, registered on
          #     first boot via boot.postBootCommands).
          #
          # All paths podman/NixOS-activation wants writable at runtime
          # (/etc/*, /run/*, /nix/var/*, ...) are placed in the OVERLAY UPPER
          # by the run script, not here.
          rootfs = pkgs.runCommand "nix-container-rootfs"
            {
              passthru = { inherit toplevel closure nixosSystem shellUser name; };
            } ''
            mkdir -p $out
            cd $out

            mkdir -p \
              bin boot dev etc home mnt \
              nix/store nix/var \
              opt proc root run sbin srv \
              sys tmp usr var

            ln -s ${toplevel}/init init
            ln -s /init sbin/init
            ln -s ${toplevel}/etc/os-release etc/os-release
            : > etc/machine-id
            ln -s /proc/mounts etc/mtab

            cp ${closure}/registration nix-path-registration

            # Symlink each closure path into our /nix/store. These are masked
            # by the fuse-overlayfs lower mount at runtime, but recorded here
            # they make the closure visible in the derivation output and act
            # as Nix references so the host store keeps the closure alive.
            while IFS= read -r p; do
              ln -s "$p" "$out$p"
            done < ${closure}/store-paths
          '';

          # Per-session host watchdog: script body extracted to
          # nix/scripts/host-watchdog.nix so the same text drives both
          # the NixOS-host and portable-tarball targets.
          hostWatchdogScript = pkgs.writeShellScript
            "nix-dev-container-session-watchdog"
            (import ./nix/scripts/host-watchdog.nix { inherit tools; });

          # Standalone host-compat probe. Built once per mkContainer
          # call so the dispatcher's `check-host-compat` subcommand
          # has a stable path to exec into.
          checkHostCompatScript = pkgs.writeShellApplication {
            name = "check-host-compat";
            runtimeInputs = [ ];
            bashOptions = [ "errexit" "pipefail" ];
            text = ''
              export PATH=''${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            '' + (import ./nix/scripts/check-host-compat.nix { });
          };

          run = pkgs.writeShellApplication {
            name = "nix-dev-container";
            runtimeInputs = with pkgs; [
              # Existing tools.
              podman crun coreutils util-linux fuse-overlayfs gnused xauth
              # Latent bugs fixed: findutils (find/xargs), gawk (awk), and
              # socat were used by the script body but not declared. Also
              # added: squashfsTools (mksquashfs/unsquashfs) and squashfuse,
              # needed when the same script is later instantiated for the
              # portable-tarball target. Harmless to ship in the NixOS
              # closure too.
              findutils gawk socat squashfsTools squashfuse
            ];
            bashOptions = [ "errexit" "pipefail" ];
            # Script body extracted to nix/scripts/run.nix. Same text body
            # drives both NixOS and portable tarball targets; the `tools`
            # attrset carries the path resolution policy.
            text = import ./nix/scripts/run.nix {
              inherit tools rootfs shellUser name
                      hostHasNvidiaContainerToolkit useKeepId keepIdUid keepIdGid
                      nixStoreMode hostStore daemonSocket;
              hostWatchdogPath = "${hostWatchdogScript}";
              checkHostCompatPath = "${checkHostCompatScript}/bin/check-host-compat";
            };
          };
          # Per-container subcommand packages. Each is a derivation named for
          # the subcommand with a single bin/<name> binary, so
          # `nix run .#<container>.<subcommand>` works through packages
          # (apps don't allow nesting under nix flake check).
          mkSubcommandPkg = subcommand: pkgs.writeShellApplication {
            name = subcommand;
            runtimeInputs = [ ];
            bashOptions = [ ];
            text = ''exec ${run}/bin/nix-dev-container ${subcommand} "$@"'';
          };

          # Plain attrset of derivations; wrap with lib.recurseIntoAttrs at
          # the use-site if you want nix flake check to walk into it.
          packages = {
            up       = mkSubcommandPkg "up";
            down     = mkSubcommandPkg "down";
            stop     = mkSubcommandPkg "stop";
            enter    = mkSubcommandPkg "enter";
            shell    = mkSubcommandPkg "shell";  # alias of enter
            develop  = mkSubcommandPkg "develop";
            exec     = mkSubcommandPkg "exec";
            boot     = mkSubcommandPkg "boot";
            logs     = mkSubcommandPkg "logs";
            status   = mkSubcommandPkg "status";
            purge    = mkSubcommandPkg "purge";
          };

          # Rootfs as a directory of real files (full closure copied).
          # Source of truth for the portable-tarball target. The
          # squashfs blob below is built ON TOP of this same staging
          # tree.
          rootfsFolder = import ./nix/rootfs-folder.nix {
            inherit pkgs toplevel closure name;
          };

          # Squashfs blob over rootfsFolder. Built on demand; reused
          # by the squashfs / both portable formats.
          rootfsSquashfs = import ./nix/rootfs-squashfs.nix {
            inherit pkgs rootfsFolder;
          };

          # Portable tarball. Named distinctly from the `portable` function
          # argument above: a `portable` let-binding would shadow the
          # argument, so `portable.format` (read above for portableFormat)
          # would point back here and recurse infinitely.
          portableTarball = import ./nix/portable-tarball.nix {
            inherit pkgs name shellUser rootfsFolder rootfsSquashfs
                    hostHasNvidiaContainerToolkit useKeepId keepIdUid keepIdGid
                    nixStoreMode hostStore daemonSocket;
            version = if self ? rev then self.rev else "dirty";
            format = portableFormat;
          };
        in
        {
          inherit nixosSystem toplevel rootfs
                  rootfsFolder rootfsSquashfs
                  run packages;
          portable = portableTarball;
        };

      example = mkContainer {
        modules = [ ./configuration.nix ];
        shellUser = "dev";
        name = "testcontainer";
        # keep-id is OFF for now: the nested user-ns it creates breaks
        # nix-daemon's makeStoreWritable() MS_REMOUNT (the fuse-overlayfs
        # superblock is owned by the rootless ns, daemon caps live in
        # the child). Host-uid translation for Wayland / develop binds
        # will be handled per-volume via podman idmap (option 2) once
        # implemented.
        keepId.enable = false;
      };

      # Same base config but using the host's nix-daemon: /nix/store is
      # mounted read-only and every build/query inside the container is
      # delegated to the host daemon over its bind-mounted socket. No
      # in-container daemon, no nixbld users. The container's closure must
      # already be realised in the host's /nix/store (it is, since this
      # builds against it). `nix run .#testdaemon.enter`, etc.
      hostDaemonExample = mkContainer {
        modules = [ ./configuration.nix ];
        shellUser = "dev";
        name = "testdaemon";
        keepId.enable = false;
        nixStore.mode = "host-daemon";
      };

      nvidia = mkContainer {
        modules = [ ./configuration-nvidia.nix ];
        shellUser = "dev";
        name = "testnvidia";
        gpu.hostHasToolkit = false;
        keepId.enable = false;
      };

      # Production-ish nvidia dev container: host-matching driver
      # userland + standard toolbox (btop/htop/tmux/git/direnv/
      # nix-direnv/devenv) + CUDA/AI cachix substituters. No CUDA /
      # PyTorch / python in the base closure - those go in per-project
      # devenv shells the user installs themselves.
      #
      # Portable target uses the folder format (no squashfuse needed
      # on the deploy host) and assumes nvidia-container-toolkit is
      # installed there so --gpu uses CDI (`--device nvidia.com/gpu=all`)
      # rather than manual /dev/nvidia* binds.
      nixctNvidia = mkContainer {
        modules = [ ./configuration-nixct-nvidia.nix ];
        shellUser = "dev";
        name = "nixct-nvidia";
        gpu.hostHasToolkit = true;
        keepId.enable = false;
        portable.format = "folder";
      };

    in
    {
      # Reusable framework. Downstream flake:
      #
      #   inputs.nix-dev-container.url = "github:...";
      #   outputs = { nixpkgs, nix-dev-container, ... }:
      #     let
      #       ct = nix-dev-container.lib.x86_64-linux.mkContainer {
      #         modules = [ ./my-system-config.nix ];
      #         shellUser = "alice";
      #         name = "myct";
      #       };
      #     in {
      #       packages.x86_64-linux.myct = ct.packages;
      #       # `nix run .#myct.enter`, `.#myct.boot`, `.#myct.purge`, ...
      #     };
      lib.${system} = { inherit mkContainer; };

      # Flat outputs (validated by nix flake check). These all resolve to a
      # derivation; running them invokes nix-dev-container with the matching
      # subcommand.
      packages.${system} = {
        inherit (example) toplevel rootfs run;
        inherit (example.packages)
          up down stop enter shell develop exec boot logs status purge;
        default = example.run;

        # Standalone host-readiness probe. Same script the portable
        # tarball ships under bin/check-host-compat, just without the
        # tarball around it. Use as:
        #
        #   nix run github:.../nix-dev-container#check-host-compat
        #
        # to verify a target host meets the prerequisites before
        # downloading or building the full portable tarball.
        check-host-compat = pkgs.writeShellApplication {
          name = "check-host-compat";
          runtimeInputs = [ ];  # script uses bare names by design
          bashOptions = [ "errexit" "pipefail" ];
          text = ''
            export PATH=''${PATH:+$PATH:}/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
          '' + (import ./nix/scripts/check-host-compat.nix { });
        };
      };

      # Nested namespace lives in legacyPackages because nix flake check
      # rejects nested attrsets in `packages`. `nix run` searches
      # apps -> packages -> legacyPackages, so `nix run .#testcontainer.enter`
      # still resolves cleanly.
      legacyPackages.${system} = {
        testcontainer = example.packages // {
          rootfsFolder   = example.rootfsFolder;
          rootfsSquashfs = example.rootfsSquashfs;
          portable       = example.portable;
        };
        testdaemon    = hostDaemonExample.packages // {
          rootfsFolder   = hostDaemonExample.rootfsFolder;
          rootfsSquashfs = hostDaemonExample.rootfsSquashfs;
          portable       = hostDaemonExample.portable;
        };
        testnvidia    = nvidia.packages // {
          rootfsFolder   = nvidia.rootfsFolder;
          rootfsSquashfs = nvidia.rootfsSquashfs;
          portable       = nvidia.portable;
        };
        nixct-nvidia  = nixctNvidia.packages // {
          rootfsFolder   = nixctNvidia.rootfsFolder;
          rootfsSquashfs = nixctNvidia.rootfsSquashfs;
          portable       = nixctNvidia.portable;
        };
      };

      apps.${system}.default = {
        type = "app";
        program = "${example.run}/bin/nix-dev-container";
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [ podman crun lxcfs ];
      };

      nixosConfigurations.example = example.nixosSystem;
    };
}
