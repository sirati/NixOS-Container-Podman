# The host side of sandboxed apps (nix/app/default.nix).
#
# `mkApp` is pure and needs three things only a NixOS configuration knows: who
# the users are (a plan is rendered per user, because paths inside the sandbox
# are the host's own), which GPU device nodes this machine has, and where the
# system fonts live. This module reads them from the configuration, the way
# eduvpn_container.nix derives its NVIDIA nodes, rather than probing the live
# machine, so evaluation stays pure.
#
#   imports = [ nixos-container-podman.nixosModules.app-sandbox ];
#   appSandbox.enable = true;
#   environment.systemPackages = [
#     (config.appSandbox.mkApp { name = "foo"; package = pkgs.foo; entries = ...; })
#   ];
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.appSandbox;
  inherit (lib) mkOption mkEnableOption types;

  hasNvidia = lib.elem "nvidia" (config.services.xserver.videoDrivers or [ ]);

  userRecord =
    name:
    let
      u = config.users.users.${name};
      group = u.group;
      gid = config.users.groups.${group}.gid or null;
    in
    {
      inherit name group gid;
      inherit (u) uid home;
    };

  records = map userRecord cfg.users;
in
{
  options.appSandbox = {
    enable = mkEnableOption "host support for desktop apps run in rootless podman containers";

    users = mkOption {
      type = types.listOf types.str;
      default = lib.attrNames (lib.filterAttrs (_: u: u.isNormalUser) config.users.users);
      defaultText = lib.literalExpression "every normal user";
      description = ''
        Users who can run the sandboxed apps. Each needs a fixed uid, because
        the sandbox plan is rendered ahead of time for it, and a rootless
        podman setup (subuid and subgid ranges, which normal users get by
        default).
      '';
    };

    gpu = {
      dri = mkOption {
        type = types.listOf types.str;
        default = [ "/dev/dri" ];
        description = ''
          Which DRM nodes the apps get. The whole directory by default, so they
          can use any GPU the machine has. Name `/dev/dri/card1` and
          `/dev/dri/renderD129` to confine them to one, for example the
          integrated GPU on a machine whose discrete GPU is busy with other work.
        '';
      };
      devices = mkOption {
        type = types.listOf types.str;
        default = lib.optional hasNvidia "/dev/nvidia*";
        defaultText = lib.literalExpression ''lib.optional hasNvidia "/dev/nvidia*"'';
        description = ''
          Device-node patterns granted next to `/dev/dri`, bound only if they
          exist at launch. The NVIDIA nodes are listed when the NVIDIA driver
          is configured; Mesa drivers need nothing beyond `/dev/dri`.
        '';
      };
      driverDir = mkOption {
        type = types.str;
        default = "/run/opengl-driver";
        description = "The host's graphics driver directory, bound read-only.";
      };
    };

    fontsDir = mkOption {
      type = types.str;
      default = "/run/current-system/sw/share/X11/fonts";
      description = ''
        The system fonts, served to apps as `/usr/share/fonts`. Their text
        tools read only that path. It exists because this module turns on
        `fonts.fontDir`.
      '';
    };

    iconsDir = mkOption {
      type = types.nullOr types.str;
      default = "/run/current-system/sw/share/icons";
      description = ''
        The system icon and cursor themes, served to apps as
        `/usr/share/icons` so the pointer looks like the rest of the desktop.
        Null serves none.
      '';
    };

    userRecords = mkOption {
      type = types.listOf types.attrs;
      readOnly = true;
      internal = true;
      default = records;
      description = "The users above as `mkApp` wants them.";
    };

    mkApp = mkOption {
      type = types.raw;
      readOnly = true;
      internal = true;
      description = ''
        `mkApp` bound to this configuration: its package set, its podman, its
        users, GPU and fonts. Entries are given as in nix/app/default.nix.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    appSandbox.mkApp =
      args:
      (import ./default.nix { inherit pkgs; }).mkApp (
        {
          podman = config.virtualisation.podman.package or pkgs.podman;
          users = records;
          gpu = {
            inherit (cfg.gpu) dri devices driverDir;
          };
          fonts = cfg.fontsDir;
          icons = cfg.iconsDir;
        }
        // args
      );

    virtualisation.podman.enable = lib.mkDefault true;
    fonts.fontDir.enable = true;

    assertions = lib.concatMap (r: [
      {
        assertion = r.uid != null;
        message = "appSandbox: user `${r.name}` has no fixed uid. Set users.users.${r.name}.uid; the sandbox plan is built ahead of time for it.";
      }
      {
        assertion = r.gid != null;
        message = "appSandbox: group `${r.group}` of user `${r.name}` has no fixed gid. Set users.groups.${r.group}.gid.";
      }
    ]) records;
  };
}
