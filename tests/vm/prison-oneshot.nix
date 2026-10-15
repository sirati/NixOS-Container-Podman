# A oneshot prison service is a task: its unit ends when the program does,
# with the program's exit status, and the container is not removed under it.
#
# Before the mode existed, consumers forced a prison service to
# Type=oneshot. Its `podman run -d` returned as soon as the container
# started, the unit counted that as success, and its ExecStopPost removed the
# container while the program was still running. Nothing it failed at could
# be seen, retried or depended on.
#
# Driven by tests/cases/56-prison-oneshot.sh.
{
  pkgs,
  src ? ../..,
}:

let
  prison = import (src + "/nix/prison") { inherit pkgs; };
  coreutils = "${pkgs.coreutils}/bin";
  task =
    name: exec:
    prison.mkPrisonService {
      inherit name exec;
      oneshot = true;
      persist = [
        {
          host = "/var/lib/o/out";
          path = "/out";
        }
      ];
    };
in
pkgs.testers.runNixOSTest {
  name = "prison-oneshot";

  nodes.machine = {
    imports = [ (import (src + "/nix/prison/module.nix") { inherit prison; }) ];
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;

    services.prisons.o = prison.mkPrison {
      name = "o";
      services = [
        (task "slow" [
          "${coreutils}/sleep"
          "5"
        ])
        (task "writes" [
          "${coreutils}/touch"
          "/out/done"
        ])
        (task "fails" [
          "${coreutils}/false"
        ])
        # Exits 143, as a program killed by SIGTERM does through catatonit.
        (task "terminated" [
          "${coreutils}/timeout"
          "--preserve-status"
          "--signal=TERM"
          "1"
          "${coreutils}/sleep"
          "30"
        ])
      ];
    };
  };

  testScript = ''
    import time

    def show(prop, unit):
        return machine.succeed(f"systemctl show -p {prop} --value {unit}").strip()

    machine.wait_for_unit("o.service", timeout=300)

    with subtest("a task is not started with its prison"):
        for unit in ["o-slow.service", "o-writes.service", "o-fails.service", "o-terminated.service"]:
            assert show("ActiveState", unit) == "inactive", unit
            assert show("NRestarts", unit) == "0", unit

    with subtest("the unit ends when the program does, and succeeds with it"):
        start = time.monotonic()
        machine.succeed("systemctl start o-slow.service")
        elapsed = time.monotonic() - start
        assert elapsed >= 5, f"the start returned after {elapsed:.1f}s, before the program ended"
        assert show("Result", "o-slow.service") == "success"
        machine.fail("su -s /bin/sh o -c 'XDG_RUNTIME_DIR=/run/user/$(id -u o) podman container exists o-slow'")

    with subtest("the program runs to its end"):
        machine.succeed("systemctl start o-writes.service")
        machine.succeed("test -e /var/lib/o/out/done")

    with subtest("the program's failure is the unit's failure"):
        machine.fail("systemctl start o-fails.service")
        assert show("Result", "o-fails.service") == "exit-code"
        assert show("ExecMainStatus", "o-fails.service") == "1"

    with subtest("a task whose program died of SIGTERM has failed"):
        machine.fail("systemctl start o-terminated.service")
        assert show("Result", "o-terminated.service") == "exit-code"
        assert show("ExecMainStatus", "o-terminated.service") == "143"

    with subtest("stopping a running task is not a failure"):
        machine.succeed("systemctl start --no-block o-slow.service")
        machine.wait_until_succeeds("test \"$(systemctl show -p ActiveState --value o-slow.service)\" = activating", timeout=60)
        machine.succeed("systemctl stop o-slow.service")
        assert show("Result", "o-slow.service") == "success"
  '';
}
