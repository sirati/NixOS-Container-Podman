# Host readiness probe.
#
# Two usage modes (auto-detected):
#
# 1. STANDALONE - run on its own to check whether the host is ready
#    for the portable tarball. Doesn't need any sibling files. Probes
#    binaries, /etc/subuid+subgid, /dev/fuse, kernel user-ns, kernel
#    version, podman rootless setup.
#
# 2. BUNDLED   - shipped under `<tarball>/bin/check-host-compat`
#    alongside the rootfs blob. Auto-detects `../data/lower.squash`
#    and adds blob-integrity + disk-free checks on top of the
#    standalone set.
#
# `tools` is accepted for symmetry with the other scripts but unused -
# every reference is a bare command name resolved via $PATH, since
# the whole point is to verify the host's $PATH is correct.

{ tools ? null }:

let
  # Required binaries — every one must resolve on PATH for the
  # container to function. Notable exclusions:
  #   - crun: podman finds its OCI runtime via containers.conf,
  #           NOT $PATH. A separate check below verifies podman
  #           itself works rather than assuming crun is on PATH.
  #   - squashfuse: only required for the squashfs-format tarball.
  #           A separate check below adapts to the bundled rootfs
  #           layout (folder-format tarballs skip squashfuse entirely).
  requiredBins = [
    "podman" "fuse-overlayfs" "fusermount3"
    "socat" "mount" "umount" "mountpoint" "unshare"
    "find" "xargs" "sed" "awk" "bash"
    "dirname" "readlink" "sha256sum" "cut" "id" "df"
  ];
  optionalBins = [ "nvidia-ctk" "lxcfs" "xauth" "crun" ];
in
''
  # Three-state output. Counts FAIL exits non-zero so callers can gate.
  fails=0
  warns=0
  passes=0

  pass() { printf 'OK    %s\n' "$*"; passes=$((passes+1)); }
  warn() { printf 'WARN  %s\n' "$*"; warns=$((warns+1)); }
  fail() { printf 'FAIL  %s\n' "$*"; fails=$((fails+1)); }

  # ----- required binaries on PATH ----------------------------------
  echo
  echo '== required binaries =='
  for b in ${builtins.concatStringsSep " " requiredBins}; do
    if command -v "$b" >/dev/null 2>&1; then
      pass "$b: $(command -v "$b")"
    else
      fail "$b: not found on PATH"
    fi
  done

  # ----- optional binaries ------------------------------------------
  echo
  echo '== optional binaries =='
  for b in ${builtins.concatStringsSep " " optionalBins}; do
    if command -v "$b" >/dev/null 2>&1; then
      pass "$b: $(command -v "$b")"
    else
      warn "$b: not found (some features will degrade)"
    fi
  done

  # ----- subuid / subgid --------------------------------------------
  # These files are ONE common way to allocate ranges for rootless
  # containers, but not the only one. Some distros use systemd-homed,
  # some HPC setups use PAM-allocated ranges, etc. The authoritative
  # check is `podman info` below; treat the file presence as a hint
  # only (WARN, not FAIL).
  echo
  echo '== rootless user-ns config =='
  user=$(id -un)
  for f in /etc/subuid /etc/subgid; do
    if [ ! -e "$f" ]; then
      warn "$f: missing — fine if podman info works below (some setups use other mechanisms)"
    elif grep -q "^$user:" "$f" 2>/dev/null; then
      pass "$f: has entry for $user"
    else
      warn "$f: no entry for $user — fine if podman info works below"
    fi
  done

  # ----- /dev/fuse --------------------------------------------------
  echo
  echo '== fuse =='
  if [ ! -e /dev/fuse ]; then
    fail "/dev/fuse: missing — load the fuse kernel module"
  elif [ ! -r /dev/fuse ] || [ ! -w /dev/fuse ]; then
    fail "/dev/fuse: not r/w for $user (check distro fuse setup)"
  else
    pass "/dev/fuse: usable"
  fi

  # ----- user-ns + mount-ns combo -----------------------------------
  echo
  echo '== unprivileged user-ns =='
  # `true` resolves via PATH (set by preamble) — works on Debian
  # (/usr/bin/true), NixOS (/run/current-system/sw/bin/true), etc.
  if unshare -Urm true 2>/dev/null; then
    pass "unshare -Urm true: works"
  else
    fail "unshare -Urm true: failed — kernel/distro may have unprivileged-userns disabled (sysctl kernel.unprivileged_userns_clone=1)"
  fi

  # ----- kernel version --------------------------------------------
  echo
  echo '== kernel =='
  rel=$(cat /proc/sys/kernel/osrelease 2>/dev/null || echo unknown)
  # Need 5.11+ for overlayfs userxattr (the kernel overlay we mount
  # rootless requires that flag). Parse "MAJOR.MINOR..." prefix.
  major=$(printf '%s' "$rel" | awk -F. '{print $1+0}')
  minor=$(printf '%s' "$rel" | awk -F. '{print $2+0}')
  if [ "$major" -gt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -ge 11 ]; }; then
    pass "kernel: $rel (>= 5.11 for overlayfs userxattr)"
  else
    fail "kernel: $rel — need >= 5.11 for overlayfs userxattr"
  fi

  # ----- rootless podman --------------------------------------------
  echo
  echo '== rootless podman =='
  if command -v podman >/dev/null 2>&1 && podman info >/dev/null 2>&1; then
    pass "podman info: ok"
  else
    fail "podman info: failed — fix rootless setup before continuing"
  fi

  # ----- tarball-layout-aware checks --------------------------------
  # The check script lives at <tarball>/bin/check-host-compat with
  # either data/lower.squash (squashfs format) or data/lower/ (folder
  # format) as a sibling. If we can't find either, we're being run
  # standalone.
  script_dir=$(dirname -- "$(readlink -f -- "$0")")
  base_dir=$(dirname -- "$script_dir")
  blob="$base_dir/data/lower.squash"
  folder="$base_dir/data/lower"

  echo
  echo '== rootfs format =='
  if [ -e "$blob" ]; then
    pass "format: squashfs (data/lower.squash present)"
    bundled_format=squashfs
  elif [ -d "$folder" ]; then
    pass "format: folder (data/lower/ present)"
    bundled_format=folder
  else
    echo '(standalone mode - no bundled rootfs)'
    bundled_format=none
  fi

  # squashfuse: required only for squashfs-format tarballs. Standalone
  # mode warns (we don't know which format the user plans to use).
  echo
  echo '== squashfuse (squashfs-format tarballs only) =='
  if command -v squashfuse >/dev/null 2>&1; then
    pass "squashfuse: $(command -v squashfuse)"
  elif [ "$bundled_format" = "squashfs" ]; then
    fail "squashfuse: not found on PATH (REQUIRED for this squashfs-format tarball)"
  elif [ "$bundled_format" = "folder" ]; then
    pass "squashfuse: not needed (folder-format tarball)"
  else
    warn "squashfuse: not found on PATH (needed if you'll use a squashfs-format tarball)"
  fi

  if [ "$bundled_format" = "squashfs" ]; then
    echo
    echo '== rootfs blob integrity =='
    expected="$base_dir/data/lower.squash.sha256"
    if [ ! -e "$expected" ]; then
      warn "lower.squash.sha256: missing — cannot verify integrity"
    else
      actual=$(sha256sum "$blob" | cut -d' ' -f1)
      want=$(cat "$expected")
      if [ "$actual" = "$want" ]; then
        pass "lower.squash sha256: matches"
      else
        fail "lower.squash sha256: mismatch (got $actual, want $want)"
      fi
    fi
  fi

  if [ "$bundled_format" != "none" ]; then
    echo
    echo '== disk =='
    data_dir="$base_dir/data"
    free_kb=$(df -k "$data_dir" | awk 'NR==2 {print $4}')
    # 4 GB = 4*1024*1024 KiB.
    if [ "$free_kb" -ge 4194304 ]; then
      pass "data/ free: $((free_kb/1024)) MiB (>= 4 GiB)"
    else
      warn "data/ free: $((free_kb/1024)) MiB (< 4 GiB; may not fit substituters/builds)"
    fi
  fi

  # ----- summary ----------------------------------------------------
  echo
  echo "== summary =="
  echo "passes: $passes  warns: $warns  fails: $fails"
  if [ "$fails" -gt 0 ]; then
    echo "host is NOT ready; fix FAIL items before running ./bin/up." >&2
  elif [ "$warns" -gt 0 ]; then
    echo "host is usable but some features may degrade." >&2
  else
    echo "host is ready." >&2
  fi
  exit "$fails"
''
