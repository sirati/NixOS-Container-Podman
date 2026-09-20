# The podman backend: prison intent rendered into podman invocations.
#
# nix/prison/default.nix says WHAT a service is; this says HOW podman is told
# about it, including what containers are called. It writes no command line
# either -- it builds values for the validated model in podman.nix, which owns
# argv and its ordering.
#
# Swapping this file is what swapping container runtimes would mean.

{
  pkgs,
  lib ? pkgs.lib,
}:

let
  podman = import ../podman.nix { inherit lib; };
  inherit (podman) renderRun;
  podmanBin = "${pkgs.podman}/bin/podman";
  crunBin = "${pkgs.crun}/bin/crun";

  # PID 1 in a namespace only receives signals it has a handler for
  # (pid_namespaces(7)), so without an init `podman stop` degrades to the
  # SIGKILL after the timeout. podman bind-mounts this itself, so it does not
  # need to be in the container's store view.
  initBin = "${pkgs.catatonit}/bin/catatonit";

  containerName = p: s: "${p.name}-${s.name}";
  ownerName = p: containerName p p.infraNet;

  # The container whose network namespace a service joins: the prison's
  # own owner, or -- for a prison that shares another prison's netns --
  # that prison's owner.
  netnsOwner = p: if (p.joins or null) != null then "${p.joins}-infra-net" else ownerName p;

  storeMountPoint = p: s: "${p.stateDir}/store/${s.name}";
  configMountPoint = p: s: "${p.stateDir}/config/${s.name}";

  resolvConf =
    p:
    pkgs.writeText "${p.name}-resolv.conf" (
      lib.concatMapStringsSep "\n" (address: "nameserver ${address}") p.resolvers + "\n"
    );

  commonMounts =
    p: s:
    [
      {
        type = "bind";
        source = storeMountPoint p s;
        destination = "/nix/store";
        readOnly = true;
        # The store view is the one place execution must be allowed: it is the
        # only executable content in the container, and it is read-only.
        noexec = false;
      }
    ]
    ++ lib.optional s.hasConfig {
      type = "bind";
      source = configMountPoint p s;
      destination = p.configDir;
      readOnly = true;
    }
    ++ lib.optional (p.resolvers != [ ]) {
      type = "bind";
      source = "${resolvConf p}";
      destination = "/etc/resolv.conf";
      readOnly = true;
    }
    ++ [
      {
        type = "tmpfs";
        destination = "/tmp";
        readOnly = false;
        size = s.tmpfsSize;
        mode = "1777";
      }
    ]
    ++ map (st: {
      type = "tmpfs";
      destination = st.path;
      readOnly = false;
      size = st.size or "64M";
      mode = st.mode or "0700";
      # Podman's `chown=true` tmpfs option derives uid/gid from --user.
      # Unlike raw `uid=`/`gid=` options, Podman accepts it and passes the
      # resolved ownership to the OCI runtime.
      chown = true;
    }) s.state
    ++ map (pm: {
      type = "bind";
      source = pm.host;
      destination = pm.path;
      readOnly = pm.readOnly or false;
    }) s.persist;

  baseSpec = p: s: {
    name = containerName p s;
    rootfs = "${s.rootfs}";
    command = s.argv;
    runtime = crunBin;
    user = { inherit (s) uid gid; };
    readOnly = s.readOnlyRoot;
    detach = true;
    capabilities = {
      drop = [ "ALL" ];
      add = s.capabilities;
    };
    init = if s.init then initBin else null;
    env = s.environment;
    mounts = commonMounts p s;
  };

  # The namespace owner: the only container in a prison that has a network
  # namespace of its own, and therefore the only one that may publish ports.
  ownerSpec =
    p:
    baseSpec p p.infraNet
    // {
      remove = false;
      # Podman can retain this namespace holder as an external container
      # across a host reboot. Replacing that stopped object lets the prison
      # reclaim its stable name without touching a live owner.
      replace = true;
      network =
        if p.wantsNetwork then
          {
            mode = "pasta";
            publish = p.publish;
            pastaOptions = p.pastaOptions;
          }
        else
          { mode = "none"; };
    };

  # Every other service is placed in the owner's namespace. It has nothing of
  # its own to configure, and the ruleset governing it was loaded from the
  # host into a namespace it cannot reach.
  serviceSpec =
    p: s:
    baseSpec p s
    // {
      remove = true;
      # Foreground: the service unit is Type=exec and supervises this process
      # directly. Detaching would exit at once, the unit would go dead, and
      # deactivation would tear the container down with it.
      detach = false;
      network = {
        mode = "container";
        container = netnsOwner p;
      };
    };

  runOwner = p: renderRun podmanBin (ownerSpec p);
  runService = p: s: renderRun podmanBin (serviceSpec p s);

  # Telling a service its configuration changed, without recreating it.
  reloadArgs =
    p: s:
    if s.reload == null then
      null
    else if s.reload ? signal then
      [
        podmanBin
        "kill"
        "--signal"
        s.reload.signal
        (containerName p s)
      ]
    else if s.reload ? exec then
      [
        podmanBin
        "exec"
        (containerName p s)
      ]
      ++ s.reload.exec
    else
      throw "prison: service ${s.name} has a `reload` that is neither `signal` nor `exec`.";

  stopArgs = p: s: [
    podmanBin
    "stop"
    "-t"
    "10"
    (containerName p s)
  ];
  rmArgs = p: s: [
    podmanBin
    "rm"
    "-f"
    (containerName p s)
  ];
in
{
  inherit
    podmanBin
    crunBin
    initBin
    containerName
    ownerName
    netnsOwner
    storeMountPoint
    configMountPoint
    ownerSpec
    serviceSpec
    runOwner
    runService
    reloadArgs
    stopArgs
    rmArgs
    ;
}
