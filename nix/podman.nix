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
  model = import ./podman-options.nix { inherit lib; };
  inherit (model)
    rt
    isRt
    rtWrap
    runOptions
    mountModel
    ;
  inherit (lib) optionals optionalString;

  renderMount = mountModel.render;

  renderNetwork =
    n:
    if n.mode == "container" then
      [
        "--network"
        "container:${n.container}"
      ]
    else
      [
        "--network"
        (
          if n.mode == "pasta" && n.pastaOptions != [ ] then
            "pasta:${lib.concatStringsSep "," n.pastaOptions}"
          else
            n.mode
        )
      ]
      ++ lib.concatMap (p: [
        "--publish"
        "${toString (if p.hostPort != null then p.hostPort else p.port)}:${toString p.port}/${p.protocol}"
      ]) n.publish;

  # Error messages need a printable name even when it is a runtime value.
  dispName = c: if isRt c.name then "$" + c.name.__rt else c.name;

  check =
    c:
    lib.throwIf (c.command == [ ]) "podman: ${dispName c} has an empty command." (
      lib.throwIf (!lib.hasPrefix "/" (builtins.head c.command))
        ''
          podman: ${dispName c} has command[0] = "${builtins.head c.command}", which is not an absolute path.

          There is no $PATH to resolve it against. Give a store path.
        ''
        (
          lib.throwIf (c.network.mode == "container" && c.network.container == null)
            "podman: ${dispName c} sets network.mode = \"container\" but no network.container."
            (
              lib.throwIf (c.network.mode != "pasta" && c.network.pastaOptions != [ ])
                "podman: ${dispName c} sets pastaOptions without network.mode = \"pasta\"."
                (
                  lib.throwIf (c.network.mode == "container" && c.network.publish != [ ]) ''
                    podman: ${dispName c} publishes ports while joining another container's network namespace.

                    A container that joins someone else's namespace cannot configure
                    it; podman rejects this at runtime. Publish on the container that
                    owns the namespace instead.
                  '' (mountModel.check (dispName c) c.mounts c)
                )
            )
        )
    );

  eval =
    spec:
    check
      (lib.evalModules {
        modules = [
          { options = runOptions; }
          spec
        ];
      }).config;

  # argv for `podman run`. --rootfs and the command come last, always, because
  # that is the only order podman parses correctly.
  renderRun =
    podmanBin: spec:
    let
      c = eval spec;
    in
    [
      podmanBin
      "run"
    ]
    ++ optionals c.remove [ "--rm" ]
    ++ optionals c.replace [ "--replace" ]
    ++ optionals c.detach [ "-d" ]
    ++ [
      "--name"
      c.name
    ]
    ++ optionals (c.runtime != null) [
      "--runtime"
      c.runtime
    ]
    ++ optionals (c.user != null) [
      "--user"
      "${toString c.user.uid}:${toString c.user.gid}"
    ]
    ++ optionals c.readOnly [ "--read-only" ]
    ++ map (x: "--cap-drop=${x}") c.capabilities.drop
    ++ map (x: "--cap-add=${x}") c.capabilities.add
    ++ optionals c.noNewPrivileges [
      "--security-opt"
      "no-new-privileges"
    ]
    ++ optionals (c.label != null) [
      "--security-opt"
      "label=${c.label}"
    ]
    ++ optionals (c.init != null) [
      "--init"
      "--init-path"
      c.init
    ]
    ++ renderNetwork c.network
    ++ lib.concatMap renderMount c.mounts
    ++ lib.concatLists (
      lib.mapAttrsToList (k: v: [
        "--env"
        "${k}=${v}"
      ]) c.env
    )
    ++ c.extraArgs
    ++ [ "--rootfs" ]
    ++ [
      (
        if isRt c.rootfs then
          rtWrap "" (optionalString c.overlay ":O") c.rootfs
        else
          "${c.rootfs}${optionalString c.overlay ":O"}"
      )
    ]
    ++ c.command;

in
let
  # Literal text that will sit inside double quotes alongside an expansion.
  escapeInDq = s: lib.replaceStrings [ "\\" "\"" "$" "`" ] [ "\\\\" "\\\"" "\\$" "\\`" ] s;

  # One argv item as a shell word. A literal is single-quoted so the shell
  # leaves it alone; a runtime value is double-quoted so the shell expands it,
  # with any literal text around it escaped for that context.
  renderItem =
    i:
    if isRt i then
      ''"'' + escapeInDq (i.prefix or "") + "$" + i.__rt + escapeInDq (i.suffix or "") + ''"''
    else
      lib.escapeShellArg i;
in
{
  inherit
    runOptions
    renderRun
    eval
    rt
    rtWrap
    ;
  renderRunShell = bin: spec: lib.concatMapStringsSep " " renderItem (renderRun bin spec);
}
