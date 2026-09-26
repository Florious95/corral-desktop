#!/bin/bash
# Read-only production identity snapshots shared by the fixture start/verify scripts.
GW_TEST_HOME=/tmp/corral-gw-test-home
GW_PIDFILE="$GW_TEST_HOME/daemon-9919.pid"
GW_SOCKET_NAME=test-corral-gw-9919
GW_SOCKET_DIR="$GW_TEST_HOME/tmux-$(id -u)"
GW_SOCKET="$GW_SOCKET_DIR/$GW_SOCKET_NAME"
GW_PROD_PID=87692
GW_CLIENT_PIDS=(72646 90213)

_gw_hash_text() { printf '%s' "${1-}" | shasum -a 256 | awk '{print $1}'; }
_gw_listener_pids() { lsof -nP -t -iTCP:9900 -sTCP:LISTEN 2>/dev/null | LC_ALL=C sort -u || true; }
_gw_established() { lsof -F pfnT -nP -iTCP:9900 -sTCP:ESTABLISHED 2>/dev/null | LC_ALL=C sort -u || true; }
_gw_socket_tmux_pids() {
  local canonical
  canonical="$(realpath "$1" 2>/dev/null)" || return 0
  LC_ALL=C lsof -nP -U 2>/dev/null | LC_ALL=C awk -v path="$canonical" '$1 == "tmux" && index($0, path) { print $2 }' | LC_ALL=C sort -u || true
}
_gw_process_identity() {
  local pid="$1" start images target=0 digest
  start="$(ps -p "$pid" -o lstart= 2>/dev/null | awk '{$1=$1; print}')"
  if [[ -z "$start" ]]; then printf 'absent|-|-|0'; return; fi
  images="$(lsof -nP -a -p "$pid" -d txt -Fn 2>/dev/null | awk '/^n\// {print substr($0,2)}' | LC_ALL=C sort -u || true)"
  [[ "$images" == *'/Applications/Corral.app/'* ]] && target=1
  digest="$(_gw_hash_text "$images")"
  printf 'present|%s|%s|%s' "$start" "$digest" "$target"
}
_gw_capture_prod_snapshot() {
  local out="$1" listeners connections count server client
  listeners="$(_gw_listener_pids)"
  [[ "$listeners" == "$GW_PROD_PID" ]] || { printf 'REFUSED: production 9900 listener PID is %s (expected %s)\n' "${listeners:-none}" "$GW_PROD_PID" >&2; return 1; }
  server="$(_gw_process_identity "$GW_PROD_PID")"
  [[ "$server" == present\|* ]] || { printf 'REFUSED: production PID %s is not live\n' "$GW_PROD_PID" >&2; return 1; }
  connections="$(_gw_established)"
  count="$(printf '%s\n' "$connections" | awk '/^n/ {n++} END {print n+0}')"
  {
    printf 'schema_version=1\n'
    printf 'captured_at_utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'port_9900_listen_pids=%s\n' "$listeners"
    printf 'port_9900_listener_identity=%s\n' "$server"
    printf 'port_9900_established_count=%s\n' "$count"
    printf 'port_9900_established_sha256=%s\n' "$(_gw_hash_text "$connections")"
    for pid in "${GW_CLIENT_PIDS[@]}"; do
      client="$(_gw_process_identity "$pid")"
      printf 'client_%s_identity=%s\n' "$pid" "$client"
    done
  } > "$out"
}
_gw_receipt_value() { awk -F= -v key="$1" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$2"; }
_gw_die() { printf 'REFUSED: %s\n' "$*" >&2; exit 1; }

umask 077
