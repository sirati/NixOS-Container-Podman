#!/usr/bin/env bash
#
# Every flag `develop` accepts.
#
# The first check is the one that keeps this file honest: it reads the
# flags out of the argument loop in dispatch.nix and fails if any of them
# is not named below, either as covered or as explicitly skipped. A flag
# added later cannot quietly go untested, and a flag skipped here says so
# in the run output rather than simply being absent from it.

# shellcheck source=../lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"

# Flags this file exercises against a running session.
COVERED=(
  -A --forward-agent --agent --agent-allow --agent-deny
  --git-serve --mount-bashrc --mount-gitconfig --translate-gitconfig
  --native --no-native -S --socket --template --env --share
  --host-port -c --command -D --develop-arg
)
# Flags that need something this machine may not have. Each is attempted
# when the host offers it and reported as a skip, with the reason, when it
# does not -- never silently dropped.
CONDITIONAL=( --x11 --x11-untrusted --wayland --wprs --dbus )

echo "== every develop flag is accounted for =="

declared=$(printf '%s\n' "${COVERED[@]}" "${CONDITIONAL[@]}" | sort -u)
parsed=$(awk '/^    develop\)/{d=1} d&&/^          --\) shift; break ;;/{exit} d' \
           "$REPO/nix/scripts/run/dispatch.nix" \
         | grep -oE '^ +-{1,2}[A-Za-z0-9-]+(\|-{1,2}[A-Za-z0-9-]+)*\)' \
         | tr -d ' )' | tr '|' '\n' | sort -u)
if [ "$declared" = "$parsed" ]; then
  pass "every flag develop parses is named here ($(printf '%s\n' "$parsed" | wc -l) of them)"
else
  diff <(printf '%s\n' "$declared") <(printf '%s\n' "$parsed") >"$OUTFILE" 2>&1 || true
  fail "develop parses flags this file does not name (< declared, > parsed)"
fi

# ------------------------------------------------------------------------

ct_new devopts nixct
check "up" ct up

# Each check gets its own project path, because a session is keyed by that
# path and its forwards belong to the session rather than to the shell that
# asked for them: sharing one path between checks would let one check's
# forward decide another's result.
proj() {
  local name=$1
  local dir="$SCRATCH/proj-$name"
  mk_project_flake "$dir" >/dev/null
  printf '%s' "$dir"
}

# The per-session socket directory is named after the project path, with
# "-" doubled and "/" turned into "-". Recomputing it here rather than
# globbing for it is not pedantry: /run/sockets/<ns> is traversable but not
# listable by the session user, so a glob finds nothing while an exact path
# works -- which is the confinement doing its job.
ns_of() {
  local ns=${1#/}
  ns=${ns//-/--}
  printf '%s' "${ns//\//-}"
}

# devrun <proj> <command> [flags...]
devrun() {
  local p=$1 cmd=$2; shift 2
  timeout 900 env NAME="$CT_NAME" STATE_DIR="$CT_STATE" \
    "$CT_RUN" develop "$@" --command "$cmd" "$p"
}

# Not every tool a check needs is in the container's system profile.
in_container() {
  ct exec -- /run/current-system/sw/bin/test -x "/run/current-system/sw/bin/$1" 2>/dev/null
}

pids=()
cleanup_helpers() {
  local p
  for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null || true; done
}
trap cleanup_helpers EXIT

echo "== the session environment =="

# shellcheck disable=SC2016 # expanded in the session, not here
check_out "--env sets a variable in the session" "got=from-flag" \
  devrun "$(proj env)" 'echo "got=$NIXCT_TEST_ENV"' --env NIXCT_TEST_ENV=from-flag

# shellcheck disable=SC2016
check_out "-D passes an argument through to nix develop" "impure-ok" \
  devrun "$(proj devarg)" 'echo impure-ok' -D --impure

echo "== host directories in the session =="

share_dir="$SCRATCH/share-rw"; mkdir -p "$share_dir"
# shellcheck disable=SC2016
check "--share hands the session the real directory (writes reach the host)" \
  devrun "$(proj share)" 'echo written > "$HOME/shared/from-session"' \
    --share "$share_dir:shared:rw"
check "and the host sees what the session wrote" \
  test -f "$share_dir/from-session"

share_ro="$SCRATCH/share-ro"; mkdir -p "$share_ro"; : >"$share_ro/readable"
# shellcheck disable=SC2016
check "--share :ro is readable in the session" \
  devrun "$(proj sharero)" 'test -f "$HOME/shared-ro/readable"' \
    --share "$share_ro:shared-ro:ro"
# shellcheck disable=SC2016
check_fails "--share :ro cannot be written from the session" \
  devrun "$(proj sharerow)" 'touch "$HOME/shared-ro/nope"' \
    --share "$share_ro:shared-ro:ro"
check "and nothing appeared on the host" test '!' -e "$share_ro/nope"

tpl_dir="$SCRATCH/template"; mkdir -p "$tpl_dir"; echo template-marker >"$tpl_dir/marker"
# shellcheck disable=SC2016
check_out "--template gives the session the host content" "template-marker" \
  devrun "$(proj template)" 'cat "$HOME/tpl/marker"' --template "$tpl_dir:tpl"
# shellcheck disable=SC2016
check "--template is writable inside the session" \
  devrun "$(proj templatew)" 'echo added > "$HOME/tpl/added"' --template "$tpl_dir:tpl"
check "but the write does not reach the host (it is frozen)" \
  test '!' -e "$tpl_dir/added"

echo "== the project bind =="

# --native binds the project directly; the default puts bindfs in between,
# which is the difference the two flags exist for.
# shellcheck disable=SC2016
check_out "the default project bind goes through bindfs" "bindfs" \
  devrun "$(proj bindfs)" 'grep " $HOME/dev " /proc/self/mounts' --no-native
# shellcheck disable=SC2016
check_fails "--native binds the project directly, without bindfs" \
  devrun "$(proj native)" 'grep " $HOME/dev " /proc/self/mounts | grep -q bindfs' --native

echo "== forwards =="

port=$((20000 + RANDOM % 20000))
nix shell nixpkgs#python3 --command python3 -c "
import socketserver
class H(socketserver.StreamRequestHandler):
    def handle(self): self.wfile.write(b'nixct-host-port-ok\n')
socketserver.TCPServer.allow_reuse_address = True
socketserver.TCPServer(('127.0.0.1', $port), H).serve_forever()
" >/dev/null 2>&1 &
pids+=($!)
# A failing forward and a failing test listener look identical from inside
# the session, so establish which one is being tested before testing it.
check_out "the host listener the next check needs is up" "nixct-host-port-ok" \
  bash -c "for i in 1 2 3 4 5 6 7 8 9 10; do
             exec 3<>/dev/tcp/127.0.0.1/$port 2>/dev/null && { head -1 <&3; exit 0; }
             sleep 0.5
           done; exit 1"
# shellcheck disable=SC2016
check_out "--host-port reaches a host loopback service from the session" \
  "nixct-host-port-ok" \
  devrun "$(proj hostport)" \
    "exec 3<>/dev/tcp/127.0.0.1/$port; head -1 <&3" --host-port "$port"

sockpath="$SCRATCH/generic.sock"
nix shell nixpkgs#python3 --command python3 -c "
import socket, os
s = socket.socket(socket.AF_UNIX); s.bind('$sockpath'); s.listen(4)
while True:
    c, _ = s.accept(); c.sendall(b'nixct-socket-ok\n'); c.close()
" >/dev/null 2>&1 &
pids+=($!)
sockproj=$(proj socket)
check_out "-S forwards a generic unix socket into the session" "GENERIC-IS-SOCKET" \
  devrun "$sockproj" \
    "test -S /run/sockets/$(ns_of "$sockproj")/generic && echo GENERIC-IS-SOCKET" \
    -S generic="$sockpath"

echo "== the ssh agent =="

if ! command -v ssh-agent >/dev/null || ! command -v ssh-keygen >/dev/null; then
  skip "-A / --agent / --agent-allow / --agent-deny" "no ssh-agent on the host"
elif ! in_container ssh-add; then
  skip "-A / --agent / --agent-allow / --agent-deny" "no ssh-add in the container"
else
  agent_dir="$SCRATCH/agent"; mkdir -p "$agent_dir"; chmod 700 "$agent_dir"
  ssh-keygen -q -t ed25519 -N "" -C nixct-test-key-one -f "$agent_dir/one" </dev/null
  ssh-keygen -q -t ed25519 -N "" -C nixct-test-key-two -f "$agent_dir/two" </dev/null
  eval "$(ssh-agent -s -a "$agent_dir/agent.sock")" >/dev/null
  pids+=("${SSH_AGENT_PID:-}")
  SSH_AUTH_SOCK="$agent_dir/agent.sock" ssh-add "$agent_dir/one" "$agent_dir/two" 2>/dev/null

  check_out "-A forwards the host agent (SSH_AUTH_SOCK from the environment)" \
    "nixct-test-key-one" \
    env SSH_AUTH_SOCK="$agent_dir/agent.sock" NAME="$CT_NAME" STATE_DIR="$CT_STATE" \
      timeout 900 "$CT_RUN" develop -A --command 'ssh-add -l' "$(proj agent)"

  check_out "--agent takes the socket path explicitly" "nixct-test-key-two" \
    devrun "$(proj agentpath)" 'ssh-add -l' --agent "$agent_dir/agent.sock"

  # The filter is the point of forwarding an agent into a container at all:
  # what reaches the session must be a subset of what the host agent holds.
  check_out "--agent-allow exposes only the named key" "nixct-test-key-one" \
    devrun "$(proj agentallow)" 'ssh-add -l' \
      --agent "$agent_dir/agent.sock" --agent-allow nixct-test-key-one
  check_fails "--agent-allow hides the key it did not name" \
    bash -c "grep -q nixct-test-key-two '$OUTFILE'"

  check_out "--agent-deny drops the named key and keeps the rest" \
    "nixct-test-key-two" \
    devrun "$(proj agentdeny)" 'ssh-add -l' \
      --agent "$agent_dir/agent.sock" --agent-deny nixct-test-key-one
  check_fails "--agent-deny really removed the denied key" \
    bash -c "grep -q nixct-test-key-one '$OUTFILE'"
fi

echo "== the host's own configuration =="

if [ -f "$HOME/.bashrc" ]; then
  # shellcheck disable=SC2016
  check "--mount-bashrc puts the host bashrc in the session HOME" \
    devrun "$(proj bashrc)" 'test -f "$HOME/.bashrc"' --mount-bashrc
else
  skip "--mount-bashrc" "the host has no ~/.bashrc"
fi

# The git config the flags copy is the one at $XDG_CONFIG_HOME/git/config,
# and that variable points into the scratch dir -- so the suite writes the
# config it expects to find rather than depending on the user having one,
# and can then assert the CONTENT arrived instead of just a file.
mkdir -p "$XDG_CONFIG_HOME/git"
cat >"$XDG_CONFIG_HOME/git/config" <<'GITCFG'
[user]
    name = nixct-test-user
    email = nixct-test@example.invalid
GITCFG
check_out "--mount-gitconfig brings the host git config into the session" \
  "nixct-test-user" \
  devrun "$(proj gitconfig)" 'git config --get user.name' --mount-gitconfig
check_out "--translate-gitconfig produces a config git can read" \
  "nixct-test-user" \
  devrun "$(proj gitxlate)" 'git config --get user.name' --translate-gitconfig

echo "== git-serve =="

if ! in_container git; then
  skip "--git-serve" "no git in the container"
else
  gitproj="$SCRATCH/proj-gitserve"
  mk_project_flake "$gitproj" >/dev/null
  git -C "$gitproj" init -q -b main
  git -C "$gitproj" -c user.email=t@example.invalid -c user.name=test add -A
  git -C "$gitproj" -c user.email=t@example.invalid -c user.name=test commit -qm init
  # The session gets a clone served over git://127.0.0.1, not the working
  # tree itself -- so what it can reach is a remote, not the host directory.
  # shellcheck disable=SC2016 # expanded in the session
  check_out "--git-serve gives the session a clone with a git:// remote" "git://" \
    devrun "$gitproj" 'git -C "$HOME/dev" remote -v' --git-serve main
fi

echo "== forwards that need a display =="

if [ -n "${DISPLAY:-}" ]; then
  # shellcheck disable=SC2016
  check_out "--x11 sets DISPLAY in the session" ":" \
    devrun "$(proj x11)" 'echo "display=$DISPLAY"' --x11
  # shellcheck disable=SC2016
  check_out "--x11-untrusted sets DISPLAY in the session" ":" \
    devrun "$(proj x11u)" 'echo "display=$DISPLAY"' --x11-untrusted
else
  skip "--x11 / --x11-untrusted" "no DISPLAY on the host"
fi

if [ -n "${WAYLAND_DISPLAY:-}" ]; then
  # shellcheck disable=SC2016
  check_out "--wayland sets WAYLAND_DISPLAY in the session" "wayland" \
    devrun "$(proj wl)" 'echo "wl=$WAYLAND_DISPLAY"' --wayland
  if command -v wprsd >/dev/null; then
    # shellcheck disable=SC2016 # expanded in the session
    check "--wprs starts a proxied compositor for the session" \
      devrun "$(proj wprs)" 'test -n "$WAYLAND_DISPLAY"' --wprs
  else
    skip "--wprs" "no wprsd on the host"
  fi
else
  skip "--wayland / --wprs" "no WAYLAND_DISPLAY on the host"
fi

if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  # shellcheck disable=SC2016
  check_out "--dbus sets DBUS_SESSION_BUS_ADDRESS in the session" "unix:" \
    devrun "$(proj dbus)" 'echo "bus=$DBUS_SESSION_BUS_ADDRESS"' --dbus
else
  skip "--dbus" "no session bus on the host"
fi

check "down" ct down --force
check "purge" ct purge --force

finish
