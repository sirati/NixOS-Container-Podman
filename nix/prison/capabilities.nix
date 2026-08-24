# Linux capabilities as a typed set, one named field per capability.
#
# A capability is not a string. Spelling it as one means a typo renders a flag
# that podman accepts and the kernel ignores, or -- worse -- one that silently
# grants nothing while the configuration reads as though it granted something.
# Here every capability is an option: an unknown name is an evaluation error
# naming the file and line, and there is nothing to prefix or misspell.
#
# Every field defaults to false. That is the whole point: the default is not
# "the podman default set", it is nothing, and each capability a service gets
# is a line someone wrote on purpose.
#
# The list is CAP_CHOWN(0) through CAP_LAST_CAP, taken from
# linux/capability.h. Capabilities are a kernel concept, so this file names no
# container runtime.

{ lib }:

let
  inherit (lib) mkOption types;

  # { cap = the kernel name without its CAP_ prefix; opt = the option name. }
  capabilities = [
    { cap = "CHOWN"; opt = "chown"; desc = "Change the ownership of any file."; }
    { cap = "DAC_OVERRIDE"; opt = "dacOverride"; desc = "Bypass file read, write and execute permission checks."; }
    { cap = "DAC_READ_SEARCH"; opt = "dacReadSearch"; desc = "Bypass file read permission checks and directory read/execute checks."; }
    { cap = "FOWNER"; opt = "fowner"; desc = "Bypass permission checks that normally require the file's uid to match."; }
    { cap = "FSETID"; opt = "fsetid"; desc = "Keep set-user-ID and set-group-ID bits when a file is modified."; }
    { cap = "KILL"; opt = "kill"; desc = "Send signals to processes owned by other users."; }
    { cap = "SETGID"; opt = "setgid"; desc = "Set arbitrary group ids, including in credentials passed over unix sockets."; }
    { cap = "SETUID"; opt = "setuid"; desc = "Set arbitrary user ids, including in credentials passed over unix sockets."; }
    { cap = "SETPCAP"; opt = "setpcap"; desc = "Add capabilities to, or drop them from, other processes' bounding sets."; }
    { cap = "LINUX_IMMUTABLE"; opt = "linuxImmutable"; desc = "Set the immutable and append-only inode flags."; }
    { cap = "NET_BIND_SERVICE"; opt = "netBindService"; desc = "Bind a socket to a port below 1024. What a nameserver needs for port 53."; }
    { cap = "NET_BROADCAST"; opt = "netBroadcast"; desc = "Broadcast and listen to multicast. Unused by the kernel in practice."; }
    { cap = "NET_ADMIN"; opt = "netAdmin"; desc = "Configure interfaces, routing, firewall rules and namespaces. Almost never right for a service: it is the capability that lets a process rewrite the policy confining it."; }
    { cap = "NET_RAW"; opt = "netRaw"; desc = "Open raw and packet sockets. Enables spoofing and sniffing within the namespace."; }
    { cap = "IPC_LOCK"; opt = "ipcLock"; desc = "Lock memory (mlock, mlockall, shmctl SHM_LOCK). Needed to keep key material out of swap."; }
    { cap = "IPC_OWNER"; opt = "ipcOwner"; desc = "Bypass permission checks on System V IPC objects."; }
    { cap = "SYS_MODULE"; opt = "sysModule"; desc = "Load and unload kernel modules. Equivalent to owning the host."; }
    { cap = "SYS_RAWIO"; opt = "sysRawio"; desc = "Perform raw I/O to ports and /dev/mem. Equivalent to owning the host."; }
    { cap = "SYS_CHROOT"; opt = "sysChroot"; desc = "Call chroot and change mount namespaces."; }
    { cap = "SYS_PTRACE"; opt = "sysPtrace"; desc = "Trace and inspect arbitrary processes. Reads their memory, including secrets."; }
    { cap = "SYS_PACCT"; opt = "sysPacct"; desc = "Configure process accounting."; }
    { cap = "SYS_ADMIN"; opt = "sysAdmin"; desc = "A grab bag covering mount, swap, quota, namespaces and much else. Effectively root; granting it forfeits most of the confinement."; }
    { cap = "SYS_BOOT"; opt = "sysBoot"; desc = "Reboot the machine and load a new kernel."; }
    { cap = "SYS_NICE"; opt = "sysNice"; desc = "Raise scheduling priority and set real-time and CPU-affinity policies."; }
    { cap = "SYS_RESOURCE"; opt = "sysResource"; desc = "Exceed resource limits, including raising hard rlimits and reserved-space quotas."; }
    { cap = "SYS_TIME"; opt = "sysTime"; desc = "Set the system clock. A DNSSEC signer with this can move itself past a signature expiry."; }
    { cap = "SYS_TTY_CONFIG"; opt = "sysTtyConfig"; desc = "Configure and hang up terminals."; }
    { cap = "MKNOD"; opt = "mknod"; desc = "Create device special files."; }
    { cap = "LEASE"; opt = "lease"; desc = "Take leases on files the process does not own."; }
    { cap = "AUDIT_WRITE"; opt = "auditWrite"; desc = "Write records to the kernel audit log."; }
    { cap = "AUDIT_CONTROL"; opt = "auditControl"; desc = "Enable, disable and configure kernel auditing."; }
    { cap = "SETFCAP"; opt = "setfcap"; desc = "Set file capabilities, which is a route to granting itself more later."; }
    { cap = "MAC_OVERRIDE"; opt = "macOverride"; desc = "Override mandatory access control (Smack)."; }
    { cap = "MAC_ADMIN"; opt = "macAdmin"; desc = "Configure mandatory access control policy (Smack)."; }
    { cap = "SYSLOG"; opt = "syslog"; desc = "Read and control the kernel ring buffer, and see kernel addresses."; }
    { cap = "WAKE_ALARM"; opt = "wakeAlarm"; desc = "Set timers that wake a suspended system."; }
    { cap = "BLOCK_SUSPEND"; opt = "blockSuspend"; desc = "Block system suspend."; }
    { cap = "AUDIT_READ"; opt = "auditRead"; desc = "Read the audit log via a multicast netlink socket."; }
    { cap = "PERFMON"; opt = "perfmon"; desc = "Use perf events and other performance monitoring interfaces."; }
    { cap = "BPF"; opt = "bpf"; desc = "Load BPF programs and create BPF maps."; }
    { cap = "CHECKPOINT_RESTORE"; opt = "checkpointRestore"; desc = "Checkpoint and restore processes, including setting arbitrary pids."; }
  ];

  options = lib.listToAttrs (map
    (c: lib.nameValuePair c.opt (mkOption {
      type = types.bool;
      default = false;
      description = c.desc;
    }))
    capabilities);

  # The kernel names of everything set to true, in header order.
  granted = cfg:
    map (c: "CAP_${c.cap}")
      (lib.filter (c: cfg.${c.opt} or false) capabilities);

  type = types.submodule { inherit options; };
in
{
  inherit options granted type capabilities;
}
