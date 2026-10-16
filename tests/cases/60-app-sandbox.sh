#!/usr/bin/env bash
#
# mkApp: a program in a rootless container that the host reaches through an
# ordinary command. The properties that make it a sandbox are checked here with
# busybox standing in for the app, so no compositor or GPU is needed: what the
# program can see, what it can change, who it runs as, and that its loopback is
# its own.

# shellcheck source=../lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

echo "== app sandbox =="

# A home directory that is not the real one, so the case writes nothing under
# the user's $HOME (the residue check would, rightly, object).
home="$SCRATCH/apphome"
rm -rf "$home"
mkdir -p "$home/Docs"
printf 'visible\n' >"$home/Docs/note.txt"
printf 'loose\n' >"$home/loose.txt"
printf 'secret\n' >"$home/.secret"
mkdir -p "$home/.ssh"

me=$(id -un) uid=$(id -u) gid=$(id -g)

# shellcheck disable=SC2016 # {home} is for mkApp to fill in, not the shell
expr="ct.mkApp {
  name = \"probe\";
  prefix = \"apptest\";
  package = pkgs.busybox;
  users = [ { name = \"$me\"; uid = $uid; gid = $gid; home = \"$home\"; } ];
  homeVisible = true;
  entries = {
    bb       = { exec = \"bin/busybox\"; stdio = true; cwd = true; env.PROBE_HOME = \"{home}\"; };
    bb-alone = { exec = \"bin/busybox\"; stdio = true; joinNetwork = false; };
    bb-win   = { exec = \"bin/busybox\"; display = true; };
  };
}"

if ! app=$(nix build "${NIX_FLAGS[@]}" --impure --no-link --print-out-paths \
             --expr "$(nix_expr "$expr")" 2>"$SCRATCH/logs/app-build.log"); then
  tail -30 "$SCRATCH/logs/app-build.log" >&2
  fail "mkApp builds"
  finish
  exit 1
fi
pass "mkApp builds"
note "$app"

check "the app has a command per entry" \
  test -x "$app/bin/bb" -a -x "$app/bin/bb-alone" -a -x "$app/bin/bb-win"

# --------------------------------------------------------------- identity

check_out "it runs as the invoking user (keep-id), not root or a stranger" "$uid" \
  "$app/bin/bb" id -u

check_err "it runs in a root filesystem the container cannot change" "Read-only file system" \
  "$app/bin/bb" touch /probe-write

check_out "placeholders in env are the user's" "PROBE_HOME=$home" \
  "$app/bin/bb" env

# ----------------------------------------------------------------- the home

check_out "a non-hidden folder of the home directory is visible" "note.txt" \
  "$app/bin/bb" ls "$home/Docs"

check_out "so is a loose non-hidden file" "loose.txt" \
  "$app/bin/bb" ls -A "$home"

listing=$("$app/bin/bb" ls -A "$home" 2>&1 || true)
if printf '%s\n' "$listing" | grep -qE '^\.(secret|ssh)$'; then
  printf '%s\n' "$listing" >"$OUTFILE"
  fail "hidden entries of the home directory are not visible"
else
  pass "hidden entries of the home directory are not visible"
fi

# What the app keeps is its own, and it survives the container.
check "the app can write to its own config directory" \
  "$app/bin/bb" sh -c "echo kept >\"$home/.config/probe\""
check_out "and finds it again in a new container" "kept" \
  "$app/bin/bb" cat "$home/.config/probe"
check_out "the host's copy is under ~/.var/app, not the host's own ~/.config" "kept" \
  cat "$home/.var/app/probe/config/probe"
check_fails "the host's own ~/.config is not touched" test -e "$home/.config"

# --------------------------------------------------------- hostile content

# A file name containing a comma would, unchecked, add mount options. It must
# stop the launch instead of being bound.
evil="$home/x,bind-propagation=shared"
: >"$evil"
check_err "a file name that would inject a mount option is refused" "refusing to bind" \
  "$app/bin/bb" true
rm -f "$evil"

# A link to nowhere would make podman refuse every mount at once.
ln -s /nonexistent/target "$home/dangling"
check "a dangling link in the home directory does not stop the app" "$app/bin/bb" true
rm -f "$home/dangling"

# ------------------------------------------------------------- the network

# The entries of one app share one network namespace and its loopback.
# shellcheck disable=SC2016
( "$app/bin/bb" sh -c 'echo from-the-server | nc -l -p 7777 -s 127.0.0.1' \
    >"$SCRATCH/logs/nc-server.out" 2>&1 & )
sleep 3

check_out "a second entry reaches the first one's loopback port" "from-the-server" \
  "$app/bin/bb" nc -w 3 127.0.0.1 7777

( "$app/bin/bb" sh -c 'echo again | nc -l -p 7778 -s 127.0.0.1' >/dev/null 2>&1 & )
sleep 2
check_fails "the host cannot reach that port" \
  bash -c 'exec 3<>/dev/tcp/127.0.0.1/7778'

( "$app/bin/bb" sh -c 'echo once-more | nc -l -p 7779 -s 127.0.0.1' >/dev/null 2>&1 & )
sleep 2
check_fails "an entry with its own namespace does not see it" \
  "$app/bin/bb-alone" nc -w 2 127.0.0.1 7779

# ----------------------------------------------------------------- windows

check_err "a windowed entry refuses to start without a compositor" "no Wayland compositor" \
  env -u WAYLAND_DISPLAY XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" "$app/bin/bb-win" true

# ---------------------------------------------------------------- cleanup

podman rm -f -t0 --depend apptest-probe-net >/dev/null 2>&1 || true
check_fails "the holder is gone after cleanup" \
  podman container exists apptest-probe-net

finish
