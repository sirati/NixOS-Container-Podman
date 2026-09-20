# Typed model for the subset of `podman run` used by this repository.
{ lib }:

let
  inherit (lib)
    mkOption
    types
    concatMapStringsSep
    optionals
    optionalString
    ;

  # A value only known when the script runs -- a computed overlay path, a
  # resolved uid, a detected GPU flag. run.nix assembles most of its argv from
  # these, so a model that only accepts literals cannot describe it.
  #
  # `rt "MERGED"` renders as "": double-quoted so the shell expands it,
  # where a literal is single-quoted so the shell does not. Validation that
  # cannot apply to an unknown value is skipped for these, which is the honest
  # thing -- pretending to check a runtime string would be worse than not
  # checking it.
  rt = name: {
    __rt = name;
    prefix = "";
    suffix = "";
  };
  isRt = v: builtins.isAttrs v && v ? __rt;
  # Wrap a runtime value in literal text, so it can sit inside a joined
  # option string like type=bind,source=$X,destination=/pause.
  rtWrap =
    pre: post: v:
    v
    // {
      prefix = pre;
      suffix = post;
    };
  rtType = types.addCheck types.attrs isRt // {
    description = "a runtime value, from rt \"VARNAME\"";
  };
  orRt = t: types.either t rtType;

  absPath =
    description:
    lib.types.addCheck types.str (s: lib.hasPrefix "/" s)
    // {
      inherit description;
    };

  capName =
    lib.types.addCheck types.str (s: s == "ALL" || builtins.match "CAP_[A-Z_]+" s != null)
    // {
      description = "capability name, CAP_-prefixed, or \"ALL\"";
    };

  mountModel = import ./podman-mounts.nix {
    inherit
      lib
      orRt
      absPath
      isRt
      rtWrap
      ;
  };
  mountType = mountModel.type;

  networkType = types.submodule (
    { config, ... }: {
      options = {
        mode = mkOption {
          type = types.enum [
            "none"
            "pasta"
            "container"
          ];
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
          type = types.listOf (
            types.submodule {
              options = {
                port = mkOption {
                  type = types.ints.between 1 65535;
                  description = "Port, on both sides.";
                };
                hostPort = mkOption {
                  type = types.nullOr (types.ints.between 1 65535);
                  default = null;
                  description = "Host-side port, when it differs from the container's.";
                };
                protocol = mkOption {
                  type = types.enum [
                    "tcp"
                    "udp"
                  ];
                  default = "tcp";
                  description = "Protocol.";
                };
              };
            }
          );
          default = [ ];
          description = ''
            Ports to publish. Only valid when this container owns its namespace:
            a container joining someone else's cannot configure it, and podman
            rejects the combination at runtime.
          '';
        };
        pastaOptions = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Arguments appended to Podman's pasta network mode.";
        };
      };
    }
  );

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
      type = types.nullOr (
        types.submodule {
          options = {
            uid = mkOption {
              type = types.ints.unsigned;
              description = "User id inside the container.";
            };
            gid = mkOption {
              type = types.ints.unsigned;
              description = "Group id inside the container.";
            };
          };
        }
      );
      default = null;
      description = "Run as this uid:gid. Null means the container's default, which is root.";
    };

    readOnly = mkOption {
      type = types.bool;
      default = true;
      description = "Read-only root filesystem.";
    };
    remove = mkOption {
      type = types.bool;
      default = true;
      description = "Remove the container when it exits (`--rm`).";
    };
    replace = mkOption {
      type = types.bool;
      default = false;
      description = "Replace a stale container with the same name (`--replace`).";
    };
    detach = mkOption {
      type = types.bool;
      default = false;
      description = "Detach (`-d`).";
    };

    capabilities = mkOption {
      type = types.submodule {
        options = {
          drop = mkOption {
            type = types.listOf capName;
            default = [ "ALL" ];
            description = "Capabilities to drop.";
          };
          add = mkOption {
            type = types.listOf capName;
            default = [ ];
            description = "Capabilities to add back.";
          };
        };
      };
      default = { };
      description = "Capability set. Drops everything by default.";
    };

    noNewPrivileges = mkOption {
      type = types.bool;
      default = true;
      description = "Set no-new-privileges.";
    };

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

    network = mkOption {
      type = networkType;
      default = { };
      description = "Network placement.";
    };
    mounts = mkOption {
      type = types.listOf mountType;
      default = [ ];
      description = "Mounts.";
    };

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

in
{
  inherit
    rt
    isRt
    rtWrap
    runOptions
    mountModel
    ;
}
