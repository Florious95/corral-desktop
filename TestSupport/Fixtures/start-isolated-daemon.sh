#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
source "$SCRIPT_DIR/isolation-common.sh"
DAEMON="$SCRIPT_DIR/bin/agentmirrord"
NODEPROBE_DIR="$SCRIPT_DIR/runtime/nodeprobe"
TOKEN_FILE="$GW_TEST_HOME/test-token"
BASELINE="$GW_TEST_HOME/isolation-before.tsv"
RUN_FILE="$GW_TEST_HOME/isolation-run-id"
TMUX_BIN=/opt/homebrew/bin/tmux
FIXTURE_AGENT="$GW_TEST_HOME/codex"
started_tmux=0
started_daemon=0
preflight_passed=0
stage=preflight
succeeded=0
daemon_pid=''

cleanup_failed_start() {
  local status=$?
  if [[ "$succeeded" == 1 || "$status" == 0 ]]; then return; fi
  if [[ "$started_daemon" == 1 && -n "$daemon_pid" && -r "$GW_PIDFILE" && "$(<"$GW_PIDFILE")" == "$daemon_pid" ]]; then
    if lsof -nP -a -p "$daemon_pid" -d txt -Fn 2>/dev/null | grep -Fx "n$DAEMON" >/dev/null; then
      kill -TERM "$daemon_pid" 2>/dev/null || true
      for _ in {1..25}; do [[ -z "$(ps -p "$daemon_pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}' || true)" ]] && break; sleep 0.2; done
    fi
    if [[ -r "$GW_TEST_HOME/state/agentmirrord.pid" && "$(<"$GW_TEST_HOME/state/agentmirrord.pid")" == "$daemon_pid" && -z "$(ps -p "$daemon_pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}' || true)" ]]; then rm -f "$GW_TEST_HOME/state/agentmirrord.pid"; fi
  fi
  if [[ "$started_tmux" == 1 && -S "$GW_SOCKET" ]]; then
    env -i PATH=/usr/bin:/bin:/opt/homebrew/bin HOME="$GW_TEST_HOME/home" TMPDIR="$GW_TEST_HOME/tmp" TMUX_TMPDIR="$GW_TEST_HOME" "$TMUX_BIN" -L "$GW_SOCKET_NAME" kill-server >/dev/null 2>&1 || true
    for _ in {1..25}; do [[ -z "$(_gw_socket_tmux_pids "$GW_SOCKET")" ]] && break; sleep 0.2; done
    if [[ -S "$GW_SOCKET" && -r "$GW_TEST_HOME/socket-identity" && "$(stat -f '%d:%i' "$GW_SOCKET")" == "$(<"$GW_TEST_HOME/socket-identity")" && -z "$(_gw_socket_tmux_pids "$GW_SOCKET")" ]]; then rm -f "$GW_SOCKET"; fi
  fi
  if [[ -n "$daemon_pid" && -r "$GW_PIDFILE" && "$(<"$GW_PIDFILE")" == "$daemon_pid" ]]; then rm -f "$GW_PIDFILE"; fi
  if [[ "$preflight_passed" == 1 ]]; then
    rm -f "$TOKEN_FILE" "$BASELINE" "$RUN_FILE" "$GW_TEST_HOME/daemon-9919.start" "$GW_TEST_HOME/tmux-server.pid" "$GW_TEST_HOME/socket-identity" "$GW_TEST_HOME/fixture-processes.tsv" "$GW_TEST_HOME/daemon.log" "$FIXTURE_AGENT"
  fi
}
trap 'rc=$?; printf "Fixture startup failed at stage %s (exit %s).\n" "$stage" "$rc" >&2' ERR
trap cleanup_failed_start EXIT

[[ "$(shasum -a 256 "$DAEMON" | awk '{print $1}')" == 00b0534278f6b0a4e4b569151dcc2782f7cc9bf6dd9b97d84c8e86bf87411f96 ]] || _gw_die 'agentmirrord copy hash changed'
[[ "$(shasum -a 256 "$NODEPROBE_DIR/nodeprobe" | awk '{print $1}')" == 57073fd42d7bdcfbd339687c09531d01aaaa02e02271257a5dd2a9ce72ffb2a3 ]] || _gw_die 'nodeprobe hash mismatch'
[[ "$(shasum -a 256 "$NODEPROBE_DIR/titles.tsv" | awk '{print $1}')" == cff45d25492fdfe9689330c630c80bad20a1f27243e5aae1d93bc57de0a22b58 ]] || _gw_die 'titles corpus hash mismatch'
[[ "$(shasum -a 256 "$NODEPROBE_DIR/providers.tsv" | awk '{print $1}')" == c9e02d01821df7d7afe2292fefb211cefea7e3abecde8b35bd9ffa2a0721ee7e ]] || _gw_die 'providers corpus hash mismatch'
[[ "$(shasum -a 256 "$NODEPROBE_DIR/nodeprobe-pi-activity.js" | awk '{print $1}')" == c28855ea4ac6f411044fb9a8066c2e5c3e5580197c1ae412e88d23d07467b714 ]] || _gw_die 'nodeprobe extension hash mismatch'
[[ -x "$NODEPROBE_DIR/tmux" && "$(shasum -a 256 "$NODEPROBE_DIR/tmux" | awk '{print $1}')" == dc44c4c11d0950435326d1735e432914fdc8fbec34a5d3368b4911b781688fe0 ]] || _gw_die 'tmux isolation shim hash mismatch'
[[ -x "$TMUX_BIN" && -x /usr/bin/clang ]] || _gw_die 'required tmux/clang tool is unavailable'
[[ ! -L "$GW_TEST_HOME" ]] || _gw_die "$GW_TEST_HOME must not be a symlink"
if [[ -e "$GW_TEST_HOME" ]]; then
  [[ "$(stat -f '%Su' "$GW_TEST_HOME")" == "$(id -un)" && "$(stat -f '%Lp' "$GW_TEST_HOME")" == 700 ]] || _gw_die "$GW_TEST_HOME must be owned by this user with mode 700"
fi
[[ ! -e "$GW_PIDFILE" ]] || _gw_die "existing PID receipt at $GW_PIDFILE; inspect/stop the prior fixture run first"
[[ ! -e "$TOKEN_FILE" && ! -e "$BASELINE" && ! -e "$RUN_FILE" && ! -e "$GW_TEST_HOME/isolation-after.tsv" && ! -e "$GW_TEST_HOME/daemon.log" && ! -e "$GW_TEST_HOME/nodeprobe-report.json" && ! -e "$GW_TEST_HOME/codex" && ! -e "$GW_TEST_HOME/state/agentmirrord.pid" ]] || _gw_die 'existing fixture runtime state found; refusing to overwrite'
for stale in "$GW_TEST_HOME/daemon-9919.start" "$GW_TEST_HOME/tmux-server.pid" "$GW_TEST_HOME/socket-identity" "$GW_TEST_HOME/fixture-processes.tsv"; do [[ ! -e "$stale" ]] || _gw_die "existing runtime receipt $stale; refusing to overwrite"; done
[[ -z "$(lsof -nP -t -iTCP:9919 -sTCP:LISTEN 2>/dev/null || true)" ]] || _gw_die 'port 9919 already has a listener; refusing to contact or stop it'
preflight_passed=1
mkdir -m 700 -p "$GW_TEST_HOME/home" "$GW_TEST_HOME/tmp" "$GW_TEST_HOME/state" "$GW_TEST_HOME/corpus" "$GW_SOCKET_DIR"
stage=production-baseline
_gw_capture_prod_snapshot "$BASELINE"

# Build a tiny, deterministic pane process named "codex"; it emits only fixture bytes.
stage=fixture-process-build
/usr/bin/clang -Os -o "$FIXTURE_AGENT" "$SCRIPT_DIR/runtime/fixture-agent.c"
chmod 700 "$FIXTURE_AGENT"
openssl rand -hex 32 > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

TMUX=(env -i PATH="$NODEPROBE_DIR:/usr/bin:/bin:/opt/homebrew/bin" HOME="$GW_TEST_HOME/home" TMPDIR="$GW_TEST_HOME/tmp" TMUX_TMPDIR="$GW_TEST_HOME" TERM=xterm-256color "$TMUX_BIN" -L "$GW_SOCKET_NAME")
[[ ! -e "$GW_SOCKET" ]] || _gw_die "isolated tmux socket already exists: $GW_SOCKET"
stage=tmux-sessions
"${TMUX[@]}" new-session -d -s static-long-text -c "$GW_TEST_HOME" "$FIXTURE_AGENT" static
started_tmux=1
[[ -S "$GW_SOCKET" ]] || _gw_die 'tmux did not create the expected isolated socket'
printf '%s\n' "$(stat -f '%d:%i' "$GW_SOCKET")" > "$GW_TEST_HOME/socket-identity"
"${TMUX[@]}" select-pane -T fixture-static-long-text -t static-long-text:0.0
"${TMUX[@]}" new-session -d -s ansi-color -c "$GW_TEST_HOME" "$FIXTURE_AGENT" ansi
"${TMUX[@]}" select-pane -T fixture-ansi-color -t ansi-color:0.0
"${TMUX[@]}" new-session -d -s cjk-emoji -c "$GW_TEST_HOME" "$FIXTURE_AGENT" unicode
"${TMUX[@]}" select-pane -T fixture-cjk-emoji -t cjk-emoji:0.0
"${TMUX[@]}" new-session -d -s streaming-output -c "$GW_TEST_HOME" "$FIXTURE_AGENT" stream
"${TMUX[@]}" select-pane -T fixture-streaming-output -t streaming-output:0.0
"${TMUX[@]}" new-session -d -s split-workspace -c "$GW_TEST_HOME" "$FIXTURE_AGENT" split-left
"${TMUX[@]}" split-window -v -t split-workspace -c "$GW_TEST_HOME" "$FIXTURE_AGENT" split-right
"${TMUX[@]}" select-pane -T fixture-split-left -t split-workspace:0.0
"${TMUX[@]}" select-pane -T fixture-split-right -t split-workspace:0.1
"${TMUX[@]}" set-option -g status off

[[ -S "$GW_SOCKET" ]] || _gw_die 'tmux did not create the expected isolated socket'
printf '%s\n' "$(stat -f '%d:%i' "$GW_SOCKET")" > "$GW_TEST_HOME/socket-identity"
stage=tmux-ownership
processes="$GW_TEST_HOME/fixture-processes.tsv"
: > "$processes"
while IFS= read -r pane_pid; do
  pane_start="$(ps -p "$pane_pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}')"
  [[ -n "$pane_start" ]] || _gw_die "cannot identify fixture pane PID $pane_pid"
  printf '%s|%s\n' "$pane_pid" "$pane_start" >> "$processes"
done < <("${TMUX[@]}" list-panes -a -F '#{pane_pid}' | LC_ALL=C sort -nu)
_gw_socket_tmux_pids "$GW_SOCKET" > "$GW_TEST_HOME/tmux-server.pid"
[[ -s "$GW_TEST_HOME/tmux-server.pid" && "$(wc -l < "$GW_TEST_HOME/tmux-server.pid" | awk '{print $1}')" == 1 ]] || _gw_die 'cannot identify one tmux process owning the exact isolated socket'
printf '%s\n' "$(date -u '+%Y%m%dT%H%M%SZ')" > "$RUN_FILE"

stage=daemon-start
unset TOKEN
TOKEN="$(<"$TOKEN_FILE")"
(
  while IFS= read -r name; do unset "$name" 2>/dev/null || true; done < <(compgen -e)
  export PATH="$NODEPROBE_DIR:/usr/bin:/bin:/opt/homebrew/bin"
  export HOME="$GW_TEST_HOME/home" TMPDIR="$GW_TEST_HOME/tmp" TMUX_TMPDIR="$GW_TEST_HOME"
  export AGENTMIRROR_TOKEN="$TOKEN"
  export AGENTMIRROR_NODEPROBE_BIN="$NODEPROBE_DIR/nodeprobe"
  export NODEPROBE_FIXTURES="$NODEPROBE_DIR/titles.tsv" NODEPROBE_PROVIDERS="$NODEPROBE_DIR/providers.tsv"
  export AGENTMIRROR_NODEPROBE_PI_EXTENSION="$NODEPROBE_DIR/nodeprobe-pi-activity.js"
  export AGENTMIRROR_E2E_DISCOVERY_SOCKET_DIRS="$GW_SOCKET_DIR"
  exec "$DAEMON" -listen 127.0.0.1:9919 -state-dir "$GW_TEST_HOME/state"
) > "$GW_TEST_HOME/daemon.log" 2>&1 &
daemon_pid=$!
printf '%s\n' "$daemon_pid" > "$GW_PIDFILE"
chmod 600 "$GW_PIDFILE"
started_daemon=1

stage=daemon-readiness
ready=0
for _ in {1..100}; do
  if ! kill -0 "$daemon_pid" 2>/dev/null; then break; fi
  if [[ "$(lsof -nP -a -p "$daemon_pid" -iTCP:9919 -sTCP:LISTEN -t 2>/dev/null || true)" == "$daemon_pid" ]]; then ready=1; break; fi
  sleep 0.2
done
[[ "$ready" == 1 ]] || { printf 'daemon failed to bind the isolated endpoint; see %s/daemon.log\n' "$GW_TEST_HOME" >&2; exit 1; }
ps -p "$daemon_pid" -o lstart= | awk '{$1=$1; print}' > "$GW_TEST_HOME/daemon-9919.start"
[[ -s "$GW_TEST_HOME/daemon-9919.start" ]] || _gw_die 'could not record daemon process identity'
succeeded=1
printf 'Isolated daemon ready: 127.0.0.1:9919 (PID %s); tmux socket %s; five sessions / six panes.\n' "$daemon_pid" "$GW_SOCKET"
printf 'PID receipt: %s\n' "$GW_PIDFILE"
printf 'Production 9900 baseline captured read-only: %s\n' "$BASELINE"
