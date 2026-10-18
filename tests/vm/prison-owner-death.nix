# A prison whose namespace owner dies is set up again by itself.
#
# The owner (the infra container and its network link) runs under no unit
# of its own. While the prison's unit was a oneshot that stayed active, a
# dead owner went unnoticed: its services kept a namespace without a
# network, and restarting one of them joined the same broken namespace.
# Now the unit waits on the owner, ends when it dies and is restarted, and
# brings its services back.
#
# Driven by tests/cases/57-prison-owner-death.sh.
{
  pkgs,
  src ? ../..,
}:

let
  prison = import (src + "/nix/prison") { inherit pkgs; };
  coreutils = "${pkgs.coreutils}/bin";
in
pkgs.testers.runNixOSTest {
  name = "prison-owner-death";

  nodes.machine = {
    imports = [ (import (src + "/nix/prison/module.nix") { inherit prison; }) ];
    virtualisation.memorySize = 2048;
    virtualisation.cores = 2;

    # As hosts keep it (sirati-nixos base-config): the wrappers unit stays
    # active, so an update that changes a wrapper stops and starts it.
    systemd.services.suid-sgid-wrappers.serviceConfig.RemainAfterExit = true;

    # Stands in for a fault report: what OnFailure= of the prison runs.
    systemd.services.w.unitConfig.OnFailure = [ "w-failed.service" ];
    systemd.services.w-failed.serviceConfig = {
      Type = "oneshot";
      ExecStart = "${coreutils}/touch /run/w-failed";
    };

    services.prisons.w = prison.mkPrison {
      name = "w";
      services = [
        (prison.mkPrisonService {
          name = "sleeper";
          exec = [ "${coreutils}/sleep" "infinity" ];
        })
      ];
    };
  };

  testScript = ''
    def show(prop, unit):
        return machine.succeed(f"systemctl show -p {prop} --value {unit}").strip()

    def owner_pid():
        return machine.succeed("su -s /bin/sh w -c 'XDG_RUNTIME_DIR=/run/user/$(id -u w) podman inspect w-infra-net --format {{.State.Pid}}'").strip()

    machine.wait_for_unit("w.service", timeout=300)
    machine.wait_for_unit("w-sleeper.service", timeout=300)

    with subtest("the prison's unit runs as long as its namespace owner"):
        assert show("Type", "w.service") == "notify"
        assert show("SubState", "w.service") == "running"
        first = owner_pid()
        prison = show("InvocationID", "w.service")
        sleeper = show("InvocationID", "w-sleeper.service")

    with subtest("a dead owner is set up again, with the prison's services"):
        machine.succeed(f"kill -KILL {first}")
        machine.wait_until_succeeds(f"test \"$(systemctl show -p InvocationID --value w.service)\" != {prison}", timeout=120)
        machine.wait_for_unit("w.service", timeout=300)
        machine.wait_for_unit("w-sleeper.service", timeout=300)
        assert owner_pid() not in ("", "0", first)
        assert show("InvocationID", "w-sleeper.service") != sleeper
        # The death is a failure, for the fault reports.
        machine.succeed("test -e /run/w-failed", "rm /run/w-failed")

    with subtest("killing the prison's unit itself is a failure it recovers from"):
        machine.wait_for_unit("w.service", timeout=300)
        prison = show("InvocationID", "w.service")
        machine.succeed("systemctl kill --signal=SIGKILL w.service")
        machine.wait_until_succeeds(f"test \"$(systemctl show -p InvocationID --value w.service)\" != {prison}", timeout=120)
        machine.wait_for_unit("w.service", timeout=300)
        machine.wait_for_unit("w-sleeper.service", timeout=300)
        machine.succeed("test -e /run/w-failed", "rm /run/w-failed")

    with subtest("an update of the setuid wrappers leaves the prison running"):
        machine.wait_for_unit("w-sleeper.service", timeout=300)
        prison = show("InvocationID", "w.service")
        sleeper = show("InvocationID", "w-sleeper.service")
        machine.succeed("systemctl is-active suid-sgid-wrappers.service")
        # What switch-to-configuration does with a changed wrappers unit.
        machine.succeed("systemctl stop suid-sgid-wrappers.service", "systemctl start suid-sgid-wrappers.service")
        machine.sleep(5)
        assert show("InvocationID", "w.service") == prison
        assert show("InvocationID", "w-sleeper.service") == sleeper
        assert show("ActiveState", "w.service") == "active"

    with subtest("a deliberate stop is not undone"):
        machine.succeed("systemctl stop w.service")
        machine.sleep(10)
        state = [show(p, "w.service") for p in ("ActiveState", "Result", "ExecMainCode", "ExecMainStatus")]
        assert state[0] == "inactive", state
        machine.fail("test -e /run/w-failed")
        assert show("ActiveState", "w-sleeper.service") == "inactive"
  '';
}
