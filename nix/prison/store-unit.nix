# One capability-confined FUSE store-view unit per prison service.
{
  lib,
  pkgs,
  backend,
  fuseBin,
}:

p: s:
let
  unitName = "${p.name}-store-${s.name}";
  mountPoint = backend.storeMountPoint p s;
  openFileArgs = lib.optionals (s.openFiles != null) [
    "--max-open-files"
    (toString s.openFiles)
  ];
  prepare = pkgs.writeShellScript "${unitName}-prepare" ''
    set -eu
    mkdir -p ${lib.escapeShellArg mountPoint}
  '';
  waitUntilMounted = pkgs.writeShellScript "${unitName}-wait" ''
    set -eu
    for _ in $(${pkgs.coreutils}/bin/seq 1 50); do
      ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg mountPoint} && exit 0
      ${pkgs.coreutils}/bin/sleep 0.2
    done
    echo "${unitName}: store view did not mount at ${mountPoint}" >&2
    exit 1
  '';
in
lib.nameValuePair unitName {
  description = "${p.name}: passthrough store view for ${s.name}";
  before = [ "${p.name}.service" ];
  partOf = [ "${p.name}.service" ];

  serviceConfig = {
    Type = "exec";
    User = p.user;
    ExecStartPre = prepare;
    ExecStart = lib.escapeShellArgs (
      [ fuseBin ]
      ++ openFileArgs
      ++ [
        "--bind-target"
        "${s.storeFarm}/nix/store"
        "--resolution-root"
        "/nix/store"
        "--allow-other"
        mountPoint
      ]
    );
    ExecStartPost = waitUntilMounted;
    ExecStopPost = "-${pkgs.util-linux}/bin/umount ${lib.escapeShellArg mountPoint}";
    Restart = "on-failure";
    RestartSec = 2;

    # FUSE_DEV_IOC_BACKING_OPEN currently requires CAP_SYS_ADMIN. It belongs
    # only to this fixed daemon unit; Podman, the setup script and all service
    # containers run without it.
    AmbientCapabilities = [ "CAP_SYS_ADMIN" ];
    CapabilityBoundingSet = [ "CAP_SYS_ADMIN" ];
    NoNewPrivileges = true;
  };
}
