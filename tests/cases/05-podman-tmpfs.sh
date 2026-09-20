#!/usr/bin/env bash
# Exercise the rendered mount with Podman itself. An argv-only assertion did
# not catch that Podman rejects uid=/gid= in --tmpfs options.

# shellcheck source=../lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

echo "== podman tmpfs ownership =="

rootfs="$SCRATCH/tmpfs-root"
mkdir -p "$rootfs"/{bin,dev,proc,run/service,sys,tmp}
chmod 0755 "$rootfs" "$rootfs"/{bin,dev,proc,run,run/service,sys,tmp}

realize() {
  nix build "${NIX_FLAGS[@]}" --impure --no-link --print-out-paths --expr "$(nix_expr "$1")"
}

busybox=$(realize 'pkgs.pkgsStatic.busybox')/bin/busybox
podman_bin=$(realize 'pkgs.podman.out')/bin/podman
crun_bin=$(realize 'pkgs.crun')/bin/crun
cp "$busybox" "$rootfs/bin/busybox"
chmod 0755 "$rootfs/bin/busybox"

PODMAN='let p = import (flake.outPath + "/nix/podman.nix") { inherit lib; }; in'
command=$(nix_eval "$PODMAN p.renderRunShell \"$podman_bin\" {
  name = \"tmpfs-owner-test\";
  rootfs = \"$rootfs\";
  overlay = false;
  runtime = \"$crun_bin\";
  user = { uid = 1234; gid = 2345; };
  readOnly = false;
  command = [
    \"/bin/busybox\" \"sh\" \"-c\"
    \"/bin/busybox touch /run/service/write-test && /bin/busybox cp /bin/busybox /run/service/noexec-probe && /bin/busybox chmod 0700 /run/service/noexec-probe && if /run/service/noexec-probe true; then exit 70; fi && /bin/busybox stat -c '%u:%g %a' /run/service && /bin/busybox grep ' /run/service ' /proc/mounts | /bin/busybox grep noexec | /bin/busybox grep nosuid | /bin/busybox grep nodev\"
  ];
  mounts = [ {
    type = \"tmpfs\";
    destination = \"/run/service\";
    readOnly = false;
    size = \"8M\";
    mode = \"0750\";
    chown = true;
  } ];
}")

check_out "rendered invocation creates a private service-owned writable tmpfs" \
  "1234:2345 750" bash -c "$command"

finish
