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
      mkContainer =
        { modules ? [ ]
        , shellUser ? "root"
        , name ? "nixct"
          # Format of the portable tarball this mkContainer call
          # produces under the `portable` attr. See nix/portable-tarball.nix
          # for the trade-offs. Acceptable values:
          #   "squashfs" - default; smallest tarball; needs squashfuse on host
          #   "folder"   - rootfs as plain files; no squashfuse needed
          #   "both"     - ship both; dispatch picks at up time
        , portableFormat ? "squashfs"
          # When true, `nix run .#<name>.up -- --gpu` uses the host's
          # nvidia-container-toolkit (CDI) integration:
          #   podman run --device nvidia.com/gpu=all ...
          # When false (the default), --gpu falls back to manual device
          # binds (/dev/nvidia* + /run/opengl-driver bind). Both end with
          # the same set of devices/libs in the container; CDI is just
          # cleaner / supported upstream.
        , hostHasNvidiaContainerToolkit ? false
          # When true, the container runs with --userns=keep-id:uid=<U>,
          # gid=<G> so that container's $shellUser (uid U, gid G) maps
          # 1:1 to the host's invoking user. This is what makes Wayland /
          # X11 work without making the host's sockets world-writable.
          # Cost: container uid 0 (root) now maps to host first-subuid
          # (e.g. 100000); the rootfs upper layer needs an ownership
          # migration which the run script does in-place at `up` time
          # (with $STATE_DIR/.keepid-migrated as the idempotency marker).
        , useKeepId ? false
          # In-container uid/gid the keep-id mapping pins to host's
          # invoking user. Must match the user/group the rootfs activation
          # creates (matches configuration.nix users.users.<shellUser>).
        , keepIdUid ? 1000
        , keepIdGid ? 100
        }:
        let
          # Tool resolution attrset - full /nix/store paths for the NixOS
          # build. See nix/scripts/tools.nix for the contract.
          tools = (import ./nix/scripts/tools.nix).mkNixosTools pkgs;

          nixosSystem = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [ ./nix/container-module.nix ] ++ modules;
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
                      hostHasNvidiaContainerToolkit useKeepId keepIdUid keepIdGid;
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

          # Portable tarball.
          portable = import ./nix/portable-tarball.nix {
            inherit pkgs name shellUser rootfsFolder rootfsSquashfs
                    hostHasNvidiaContainerToolkit useKeepId keepIdUid keepIdGid;
            version = if self ? rev then self.rev else "dirty";
            format = portableFormat;
          };
        in
        {
          inherit nixosSystem toplevel rootfs
                  rootfsFolder rootfsSquashfs portable
                  run packages;
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
        useKeepId = false;
      };

      nvidia = mkContainer {
        modules = [ ./configuration-nvidia.nix ];
        shellUser = "dev";
        name = "testnvidia";
        hostHasNvidiaContainerToolkit = false;
        useKeepId = false;
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
        hostHasNvidiaContainerToolkit = true;
        useKeepId = false;
        portableFormat = "folder";
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
