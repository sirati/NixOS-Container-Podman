# A validated Nix model of the podman invocations this framework makes.
#
# Nothing above this file writes a command line. Callers describe what they
# want as typed Nix; this renders argv. The point is not tidiness -- it is that
# the mistakes we actually made stop being expressible:
#
#   * `--rootfs` is a BOOLEAN flag whose path is the positional image
#     argument, so it must come last. Getting that wrong made podman parse the
#     next flag as the command ("executable file `--user` not found in
#     $PATH"). Here the renderer owns the ordering and the caller cannot
#     place it.
#   * publishing a port while joining another container's namespace is
#     rejected by podman at runtime, because the namespace is not this
#     container's to configure. Here it is a type error.
#   * a mount destination that is not absolute, a tmpfs size in the wrong
#     shape, a capability without its CAP_ prefix: all caught at eval.
#
# Only the options this framework uses are modelled. An option that is not
# here is not silently passed through -- `extraArgs` exists for that, and
# being ugly is the point.

# Pure: needs only `lib`, so it can be used from run.nix, which is
# deliberately pkgs-free in order to also drive the portable tarball.
{ lib }:

let
  inherit (lib) mkOption types concatMapStringsSep optionals optionalString;

  # A value only known when the script runs -- a computed overlay path, a
  # resolved uid, a detected GPU flag. run.nix assembles most of its argv from
  # these, so a model that only accepts literals cannot describe it.
  #
  # `rt "MERGED"` renders as "": double-quoted so the shell expands it,
  # where a literal is single-quoted so the shell does not. Validation that
  # cannot apply to an unknown value is skipped for these, which is the honest
  # thing -- pretending to check a runtime string would be worse than not
  # checking it.
  rt = name: { __rt = name; prefix = ""; suffix = ""; };
  isRt = v: builtins.isAttrs v && v ? __rt;
  # Wrap a runtime value in literal text, so it can sit inside a joined
  # option string like type=bind,source=$X,destination=/pause.
  rtWrap = pre: post: v: v // { prefix = pre; suffix = post; };
  rtType = types.addCheck types.attrs isRt // {
    description = "a runtime value, from rt \"VARNAME\"";
  };
  orRt = t: types.either t rtType;

  absPath = description:
    lib.types.addCheck types.str (s: lib.hasPrefix "/" s) // {
      inherit description;
    };

  # Sizes podman accepts for tmpfs: a number with an optional k/m/g suffix.
  sizeType = lib.types.addCheck types.str
    (s: builtins.match "[0-9]+[kKmMgG]?" s != null) // {
    description = "byte size, optionally suffixed k/m/g (e.g. \"64M\")";
  };

  # Octal mode as written in a mount option.
  modeType = lib.types.addCheck types.str
    (s: builtins.match "0?[0-7]{3,4}" s != null) // {
    description = "octal file mode (e.g. \"0700\")";
  };

  capName = lib.types.addCheck types.str
    (s: s == "ALL" || builtins.match "CAP_[A-Z_]+" s != null) // {
    description = "capability name, CAP_-prefixed, or \"ALL\"";
  };

  mountType = types.submodule ({ config, ... }: {
    options = {
      type = mkOption {
        type = types.enum [ "bind" "tmpfs" ];
        description = "Mount kind.";
      };
      source = mkOption {
        type = types.nullOr (orRt (absPath "absolute host path"));
        default = null;
        description = "Host path. Required for bind, meaningless for tmpfs.";
      };
      destination = mkOption {
        type = absPath "absolute path inside the container";
        description = "Where the mount appears in the container.";
      };
      readOnly = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Read-only. Defaults true: a writable mount is a decision worth
          writing down.
        '';
      };
      noexec = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Refuse execution from this mount. Defaults true -- a writable path
          that is also executable is where a payload lands.
        '';
      };
      nosuid = mkOption { type = types.bool; default = true; description = "Ignore set-user-ID bits."; };
      nodev = mkOption { type = types.bool; default = true; description = "Refuse device nodes."; };
      size = mkOption {
        type = types.nullOr sizeType;
        default = null;
        description = "tmpfs size. Only meaningful for tmpfs.";
      };
      mode = mkOption {
        type = types.nullOr modeType;
        default = null;
        description = "tmpfs mode. Only meaningful for tmpfs.";
      };
    };
  });

  networkType = types.submodule ({ config, ... }: {
    options = {
      mode = mkOption {
        type = types.enum [ "none" "pasta" "container" ];
        default = "none";
        description = ''
          `none` gives loopback only. `pasta` gives a real stack. `container`
          joins another container's namespace, which is how a prison service
          reaches the namespace its owner holds.
        '';
      };
      container = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Name of the container whose namespace to join. Required when mode is \"container\".";
      };
      publish = mkOption {
        type = types.listOf (types.submodule {
          options = {
            port = mkOption { type = types.ints.between 1 65535; description = "Port, on both sides."; };
            hostPort = mkOption {
              type = types.nullOr (types.ints.between 1 65535);
              default = null;
              description = "Host-side port, when it differs from the container's.";
            };
            protocol = mkOption { type = types.enum [ "tcp" "udp" ]; default = "tcp"; description = "Protocol."; };
          };
        });
        default = [ ];
        description = ''
          Ports to publish. Only valid when this container owns its namespace:
          a container joining someone else's cannot configure it, and podman
          rejects the combination at runtime.
        '';
      };
    };
  });

  runOptions = {
    name = mkOption {
      type = orRt types.str;
      description = "Container name. May be a runtime value.";
    };

    rootfs = mkOption {
      type = orRt (absPath "absolute path to an exploded rootfs");
      description = ''
        Rootfs directory. Rendered last, as the positional image argument,
        because `--rootfs` is a boolean flag -- the caller cannot influence
        where it lands.
      '';
    };

    overlay = mkOption {
      type = types.bool;
      default = true;
      description = "Append `:O`, giving the container a throwaway overlay over a read-only lower.";
    };

    command = mkOption {
      type = types.listOf types.str;
      description = ''
        argv. argv[0] must be absolute: a prison has no $PATH, and a bare name
        would resolve against whatever the store view happens to hold.
      '';
    };

    runtime = mkOption {
      type = types.nullOr (absPath "absolute path to an OCI runtime");
      default = null;
      description = "OCI runtime binary. Pinned to a store path so the host's containers.conf cannot choose for us.";
    };

    user = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          uid = mkOption { type = types.ints.unsigned; description = "User id inside the container."; };
          gid = mkOption { type = types.ints.unsigned; description = "Group id inside the container."; };
        };
      });
      default = null;
      description = "Run as this uid:gid. Null means the container's default, which is root.";
    };

    readOnly = mkOption { type = types.bool; default = true; description = "Read-only root filesystem."; };
    remove = mkOption { type = types.bool; default = true; description = "Remove the container when it exits (`--rm`)."; };
    detach = mkOption { type = types.bool; default = false; description = "Detach (`-d`)."; };

    capabilities = mkOption {
      type = types.submodule {
        options = {
          drop = mkOption { type = types.listOf capName; default = [ "ALL" ]; description = "Capabilities to drop."; };
          add = mkOption { type = types.listOf capName; default = [ ]; description = "Capabilities to add back."; };
        };
      };
      default = { };
      description = "Capability set. Drops everything by default.";
    };

    noNewPrivileges = mkOption { type = types.bool; default = true; description = "Set no-new-privileges."; };

    label = mkOption {
      type = types.nullOr types.str;
      default = "disable";
      description = "SELinux label option. Null omits it.";
    };

    init = mkOption {
      type = types.nullOr (absPath "absolute path to an init binary");
      default = null;
      description = ''
        Init process to run as PID 1. Needed because PID 1 in a namespace only
        receives signals it has a handler for (pid_namespaces(7)), so without
        one `podman stop` degrades to SIGKILL at the timeout.
      '';
    };

    network = mkOption { type = networkType; default = { }; description = "Network placement."; };
    mounts = mkOption { type = types.listOf mountType; default = [ ]; description = "Mounts."; };

    env = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Environment variables.";
    };

    extraArgs = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Raw arguments, for anything this model does not cover. Deliberately
        awkward: reaching for it means the model should probably grow instead.
      '';
    };
  };

  renderMount = m:
    let
      tail = [ "destination=${m.destination}" ]
        ++ optionals m.readOnly [ "ro" ]
        ++ optionals m.noexec [ "noexec" ]
        ++ optionals m.nosuid [ "nosuid" ]
        ++ optionals m.nodev [ "nodev" ]
        ++ optionals (m.size != null) [ "tmpfs-size=${m.size}" ]
        ++ optionals (m.mode != null) [ "tmpfs-mode=${m.mode}" ];
      tailStr = lib.concatStringsSep "," tail;
    in
    [ "--mount" ]
    ++ (
      if m.source == null then [ "type=${m.type},${tailStr}" ]
      # A runtime source has to sit inside the joined option string, so the
      # whole item becomes a runtime value with the literal text around it.
      else if isRt m.source
      then [ (rtWrap "type=${m.type},source=" ",${tailStr}" m.source) ]
      else [ "type=${m.type},source=${m.source},${tailStr}" ]
    );

  renderNetwork = n:
    if n.mode == "container" then [ "--network" "container:${n.container}" ]
    else [ "--network" n.mode ]
      ++ lib.concatMap
        (p: [ "--publish" "${toString (if p.hostPort != null then p.hostPort else p.port)}:${toString p.port}/${p.protocol}" ])
        n.publish;

  # Error messages need a printable name even when it is a runtime value.
  dispName = c: if isRt c.name then "$" + c.name.__rt else c.name;

  check = c:
    lib.throwIf (c.command == [ ]) "podman: ${dispName c} has an empty command."
      (lib.throwIf (!lib.hasPrefix "/" (builtins.head c.command)) ''
        podman: ${dispName c} has command[0] = "${builtins.head c.command}", which is not an absolute path.

        There is no $PATH to resolve it against. Give a store path.
      ''
        (lib.throwIf (c.network.mode == "container" && c.network.container == null)
          "podman: ${dispName c} sets network.mode = \"container\" but no network.container."
          (lib.throwIf (c.network.mode == "container" && c.network.publish != [ ]) ''
            podman: ${dispName c} publishes ports while joining another container's network namespace.

            A container that joins someone else's namespace cannot configure
            it; podman rejects this at runtime. Publish on the container that
            owns the namespace instead.
          ''
            (lib.throwIf (builtins.any (m: m.type == "bind" && m.source == null) c.mounts)
              "podman: ${dispName c} has a bind mount with no source."
              (lib.throwIf (builtins.any (m: m.type == "tmpfs" && m.source != null) c.mounts)
                "podman: ${dispName c} has a tmpfs mount with a source, which is meaningless."
                c)))));

  eval = spec: check (lib.evalModules {
    modules = [ { options = runOptions; } spec ];
  }).config;

  # argv for `podman run`. --rootfs and the command come last, always, because
  # that is the only order podman parses correctly.
  renderRun = podmanBin: spec:
    let c = eval spec; in
    [ podmanBin "run" ]
    ++ optionals c.remove [ "--rm" ]
    ++ optionals c.detach [ "-d" ]
    ++ [ "--name" c.name ]
    ++ optionals (c.runtime != null) [ "--runtime" c.runtime ]
    ++ optionals (c.user != null) [ "--user" "${toString c.user.uid}:${toString c.user.gid}" ]
    ++ optionals c.readOnly [ "--read-only" ]
    ++ map (x: "--cap-drop=${x}") c.capabilities.drop
    ++ map (x: "--cap-add=${x}") c.capabilities.add
    ++ optionals c.noNewPrivileges [ "--security-opt" "no-new-privileges" ]
    ++ optionals (c.label != null) [ "--security-opt" "label=${c.label}" ]
    ++ optionals (c.init != null) [ "--init" "--init-path" c.init ]
    ++ renderNetwork c.network
    ++ lib.concatMap renderMount c.mounts
    ++ lib.concatLists (lib.mapAttrsToList (k: v: [ "--env" "${k}=${v}" ]) c.env)
    ++ c.extraArgs
    ++ [ "--rootfs" ]
    ++ [ (
      if isRt c.rootfs
      then rtWrap "" (optionalString c.overlay ":O") c.rootfs
      else "${c.rootfs}${optionalString c.overlay ":O"}"
    ) ]
    ++ c.command;

in
let
  # Literal text that will sit inside double quotes alongside an expansion.
  escapeInDq = s: lib.replaceStrings [ "\\" "\"" "$" "`" ] [ "\\\\" "\\\"" "\\$" "\\`" ] s;

  # One argv item as a shell word. A literal is single-quoted so the shell
  # leaves it alone; a runtime value is double-quoted so the shell expands it,
  # with any literal text around it escaped for that context.
  renderItem = i:
    if isRt i
    then ''"'' + escapeInDq (i.prefix or "") + "$" + i.__rt
         + escapeInDq (i.suffix or "") + ''"''
    else lib.escapeShellArg i;
in
{
  inherit runOptions renderRun eval rt rtWrap;
  renderRunShell = bin: spec:
    lib.concatMapStringsSep " " renderItem (renderRun bin spec);
}
