# Renders a launch plan for nix/app/runner.rs.
#
# The podman model (nix/podman.nix) owns what an invocation may say; this only
# serialises its argv, with the runtime values and splices still marked, plus
# the few things the runner decides at launch. The format is documented at
# `parse_plan` in runner.rs. Fields are TAB separated, so a field that contains
# a TAB or a newline is an error here, not a quoting problem there.
{ lib, isRt, isRtArray }:

let
  field =
    s:
    lib.throwIf (lib.hasInfix "\t" s || lib.hasInfix "\n" s)
      "app plan: a field contains a TAB or a newline: ${builtins.toJSON s}"
      s;

  tab = lib.concatStringsSep "\t";

  item =
    i:
    if isRtArray i then
      tab [ "a" (field i.__rt) ]
    else if isRt i then
      tab [
        "r"
        (field i.__rt)
        (field (i.prefix or ""))
        (field (i.suffix or ""))
      ]
    else
      tab [
        "s"
        (field i)
      ];

  rule =
    r:
    if r ? mount then
      tab [
        "mount"
        (field r.mount.pattern)
        (field r.mount.options)
      ]
    else if r ? mountAs then
      tab [
        "mount-as"
        (field r.mountAs.source)
        (field r.mountAs.destination)
        (field r.mountAs.options)
      ]
    else
      throw "app plan: a provider rule is neither `mount` nor `mountAs`";

  section = head: lines: [ "[${head}]" ] ++ lines;
in
{
  render =
    {
      name,
      podman,
      holder ? null,
      holderProcess ? null, # the name of the process that is the holder, to tell it from a pid reused since
      tty ? "never",
      vars ? [ ],
      require ? [ ],
      ensureDirs ? [ ],
      providers ? { },
      dbus ? null, # { proxy; upstream; socket; args; }
      podmanArgs ? [ ], # global options, before the subcommand of every podman call
      podmanEnv ? { }, # environment for every podman call
      holderArgv ? [ ],
      runArgv,
    }:
    lib.concatStringsSep "\n" (
      [ "plan 1" ]
      ++ section "meta" (
        [
          (tab [
            "name"
            (field name)
          ])
          (tab [
            "podman"
            (field podman)
          ])
          (tab [
            "tty"
            tty
          ])
        ]
        ++ lib.optional (holder != null) (tab [
          "holder"
          (field holder)
        ])
        ++ lib.optional (holder != null && holderProcess != null) (tab [
          "holder-process"
          (field holderProcess)
        ])
      )
      ++ section "vars" (
        map (
          v:
          tab [
            (field v.name)
            (field v.template)
          ]
        ) vars
      )
      ++ section "require" (
        map (
          r:
          tab [
            (field r.var)
            (field r.message)
          ]
        ) require
      )
      ++ section "ensure-dir" (
        map (
          d:
          tab [
            (field d.mode)
            (field d.template)
          ]
        ) ensureDirs
      )
      ++ lib.concatLists (
        lib.mapAttrsToList (n: rules: section "provider ${field n}" (map rule rules)) providers
      )
      ++ lib.optionals (dbus != null) (
        section "dbus" (
          [
            (tab [
              "proxy"
              (field dbus.proxy)
            ])
            (tab [
              "upstream"
              (field dbus.upstream)
            ])
            (tab [
              "socket"
              (field dbus.socket)
            ])
          ]
          ++ map (
            a:
            tab [
              "arg"
              (field a)
            ]
          ) dbus.args
        )
      )
      ++ lib.optionals (podmanArgs != [ ] || podmanEnv != { }) (
        section "podman" (
          map (
            a:
            tab [
              "arg"
              (field a)
            ]
          ) podmanArgs
          ++ lib.mapAttrsToList (
            n: v:
            tab [
              "env"
              (field n)
              (field v)
            ]
          ) podmanEnv
        )
      )
      ++ section "holder" (map item holderArgv)
      ++ section "run" (map item runArgv)
      ++ [ "" ]
    );
}
