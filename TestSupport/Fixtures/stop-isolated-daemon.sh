#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
source "$SCRIPT_DIR/isolation-common.sh"
DAEMON="$SCRIPT_DIR/bin/agentmirrord"
TMUX_BIN=/opt/homebrew/bin/tmux
FIXTURE_AGENT="$GW_TEST_HOME/codex"
[[ -r "$GW_PIDFILE" ]] || _gw_die "no owned daemon PID receipt at $GW_PIDFILE; refusing broad process search"
PID="$(<"$GW_PIDFILE")"
[[ "$PID" =~ ^[0-9]+$ ]] || _gw_die 'daemon PID receipt is not numeric'

pid_start() { ps -p "$1" -o lstart= 2>/dev/null | awk '{$1=$1; print}' || true; }
exact_daemon() {
  [[ "$(pid_start "$PID")" == "$(<"$GW_TEST_HOME/daemon-9919.start")" ]] &&
    lsof -nP -a -p "$PID" -d txt -Fn 2>/dev/null | grep -Fx "n$DAEMON" >/dev/null
}
if [[ -n "$(pid_start "$PID")" ]]; then
  [[ -r "$GW_TEST_HOME/daemon-9919.start" ]] || _gw_die 'missing daemon start-time receipt; not signaling PID'
  exact_daemon || _gw_die "PID $PID no longer matches the recorded fixture daemon; not signaling"
  kill -TERM "$PID"
  stopped=0
  for _ in {1..50}; do
    if [[ -z "$(pid_start "$PID")" ]]; then stopped=1; break; fi
    exact_daemon || _gw_die "PID $PID identity changed while waiting; not sending another signal"
    sleep 0.2
  done
  if [[ "$stopped" == 0 ]]; then
    exact_daemon || _gw_die "PID $PID identity changed; refusing SIGKILL"
    kill -KILL "$PID"
    for _ in {1..25}; do [[ -z "$(pid_start "$PID")" ]] && { stopped=1; break; }; sleep 0.2; done
  fi
  [[ "$stopped" == 1 ]] || _gw_die "fixture daemon PID $PID did not exit"
fi

# Stop only the tmux server bound to the recorded private socket/inode.
if [[ -S "$GW_SOCKET" ]]; then
  [[ -r "$GW_TEST_HOME/socket-identity" && -r "$GW_TEST_HOME/tmux-server.pid" ]] || _gw_die 'socket lacks its ownership receipt; refusing to touch it'
  [[ "$(stat -f '%d:%i' "$GW_SOCKET")" == "$(<"$GW_TEST_HOME/socket-identity")" ]] || _gw_die 'isolated tmux socket inode changed; refusing to touch it'
  tmux_pid="$(<"$GW_TEST_HOME/tmux-server.pid")"
  [[ "$tmux_pid" =~ ^[0-9]+$ ]] || _gw_die 'tmux PID receipt is not numeric'
  socket_owners="$(_gw_socket_tmux_pids "$GW_SOCKET")"
  [[ "$socket_owners" == "$tmux_pid" ]] || _gw_die "socket owner is ${socket_owners:-none}, expected recorded tmux PID $tmux_pid"
  env -i PATH=/usr/bin:/bin:/opt/homebrew/bin HOME="$GW_TEST_HOME/home" TMPDIR="$GW_TEST_HOME/tmp" TMUX_TMPDIR="$GW_TEST_HOME" "$TMUX_BIN" -L "$GW_SOCKET_NAME" kill-server
  for _ in {1..50}; do [[ -z "$(_gw_socket_tmux_pids "$GW_SOCKET")" ]] && break; sleep 0.2; done
  [[ -z "$(_gw_socket_tmux_pids "$GW_SOCKET")" ]] || _gw_die 'isolated tmux server still owns the recorded socket'
  if [[ -S "$GW_SOCKET" ]]; then
    [[ "$(stat -f '%d:%i' "$GW_SOCKET")" == "$(<"$GW_TEST_HOME/socket-identity")" ]] || _gw_die 'stale socket inode changed; refusing to unlink it'
    rm -f "$GW_SOCKET"
  fi
fi

# A pane process that survived tmux shutdown is signaled only if it is still the exact fixture executable.
if [[ -r "$GW_TEST_HOME/fixture-processes.tsv" ]]; then
  while IFS='|' read -r child child_start; do
    [[ "$child" =~ ^[0-9]+$ && -n "$child_start" ]] || continue
    current_start="$(pid_start "$child")"
    [[ -n "$current_start" ]] || continue
    [[ "$current_start" == "$child_start" ]] || _gw_die "fixture child PID $child identity changed; refusing to signal"
    if lsof -nP -a -p "$child" -d txt -Fn 2>/dev/null | grep -Fx "n$FIXTURE_AGENT" >/dev/null; then
      kill -TERM "$child"
      for _ in {1..25}; do [[ -z "$(pid_start "$child")" ]] && break; sleep 0.2; done
      if [[ -n "$(pid_start "$child")" ]]; then
        [[ "$(pid_start "$child")" == "$child_start" ]] && lsof -nP -a -p "$child" -d txt -Fn 2>/dev/null | grep -Fx "n$FIXTURE_AGENT" >/dev/null || _gw_die "fixture child PID $child identity changed; refusing SIGKILL"
        kill -KILL "$child"
      fi
    fi
  done < "$GW_TEST_HOME/fixture-processes.tsv"
fi
state_pidfile="$GW_TEST_HOME/state/agentmirrord.pid"
if [[ -e "$state_pidfile" ]]; then
  [[ -r "$state_pidfile" && "$(<"$state_pidfile")" == "$PID" && -z "$(pid_start "$PID")" ]] || _gw_die 'internal daemon pidfile does not match the stopped receipt; refusing to remove it'
  rm -f "$state_pidfile"
fi
[[ -z "$(lsof -nP -t -iTCP:9919 -sTCP:LISTEN 2>/dev/null || true)" ]] || _gw_die 'a listener remains on the isolated 9919 port'
[[ -z "$(_gw_socket_tmux_pids "$GW_SOCKET")" ]] || _gw_die 'a process still owns the isolated tmux socket'

# Delete only known fixture runtime files; preserve receipts under the fixture repository.
rm -f "$GW_PIDFILE" "$GW_TEST_HOME/daemon-9919.start" "$GW_TEST_HOME/tmux-server.pid" \
  "$GW_TEST_HOME/socket-identity" "$GW_TEST_HOME/fixture-processes.tsv" "$GW_TEST_HOME/isolation-before.tsv" \
  "$GW_TEST_HOME/isolation-after.tsv" "$GW_TEST_HOME/isolation-run-id" "$GW_TEST_HOME/test-token" \
  "$GW_TEST_HOME/daemon.log" "$GW_TEST_HOME/nodeprobe-report.json" "$GW_TEST_HOME/codex"
printf 'Stopped only recorded fixture daemon PID %s; isolated tmux socket and port 9919 are clear.\n' "$PID"
