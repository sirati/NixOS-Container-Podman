# State: the shared host directories, the store GC roots, the state directory
# layout, and mounting the rootfs lower.
#
# Split out of run.nix. The body is emitted verbatim in the same position, so
# the generated script is unchanged -- verified by hashing it before and after.

{ tools
, mountLowerBody
}:

''
  # ----- helpers -------------------------------------------------

  # Host-side dir bound into the container as /hostmnts. Each
  # `develop <hostpath>` adds a sub-bind here; the container sees
  # the change via rshared propagation. Mode 0700 so that only
  # container-root (= host sirati) can enumerate it - session
  # users in the container never see /hostmnts directly.
  WORK_SHARED="$STATE_DIR/work-shared"
  # Parallel dir for RAW unix-socket binds (Wayland, X11, …)
  # that need full fd-passing (SCM_RIGHTS). socat can't proxy
  # SCM_RIGHTS, so these have to be bind-mounted directly at a
  # path the session user can traverse. Mode 0711: world can
  # cross but only root can list. The socket files inside
  # inherit their source's perms (typically 0755 for Wayland,
  # 0777 for X11), which is what gates actual access.
  SOCKET_MOUNTS="$STATE_DIR/socket-mounts"
  # HOST_NIX_DAEMON only: per-session GC-root directory. Bound into the
  # container at the IDENTICAL absolute path so a store-pointing
  # symlink created here resolves the same in both namespaces; the
  # host nix-daemon then protects those paths from
  # nix-collect-garbage for the session lifetime. Each develop
  # session gets a 0700 root-owned subdir $SESSION_GCROOTS/<mount_id>.
  SESSION_GCROOTS="$STATE_DIR/session-gcroots"

  # plant_store_gcroot / drop_store_gcroot: host-side GC-root lifecycle
  # for HOST_NIX_STORE mode. The symlink farm ($NIX_STORE_LOWER) and its
  # closure live in the HOST store; an indirect root keeps the host
  # daemon from collecting them while the container exists. No-op unless
  # HOST_NIX_STORE=1 (self-contained / daemon modes don't need it).
  plant_store_gcroot() {
    [ "$HOST_NIX_STORE" = "1" ] || return 0
    [ -n "$NIX_STORE_LOWER" ] || return 0
    nix-store --realise --add-root "$NIX_STORE_LOWER_GCROOT" \
      "$NIX_STORE_LOWER" >/dev/null 2>&1 || true
  }
  drop_store_gcroot() {
    rm -f -- "$NIX_STORE_LOWER_GCROOT" 2>/dev/null || true
  }
  # store_summary: one-word description of the /nix provisioning for
  # status / up output, derived from the resolved axes.
  store_summary() {
    if [ "$HOST_NIX_DAEMON" = "1" ]; then
      echo "host-daemon"
    elif [ "$HOST_NIX_STORE" = "1" ]; then
      echo "host-store"
    else
      echo "self-contained"
    fi
  }

  # Idempotent: create $STATE_DIR layout, pre-populate UPPER with
  # writable copies of every directory NixOS activation chmods or
  # writes into.
  ensure_state() {
    # Host-side dirs that the calling user owns natively: safe
    # to mkdir/chmod directly.
    mkdir -p \
      "$PODMAN_ROOT" "$PODMAN_RUNROOT" \
      "$WORK" "$MERGED" \
      "$WORK_SHARED" "$SOCKET_MOUNTS"
    chmod 0700 -- "$WORK_SHARED"
    chmod 0711 -- "$SOCKET_MOUNTS"

    # HOST_NIX_DAEMON: per-session GC-root parent dir (host side, owned
    # by the calling user = container root under default rootless).
    if [ "$HOST_NIX_DAEMON" = "1" ]; then
      mkdir -p "$SESSION_GCROOTS"
      chmod 0700 -- "$SESSION_GCROOTS"
    fi

    # NIX_UPPER / NIX_WORK back the /nix/store overlay, needed for every
    # combo EXCEPT directory mode (no overlays) and HOST_NIX_DAEMON (whole
    # /nix rbind). Created here; harmless to skip when unused.
    _STORE_OVERLAY=0
    if [ "$STORAGE" != "directory" ] && [ "$HOST_NIX_DAEMON" != "1" ]; then
      _STORE_OVERLAY=1
    fi

    if [ "$STORAGE" = "directory" ]; then
      # No rootfs overlay: materialize $ROOTFS into a writable real copy
      # at $MERGED. Idempotent - skip if already populated (a non-empty
      # $MERGED means a prior run already copied it). cp -a preserves the
      # tree; chmod -R u+w makes the store-derived 0444/0555 files
      # writable so in-container activation can rewrite them. Run inside
      # podman unshare for CAP_DAC_OVERRIDE on subuid-owned files.
      _ROOTFS=$ROOTFS _MERGED=$MERGED \
        podman unshare ${tools.bash} -c '
        set -euo pipefail
        if [ -z "$(ls -A "$_MERGED" 2>/dev/null)" ]; then
          cp -a "$_ROOTFS"/. "$_MERGED"/
          chmod -R u+w "$_MERGED"
        fi
      '
    fi

    # UPPER and NIX_UPPER may already be migrated to host's
    # first subuid (when useKeepId is on), so the calling user
    # can neither traverse them nor chmod them directly. Run
    # the layout/perms setup inside `podman unshare`, which
    # has CAP_FOWNER + CAP_DAC_OVERRIDE for files owned by
    # uids mapped in the rootless user-ns - covers both the
    # pre-migration (sirati-owned) and post-migration (subuid-
    # owned) cases. The UPPER skeleton only backs the rootfs
    # overlay (ephemeral/overlay); directory mode has none.
    _UPPER=$UPPER _NIX_UPPER=$NIX_UPPER _NIX_WORK=$NIX_WORK \
    _STORAGE=$STORAGE _STORE_OVERLAY=$_STORE_OVERLAY \
    _ROOTFS=$ROOTFS _HOST_NIX_DAEMON=$HOST_NIX_DAEMON \
      podman unshare ${tools.bash} -c '
      set -euo pipefail
      if [ "$_STORE_OVERLAY" = "1" ]; then
        mkdir -p "$_NIX_UPPER" "$_NIX_WORK"
      fi
      [ "$_STORAGE" = "directory" ] && exit 0
      mkdir -p "$_UPPER"
      mkdir -p \
        "$_UPPER"/bin "$_UPPER"/sbin \
        "$_UPPER"/etc "$_UPPER"/home "$_UPPER"/root \
        "$_UPPER"/usr "$_UPPER"/opt "$_UPPER"/boot "$_UPPER"/mnt \
        "$_UPPER"/srv "$_UPPER"/run "$_UPPER"/run/secrets \
        "$_UPPER"/run/wrappers \
        "$_UPPER"/var "$_UPPER"/var/lib "$_UPPER"/var/log \
        "$_UPPER"/var/cache "$_UPPER"/var/spool "$_UPPER"/var/empty \
        "$_UPPER"/var/tmp "$_UPPER"/tmp \
        "$_UPPER"/work
      # Nix DB / daemon-socket location. The profiles/per-user and
      # gcroots/per-user dirs are pre-created in the WRITABLE upper so they
      # mask the read-only, host-root-owned copies baked into the
      # system-lower /nix/var: an in-container nix-daemon (self-contained or
      # host-store modes) chmods these to 1777 on connect, which EPERMs
      # against the baked dirs (owned by a uid unmapped in the rootless
      # user-ns). The upper copies are owned by container root, so the chmod
      # succeeds.
      mkdir -p \
        "$_UPPER"/nix/var/nix/db \
        "$_UPPER"/nix/var/nix/profiles/per-user \
        "$_UPPER"/nix/var/nix/gcroots/per-user \
        "$_UPPER"/nix/var/nix/temproots \
        "$_UPPER"/nix/var/nix/userpool \
        "$_UPPER"/nix/var/nix/daemon-socket
      chmod 1777 "$_UPPER"/tmp "$_UPPER"/var/tmp \
        "$_UPPER"/nix/var/nix/profiles/per-user \
        "$_UPPER"/nix/var/nix/gcroots/per-user
      # Stage a WRITABLE, container-root-owned copy of the baked nix db into
      # the upper. The db baked into the system-lower /nix/var is read-only
      # (0444) and owned by an unmapped (host-root) uid; an overlay copy-up
      # on the first daemon write would inherit those attrs, so the
      # in-container daemon could not write it ("attempt to write a readonly
      # database"). A plain cp (not -a) makes a container-root-owned copy
      # that masks the baked one; chmod makes it writable. Skip in daemon
      # mode (the host db is authoritative) and never clobber a db the
      # daemon has already been writing across restarts.
      if [ "$_HOST_NIX_DAEMON" != "1" ] \
         && [ -f "$_ROOTFS/nix/var/nix/db/db.sqlite" ] \
         && [ ! -f "$_UPPER/nix/var/nix/db/db.sqlite" ]; then
        cp "$_ROOTFS"/nix/var/nix/db/db.sqlite "$_UPPER"/nix/var/nix/db/db.sqlite
        chmod 0644 "$_UPPER"/nix/var/nix/db/db.sqlite
        if [ -f "$_ROOTFS/nix/var/nix/db/schema" ]; then
          cp "$_ROOTFS"/nix/var/nix/db/schema "$_UPPER"/nix/var/nix/db/schema
          chmod 0644 "$_UPPER"/nix/var/nix/db/schema
        fi
      fi
      : > "$_UPPER"/etc/hostname
      : > "$_UPPER"/etc/hosts
      : > "$_UPPER"/etc/resolv.conf
      : > "$_UPPER"/run/.containerenv
      # Stage a real, persistent /etc/machine-id into the upper. The
      # rootfs lower ships it empty (normal for a NixOS image), so
      # without this systemd finds it empty at every boot and falls
      # back to its container-transient-ID path: a read-only tmpfs
      # over /etc/machine-id plus systemd-machine-id-commit.service to
      # persist it later. That commit step relies on container-runtime
      # integration podman does not provide, so it always fails
      # (degraded, not running). Pre-seeding a non-empty ID here means
      # systemd never creates the transient mount, so the commit unit
      # condition (ConditionPathIsMountPoint=/etc/machine-id) is false
      # and it is skipped instead of run. Generated once and kept
      # stable across restarts (not regenerated if already present).
      if [ ! -s "$_UPPER"/etc/machine-id ]; then
        { head -c 16 /dev/urandom | od -An -tx1 | tr -d " \n"; echo; } \
          > "$_UPPER"/etc/machine-id
        chmod 0444 "$_UPPER"/etc/machine-id
      fi
    '
  }

  # mount_rootfs_lower: set up $ROOTFS as a usable lowerdir for the
  # kernel-overlayfs mount in start_persistent / boot. NixOS-host: a
  # no-op (ROOTFS is already a /nix/store path). Portable: mount the
  # squashfs blob via squashfuse and point $ROOTFS at the mount.
  # Called BEFORE `podman unshare`, in the host's normal mount-ns, so
  # the unshare inherits the mount.
  mount_rootfs_lower() {
    ${mountLowerBody}
  }
''
