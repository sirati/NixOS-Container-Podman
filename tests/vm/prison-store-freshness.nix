# A store view left serving the old closure by a switch heals itself.
#
# The 2026-10-14 outage: during a switch, after it compared the old and new
# units and found a prison stopped, something started the prison from the
# OLD unit files. Its store views came up serving the old store farm. The
# switch then installed the new units, reloaded, found the views active and
# left them alone, and the prison's services ran their new argv against the
# old /nix/store.
#
# This replays that window with the production activation: the views are
# started from the booted generation's units, then the new generation's
# activation installs its units and systemd reloads them, and then the
# service is started as the switch would. The service unit's ExecCondition
# must notice the stale view, queue its restart, and the service must end up
# running against the new closure without ever being marked failed.
#
# Driven by tests/cases/55-prison-store-freshness.sh.
{
  pkgs,
  src ? ../..,
}:

let
  prison = import (src + "/nix/prison") { inherit pkgs; };
  prisonFor =
    packages:
    prison.mkPrison {
      name = "r";
      services = [
        (prison.mkPrisonService {
          name = "s";
          exec = [
            "${pkgs.coreutils}/bin/sleep"
            "infinity"
          ];
          inherit packages;
        })
      ];
    };
  # The bind target each generation's view serves, as the module names it.
  farmOf = packages: "${(builtins.head (prisonFor packages).svcList).storeFarm}/nix/store";
in
pkgs.testers.runNixOSTest {
  name = "prison-store-freshness";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ (import (src + "/nix/prison/module.nix") { inherit prison; }) ];
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;

      services.prisons.r = prisonFor [ ];

      # The next generation: the same service with a different closure, so
      # its store view serves a different farm.
      specialisation.new.configuration = {
        services.prisons.r = lib.mkForce (prisonFor [ pkgs.hello ]);
      };
    };

  testScript =
    let
      old = farmOf [ ];
      new = farmOf [ pkgs.hello ];
    in
    ''
      OLD = "${old}"
      NEW = "${new}"
      HELLO = "${builtins.baseNameOf pkgs.hello}"
      assert OLD != NEW

      def show(prop, unit):
          return machine.succeed(f"systemctl show -p {prop} --value {unit}").strip()

      def served(unit):
          pid = show("MainPID", unit)
          return machine.succeed(f"tr '\\0' ' ' < /proc/{pid}/cmdline")

      machine.wait_for_unit("r-s.service", timeout=300)
      assert OLD in served("r-store-s.service")

      with subtest("the switch window leaves a view serving the old farm"):
          machine.succeed("systemctl stop r.service")
          # Started from the booted generation's unit files...
          machine.succeed("systemctl start r-store-infra-net.service r-store-s.service")
          # ...and then the switch installs the new generation and reloads.
          gen = machine.succeed("readlink -f /run/current-system/specialisation/new").strip()
          machine.succeed(f"{gen}/activate")
          machine.succeed("systemctl daemon-reload")
          assert NEW in show("ExecStart", "r-store-s.service")
          assert OLD in served("r-store-s.service"), "the window did not leave a stale view"

      with subtest("starting the service replaces the stale view"):
          machine.succeed("systemctl start r-s.service")
          machine.wait_until_succeeds(
              "tr '\\0' ' ' < /proc/$(systemctl show -p MainPID --value r-store-s.service)/cmdline"
              f" | grep -qF {NEW}",
              timeout=120,
          )
          machine.wait_for_unit("r-s.service", timeout=120)
          assert NEW in served("r-store-s.service")
          # The container's /nix/store is the new closure.
          machine.succeed(f"test -e /var/lib/r/store/s/{HELLO}")
          machine.succeed("journalctl -b -u r-s.service | grep -F 'prison-store-check: r-store-s.service serves'")
          # Healing is a skipped start and a restart, never a failure.
          machine.fail("journalctl -b -u r-s.service | grep -F 'Failed with result'")
          assert show("Result", "r-s.service") == "success"

      with subtest("a fresh view is left alone"):
          before = show("MainPID", "r-store-s.service")
          machine.succeed("systemctl restart r-s.service")
          machine.wait_for_unit("r-s.service", timeout=120)
          assert show("MainPID", "r-store-s.service") == before
    '';
}
