# Readiness of a prison service unit while PID 1 is busy.
#
# A prison service unit used to report readiness with an sd_notify datagram
# sent by a short-lived rootless podman child. When PID 1 reached the
# datagram after that child had exited, it could not attribute it to the
# unit and failed the start with result 'protocol'. A daemon-reload loop is
# the reliable way to make PID 1 that late. This drives the module's own
# generated units through start/stop under that load and counts failures.
#
# Driven by tests/cases/50-prison-readiness.sh. `src` is the tree whose
# nix/prison is tested, so the same script can be pointed at an older
# checkout to show the race there.
{
  pkgs,
  src ? ../..,
  iterations ? 30,
}:

pkgs.testers.runNixOSTest {
  name = "prison-readiness";

  nodes.machine =
    { pkgs, ... }:
    let
      prison = import (src + "/nix/prison") { inherit pkgs; };
    in
    {
      imports = [ (import (src + "/nix/prison/module.nix") { inherit prison; }) ];
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;

      services.prisons.r = prison.mkPrison {
        name = "r";
        services = [
          (prison.mkPrisonService {
            name = "s";
            exec = [
              "${pkgs.coreutils}/bin/sleep"
              "infinity"
            ];
          })
        ];
      };

      # A dependent service, ordered after the prison service the way a
      # consumer's is. It must only ever find the container running.
      systemd.services.dependent = {
        after = [ "r-s.service" ];
        requires = [ "r-s.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          User = "r";
          ExecStart = pkgs.writeShellScript "dependent-check" ''
            state=$(${pkgs.podman}/bin/podman container inspect --format '{{.State.Running}}' r-s)
            [ "$state" = true ] || { echo "container not running: $state" >&2; exit 1; }
          '';
        };
      };
    };

  testScript = ''
    N = ${toString iterations}
    U = "r-s.service"

    machine.wait_for_unit(U, timeout=300)

    def show(prop, unit=U):
        return machine.succeed(f"systemctl show -p {prop} --value {unit}").strip()

    def cycle(tag):
        fails = {}
        for i in range(N):
            machine.execute("systemctl stop dependent.service " + U + "; systemctl reset-failed " + U + " dependent.service")
            rc, _ = machine.execute("systemctl start dependent.service", timeout=300)
            if rc != 0:
                key = show("Result")
                if key == "success":
                    key = "dependent " + show("Result", "dependent.service")
                fails[key] = fails.get(key, 0) + 1
        print(f"RESULT {tag}: {N - sum(fails.values())}/{N} ok, failures {fails}")
        return sum(fails.values())

    quiet = cycle("quiet")

    machine.succeed("systemd-run --unit=busy-reload -p Type=exec sh -c 'while :; do systemctl daemon-reload; done'")
    loaded = cycle("daemon-reload loop")
    machine.succeed("systemctl stop busy-reload")

    assert quiet == 0 and loaded == 0, f"{quiet} quiet and {loaded} loaded start failures"

    with subtest("systemd supervises conmon as the main process"):
        machine.succeed("systemctl start dependent.service")
        pid = show("MainPID")
        assert machine.succeed(f"cat /proc/{pid}/comm").strip() == "conmon"
        machine.succeed(f"grep -q '/r-s.service$' /proc/{pid}/cgroup")

    with subtest("the container exiting is noticed and the service restarted"):
        before = int(show("NRestarts"))
        machine.succeed("su -s /bin/sh r -c 'XDG_RUNTIME_DIR=/run/user/$(id -u r) podman kill r-s'")
        machine.wait_until_succeeds(f"[ $(systemctl show -p NRestarts --value {U}) -gt {before} ]", timeout=60)
        machine.wait_for_unit(U, timeout=60)
  '';
}
