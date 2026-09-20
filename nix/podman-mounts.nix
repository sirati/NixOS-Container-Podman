# Typed Podman bind/tmpfs mount model and argv rendering.
{
  lib,
  orRt,
  absPath,
  isRt,
  rtWrap,
}:

let
  inherit (lib) mkOption types optionals;

  sizeType = types.addCheck types.str (s: builtins.match "[0-9]+[kKmMgG]?" s != null) // {
    description = "byte size, optionally suffixed k/m/g (e.g. \"64M\")";
  };

  modeType = types.addCheck types.str (s: builtins.match "0?[0-7]{3,4}" s != null) // {
    description = "octal file mode (e.g. \"0700\")";
  };

  type = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [
          "bind"
          "tmpfs"
        ];
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
        description = "Read-only. Defaults true so writable mounts are explicit.";
      };
      noexec = mkOption {
        type = types.bool;
        default = true;
        description = "Refuse execution from the mount.";
      };
      nosuid = mkOption {
        type = types.bool;
        default = true;
        description = "Ignore set-user-ID bits.";
      };
      nodev = mkOption {
        type = types.bool;
        default = true;
        description = "Refuse device nodes.";
      };
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
      chown = mkOption {
        type = types.bool;
        default = false;
        description = "Make the tmpfs root belong to the container process user.";
      };
    };
  };

  render =
    m:
    let
      bindTail = [
        "destination=${m.destination}"
      ]
      ++ optionals m.readOnly [ "ro" ]
      ++ optionals m.noexec [ "noexec" ]
      ++ optionals m.nosuid [ "nosuid" ]
      ++ optionals m.nodev [ "nodev" ];
      tmpfsOptions = [
        "type=tmpfs"
        "destination=${m.destination}"
      ]
      ++ optionals m.chown [ "chown=true" ]
      ++ optionals m.readOnly [ "ro" ]
      ++ optionals (!m.readOnly) [ "rw" ]
      ++ optionals m.noexec [ "noexec" ]
      ++ optionals m.nosuid [ "nosuid" ]
      ++ optionals m.nodev [ "nodev" ]
      ++ optionals (m.size != null) [ "tmpfs-size=${m.size}" ]
      ++ optionals (m.mode != null) [ "tmpfs-mode=${m.mode}" ];
      bindTailStr = lib.concatStringsSep "," bindTail;
    in
    if m.type == "tmpfs" then
      [
        "--mount"
        (lib.concatStringsSep "," tmpfsOptions)
      ]
    else
      [ "--mount" ]
      ++ (
        if m.source == null then
          [ "type=${m.type},${bindTailStr}" ]
        else if isRt m.source then
          [ (rtWrap "type=${m.type},source=" ",${bindTailStr}" m.source) ]
        else
          [ "type=${m.type},source=${m.source},${bindTailStr}" ]
      );

  check =
    containerName: mounts: value:
    lib.throwIf (builtins.any (m: m.type == "bind" && m.source == null) mounts)
      "podman: ${containerName} has a bind mount with no source."
      (
        lib.throwIf (builtins.any (m: m.type == "tmpfs" && m.source != null) mounts)
          "podman: ${containerName} has a tmpfs mount with a source, which is meaningless."
          (
            lib.throwIf (builtins.any (
              m: m.type == "bind" && (m.size != null || m.mode != null || m.chown)
            ) mounts) "podman: ${containerName} gives tmpfs-only options to a bind mount." value
          )
      );
in
{
  inherit type render check;
}
