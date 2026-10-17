# mkApp: run a desktop program in a rootless podman container and present it to
# the host as an ordinary Wayland application.
#
# The host sees what an installed program shows: `bin/<entry>` on PATH, and the
# package's `share/` (desktop entries, icons, MIME types) unchanged, so the
# menu, the file manager and `xdg-open` find it as they would any other. Run it
# and the window is a native Wayland client of the host compositor, with the
# GPU, clipboard, input methods and audio, because the container is given those
# sockets and device nodes and nothing else. The program cannot see the rest of
# the home directory, other processes, or the host's loopback.
#
# This layer says WHAT an app is allowed to reach ("plugs", as in snap); the
# podman model in nix/podman.nix says how that becomes a command line, and
# nix/app/runner.rs fills in what is only known at launch.
#
# Every entry of one app joins one network namespace, held by a small pause
# container, so the app and anything that talks to it over loopback (an MCP
# server, a CLI) share a private `127.0.0.1` the host cannot reach. The pause
# container lives while some entry runs: the runner keeps a lease on it and the
# last entry to end removes it (nix/app/runner.rs, acquire_lease).
#
#   mkApp {
#     name = "photocraft";
#     package = pkgs.photocraft;
#     users = [ { name = "alice"; uid = 1000; gid = 100; home = "/home/alice"; } ];
#     userDirs = [ "Documents" "Pictures" ];
#     gpu = { devices = [ "/dev/nvidia*" ]; };
#     entries = {
#       photocraft = { exec = "bin/photocraft"; display = true; };
#       photocraft-cli = { exec = "bin/photocraft-cli"; stdio = true; tty = "auto"; cwd = true; };
#     };
#   }
{
  pkgs,
  lib ? pkgs.lib,
}:

let
  podmanModel = import ../podman.nix { inherit lib; };
  inherit (podmanModel)
    rt
    rtArray
    rtWrap
    renderRun
    isRt
    isRtArray
    ;
  planLib = import ./plan.nix { inherit lib isRt isRtArray; };
  runner = import ./runner.nix { inherit pkgs; };
  mkRootfs = import ./rootfs.nix;

  crun = "${pkgs.crun}/bin/crun";
  catatonit = "${pkgs.catatonit}/bin/catatonit";

  # Bind options for a provider rule. Everything is `nosuid,nodev,noexec`
  # unless the thing bound needs otherwise: device nodes need `dev`, a
  # directory of loadable libraries needs `exec`.
  bindOptions =
    {
      ro ? false,
      dev ? false,
      exec ? false,
    }:
    lib.concatStringsSep "," (
      lib.optional ro "ro" ++ [ "nosuid" ] ++ lib.optional (!dev) "nodev" ++ lib.optional (!exec) "noexec"
    );

  # Apps that play sound through ALSA (most Rust audio code does) reach
  # PipeWire the way every NixOS program does: /etc/alsa/conf.d names the
  # PipeWire plugin. The host's copy is symlinks into /etc/static, which does
  # not exist in the sandbox, so the same three files are made here.
  alsaConfDir = pkgs.runCommand "app-alsa-conf.d" { } ''
    mkdir -p $out
    cat > $out/49-pipewire-modules.conf <<'EOF'
    pcm_type.pipewire {
      libs.native = ${pkgs.pipewire}/lib/alsa-lib/libasound_module_pcm_pipewire.so ;
    }
    ctl_type.pipewire {
      libs.native = ${pkgs.pipewire}/lib/alsa-lib/libasound_module_ctl_pipewire.so ;
    }
    EOF
    cp ${pkgs.pipewire}/share/alsa/alsa.conf.d/50-pipewire.conf $out/
    cp ${pkgs.pipewire}/share/alsa/alsa.conf.d/99-pipewire-default.conf $out/
  '';

  defaultPassEnv = [
    "LANG"
    "LANGUAGE"
    "LC_ALL"
    "LC_CTYPE"
    "LOCALE_ARCHIVE"
    "TZ"
    "XDG_CURRENT_DESKTOP"
    "XCURSOR_THEME"
    "XCURSOR_SIZE"
    # Which GPU a wgpu program draws on, for machines that have two.
    "WGPU_BACKEND"
    "WGPU_ADAPTER_NAME"
    "WGPU_POWER_PREF"
  ];

  # What an app keeps, and where it expects to find it. These four are all the
  # persistence it gets (flatpak's ~/.var/app/<id> layout).
  stateDirs = [
    {
      keep = "config";
      at = ".config";
    }
    {
      keep = "data";
      at = ".local/share";
    }
    {
      keep = "cache";
      at = ".cache";
    }
    {
      keep = "state";
      at = ".local/state";
    }
  ];

  entryDefaults = {
    args = [ ];
    env = { };
    display = false; # wayland, gpu, audio, fonts: only a window needs them
    stdio = false; # keep stdin open: the entry speaks over stdout
    tty = "never"; # "auto" allocates one when both ends are terminals
    joinNetwork = true; # false: a namespace of its own, with nothing in it
    cwd = false; # start in the caller's directory, if it is visible
    paths = [ ];
    ensureDirs = [ ];
  };

  mkApp =
    {
      name,
      package,
      users, # [ { name; uid; gid; group ? "users"; home; } ]
      prefix ? "app",
      podman ? pkgs.podman,
      network ? "pasta", # of the shared namespace: "pasta" or "none"
      state ? true, # keep the app's XDG dirs under ~/.var/app/<name>
      homeVisible ? false, # every non-hidden entry of the home directory, as in snap's `home`
      userDirs ? [ ], # names under the home directory, read-write
      paths ? [ ], # [ { path; mode ? "rw"; } ] absolute, same path inside
      gpu ? null, # { dri ? [ "/dev/dri" ]; devices ? [ glob ]; driverDir ? "/run/opengl-driver"; }
      fonts ? null, # host directory served as /usr/share/fonts
      icons ? null, # host directory served as /usr/share/icons (cursor themes)
      audio ? false,
      dbus ? true, # a filtered session bus: portals, notifications, tray
      appId ? "app.${prefix}.${name}", # the D-Bus name the app may own
      env ? { },
      passEnv ? defaultPassEnv,
      entries,
    }:
    assert lib.assertMsg (builtins.elem network [
      "pasta"
      "none"
    ]) "mkApp ${name}: network must be \"pasta\" or \"none\"";
    assert lib.assertMsg (users != [ ]) "mkApp ${name}: no users, so nobody could run it";
    let
      holderName = "${prefix}-${name}-net";
      podmanBin = "${podman}/bin/podman";

      planFor =
        user: entryName: entry0:
        let
          uid = toString user.uid;
          runtimeDir = "/run/user/${uid}";
          # The same entry text serves every user: `{home}`, `{user}`, `{uid}`
          # and `{runtime_dir}` in args, env values and paths are this user's.
          # (Other `{...}` stay for the runner, which knows them at launch.)
          forUser =
            lib.replaceStrings
              [ "{home}" "{user}" "{uid}" "{runtime_dir}" ]
              [ user.home user.name uid runtimeDir ];
          entry1 = entryDefaults // entry0;
          e = entry1 // {
            args = map forUser entry1.args;
            env = lib.mapAttrs (_: forUser) entry1.env;
            paths = map (p: p // { path = forUser p.path; }) entry1.paths;
            ensureDirs = map (d: d // { template = forUser d.template; }) entry1.ensureDirs;
          };
          stateDir = "${user.home}/.var/app/${name}";
          rootfs = mkRootfs {
            inherit pkgs lib user;
          };

          store = {
            type = "bind";
            source = "/nix/store";
            destination = "/nix/store";
            readOnly = true;
            # The one mount execution must be allowed from, and it is read-only.
            noexec = false;
          };

          pathRule = p: {
            mount = {
              pattern = p.path;
              options = bindOptions { ro = (p.mode or "rw") == "ro"; };
            };
          };

          providers =
            lib.optionalAttrs e.display (
              {
                wayland = [
                  {
                    mountAs = {
                      source = "{wayland_socket}";
                      destination = "${runtimeDir}/wayland-0";
                      options = bindOptions { ro = true; };
                    };
                  }
                ];
                localtime = [
                  {
                    mountAs = {
                      source = "/etc/localtime";
                      destination = "/etc/localtime";
                      options = bindOptions { ro = true; };
                    };
                  }
                ];
              }
              // lib.optionalAttrs (gpu != null) {
                gpu =
                  map
                    (d: {
                      mount = {
                        pattern = d;
                        options = bindOptions { dev = true; };
                      };
                    })
                    ((gpu.dri or [ "/dev/dri" ]) ++ (gpu.devices or [ ]))
                  ++ [
                    {
                      mount = {
                        pattern = gpu.driverDir or "/run/opengl-driver";
                        options = bindOptions {
                          ro = true;
                          exec = true;
                        };
                      };
                    }
                  ];
              }
              // lib.optionalAttrs audio {
                audio = map
                  (s: {
                    mountAs = {
                      source = "{xdg_runtime_dir}/${s}";
                      destination = "${runtimeDir}/${s}";
                      options = bindOptions { };
                    };
                  })
                  [
                    "pipewire-0"
                    "pulse/native"
                  ];
              }
              // lib.optionalAttrs (fonts != null) {
                fonts = [
                  {
                    mountAs = {
                      source = fonts;
                      destination = "/usr/share/fonts";
                      options = bindOptions { ro = true; };
                    };
                  }
                ];
              }
              // lib.optionalAttrs (icons != null) {
                icons = [
                  {
                    mountAs = {
                      source = icons;
                      destination = "/usr/share/icons";
                      options = bindOptions { ro = true; };
                    };
                  }
                ];
              }
              // lib.optionalAttrs dbus {
                dbus = [
                  {
                    mountAs = {
                      source = "{dbus_socket}";
                      destination = "${runtimeDir}/bus";
                      options = bindOptions { ro = true; };
                    };
                  }
                ];
              }
            )
            // {
              paths = map pathRule (
                lib.optional homeVisible { path = "${user.home}/*"; }
                ++ map (d: { path = "${user.home}/${d}"; }) userDirs
                ++ map (p: p // { path = forUser p.path; }) paths
                ++ e.paths
              );
            };

          mounts = [
            store
            {
              type = "tmpfs";
              destination = "/tmp";
              readOnly = false;
              mode = "1777";
              size = "2g";
            }
            {
              type = "tmpfs";
              destination = runtimeDir;
              readOnly = false;
              mode = "0700";
              chown = true;
              size = "64m";
            }
          ]
          ++ lib.optional (e.display && audio) {
            type = "bind";
            source = "${alsaConfDir}";
            destination = "/etc/alsa/conf.d";
            readOnly = true;
          }
          ++ [
            # The home directory is a scratch one. What the app keeps lives in the
            # four XDG directories below, which belong to the app alone; the
            # host's own ~/.config, ~/.ssh and the rest are not here at all.
            {
              type = "tmpfs";
              destination = user.home;
              readOnly = false;
              mode = "0700";
              chown = true;
              size = "256m";
            }
          ]
          ++ lib.optionals state (
            map (d: {
              type = "bind";
              source = "${stateDir}/${d.keep}";
              destination = "${user.home}/${d.at}";
              readOnly = false;
            }) stateDirs
          );

          baseEnv = {
            HOME = user.home;
            USER = user.name;
            LOGNAME = user.name;
            XDG_RUNTIME_DIR = runtimeDir;
            SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
            PATH = "${package}/bin";
          }
          // lib.optionalAttrs e.display {
            WAYLAND_DISPLAY = "wayland-0";
            XDG_SESSION_TYPE = "wayland";
          }
          // lib.optionalAttrs (e.display && audio) {
            PULSE_SERVER = "unix:${runtimeDir}/pulse/native";
          }
          // lib.optionalAttrs (e.display && dbus) {
            DBUS_SESSION_BUS_ADDRESS = "unix:path=${runtimeDir}/bus";
          }
          // lib.optionalAttrs (e.display && icons != null) {
            XCURSOR_PATH = "/usr/share/icons";
          };

          spec = {
            name = rtWrap "${prefix}-${name}-${entryName}-" "" (rt "pid");
            rootfs = "${rootfs}";
            inherit mounts;
            command = [ "${package}/${e.exec}" ] ++ e.args;
            runtime = crun;
            user = { inherit (user) uid gid; };
            userns.mode = "keep-id";
            interactive = e.stdio;
            init = catatonit;
            network =
              if e.joinNetwork then
                {
                  mode = "container";
                  container = holderName;
                }
              else
                { mode = "none"; };
            env = baseEnv // env // e.env;
            inherit passEnv;
            splice = map rtArray (builtins.attrNames providers);
            workdir = if e.cwd then rt "cwd" else null;
          };

          holderSpec = {
            name = holderName;
            rootfs = "${rootfs}";
            command = [
              catatonit
              "-P"
            ];
            runtime = crun;
            user = { inherit (user) uid gid; };
            userns.mode = "keep-id";
            remove = false;
            detach = true;
            network.mode = network;
            mounts = [ store ];
          };
        in
        planLib.render {
          name = "${name}/${entryName}";
          podman = podmanBin;
          holder = if e.joinNetwork then holderName else null;
          inherit (e) tty;
          require = lib.optional e.display {
            var = "wayland_socket";
            message = "${entryName}: no Wayland compositor socket found; start it from a graphical session (check WAYLAND_DISPLAY and XDG_RUNTIME_DIR)";
          };
          ensureDirs =
            lib.optionals state (
              map (d: {
                mode = "700";
                template = "${stateDir}/${d.keep}";
              }) stateDirs
            )
            ++ e.ensureDirs;
          inherit providers;
          dbus = if !(e.display && dbus) then null else {
            proxy = "${pkgs.xdg-dbus-proxy}/bin/xdg-dbus-proxy";
            upstream = "{xdg_runtime_dir}/bus";
            # One socket per launch, in a directory only the user can enter.
            socket = "{xdg_runtime_dir}/${prefix}-dbus/${name}-{pid}";
            # What flatpak lets an app do by default: use the portals, send
            # notifications, show up in the tray and the file manager, own its
            # own name. Everything else on the bus does not exist for it.
            args = [
              "--filter"
              "--own=${appId}"
              "--own=${appId}.*"
              "--talk=org.freedesktop.portal.*"
              "--talk=org.freedesktop.Notifications"
              "--talk=org.freedesktop.FileManager1"
              "--talk=org.kde.StatusNotifierWatcher"
              "--call=org.freedesktop.portal.*=*"
              "--broadcast=org.freedesktop.portal.*=@/org/freedesktop/portal/*"
            ];
          };
          holderArgv = renderRun podmanBin holderSpec;
          runArgv = renderRun podmanBin spec;
        };

      planDirFor =
        entryName: entry:
        pkgs.linkFarm "${prefix}-${name}-${entryName}-plans" (
          map (user: {
            name = "${toString user.uid}.plan";
            path = pkgs.writeText "${prefix}-${name}-${entryName}-${toString user.uid}.plan" (
              planFor user entryName entry
            );
          }) users
        );

      planDirs = lib.mapAttrs planDirFor entries;
    in
    pkgs.runCommand "${name}-sandboxed-${package.version or "0"}"
      {
        pname = "${name}-sandboxed";
        version = package.version or "0";
        nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
        meta = (package.meta or { }) // {
          mainProgram = name;
          platforms = lib.platforms.linux;
        };
        passthru = {
          inherit package planDirs holderName;
        };
      }
      ''
        mkdir -p $out/bin
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            n: dir: "makeBinaryWrapper ${runner}/bin/app-runner $out/bin/${n} --add-flags ${dir}"
          ) planDirs
        )}
        # The package's own desktop entries, icons and MIME types, as symlinks to
        # the files: their `Exec=` names a program this package now provides.
        if [ -d ${package}/share ]; then
          cp -rs --no-preserve=mode ${package}/share $out/share
        fi
      '';
in
{
  inherit mkApp;
  appRunner = runner;
}
