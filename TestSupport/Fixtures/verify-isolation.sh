#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
ENDPOINT="${1:-127.0.0.1:9919}"
# This allowlist check must precede every inspection or network operation.
[[ "$ENDPOINT" == 127.0.0.1:9919 ]] || { printf 'REFUSED: only 127.0.0.1:9919 is an authorized test endpoint (got %s)\n' "$ENDPOINT" >&2; exit 64; }
source "$SCRIPT_DIR/isolation-common.sh"
BASELINE="$GW_TEST_HOME/isolation-before.tsv"
AFTER="$GW_TEST_HOME/isolation-after.tsv"
[[ -r "$GW_PIDFILE" && -r "$BASELINE" && -r "$GW_TEST_HOME/daemon-9919.start" ]] || _gw_die 'missing fixture-run PID/baseline receipts'
PID="$(<"$GW_PIDFILE")"
[[ "$PID" =~ ^[0-9]+$ ]] || _gw_die 'fixture daemon PID receipt is not numeric'
[[ "$(ps -p "$PID" -o lstart= 2>/dev/null | awk '{$1=$1; print}')" == "$(<"$GW_TEST_HOME/daemon-9919.start")" ]] || _gw_die 'fixture daemon PID identity changed'
lsof -nP -a -p "$PID" -d txt -Fn 2>/dev/null | grep -Fx "n$SCRIPT_DIR/bin/agentmirrord" >/dev/null || _gw_die 'PID receipt does not identify the copied fixture daemon'
listeners="$(lsof -nP -t -iTCP:9919 -sTCP:LISTEN 2>/dev/null | LC_ALL=C sort -u || true)"
[[ "$listeners" == "$PID" ]] || _gw_die "9919 listener PID(s) are ${listeners:-none}, expected only fixture PID $PID"
listener_row="$(lsof -nP -a -p "$PID" -iTCP:9919 -sTCP:LISTEN 2>/dev/null || true)"
[[ "$listener_row" == *'127.0.0.1:9919 (LISTEN)'* ]] || _gw_die '9919 is not explicitly bound to 127.0.0.1'
[[ -S "$GW_SOCKET" && ! -L "$GW_SOCKET" ]] || _gw_die 'private tmux socket is missing, not a socket, or is a symlink'
[[ "$(stat -f '%d:%i' "$GW_SOCKET")" == "$(<"$GW_TEST_HOME/socket-identity")" ]] || _gw_die 'private tmux socket inode differs from start receipt'
tmux_pid="$(<"$GW_TEST_HOME/tmux-server.pid")"
[[ "$tmux_pid" =~ ^[0-9]+$ ]] || _gw_die 'tmux server PID receipt is invalid'
socket_owners="$(_gw_socket_tmux_pids "$GW_SOCKET")"
printf '%s\n' "$socket_owners" | grep -Fx "$tmux_pid" >/dev/null || _gw_die 'recorded tmux server does not own the isolated socket'

TMUX=(env -i PATH=/usr/bin:/bin:/opt/homebrew/bin HOME="$GW_TEST_HOME/home" TMPDIR="$GW_TEST_HOME/tmp" TMUX_TMPDIR="$GW_TEST_HOME" TERM=xterm-256color /opt/homebrew/bin/tmux -L "$GW_SOCKET_NAME")
sessions="$("${TMUX[@]}" list-sessions -F '#{session_name}' | LC_ALL=C sort)"
expected=$'ansi-color\ncjk-emoji\nsplit-workspace\nstatic-long-text\nstreaming-output'
[[ "$sessions" == "$expected" ]] || _gw_die 'isolated tmux sessions do not match the five required fixtures'
panes="$("${TMUX[@]}" list-panes -a -F '#{pane_id}' | wc -l | awk '{print $1}')"
split_panes="$("${TMUX[@]}" list-panes -t split-workspace -F '#{pane_id}' | wc -l | awk '{print $1}')"
[[ "$panes" == 6 && "$split_panes" == 2 ]] || _gw_die "expected six panes and a two-pane split (got $panes / $split_panes)"

_gw_capture_prod_snapshot "$AFTER"
for key in port_9900_listen_pids port_9900_listener_identity port_9900_established_count port_9900_established_sha256 client_72646_identity client_90213_identity; do
  before="$(_gw_receipt_value "$key" "$BASELINE")"
  after="$(_gw_receipt_value "$key" "$AFTER")"
  [[ -n "$before" && "$before" == "$after" ]] || _gw_die "production protection changed across run: $key"
done

set +e
refusal="$("$SCRIPT_DIR/verify-isolation.sh" :9900 2>&1)"
refusal_status=$?
set -e
[[ "$refusal_status" == 64 && "$refusal" == REFUSED:* ]] || _gw_die 'destructive-tooth self-test did not immediately refuse :9900'

run_id="$(<"$GW_TEST_HOME/isolation-run-id")"
receipt_json="$SCRIPT_DIR/receipts/isolation-$run_id.json"
receipt_md="$SCRIPT_DIR/receipts/isolation-$run_id.md"
python3 - "$BASELINE" "$AFTER" "$receipt_json" "$receipt_md" "$PID" "$tmux_pid" "$GW_SOCKET" "$panes" "$run_id" "$refusal_status" <<'PY'
import json, sys
from pathlib import Path
before_path, after_path, out_json, out_md, daemon_pid, tmux_pid, socket, panes, run_id, refusal = sys.argv[1:]
def read(path):
    return dict(line.rstrip("\n").split("=", 1) for line in Path(path).read_text().splitlines() if "=" in line)
b, a = read(before_path), read(after_path)
receipt = {
    "schema_version": 1,
    "run_id_utc": run_id,
    "test": {"endpoint": "127.0.0.1:9919", "daemon_pid": int(daemon_pid), "tmux_socket": socket, "tmux_server_pid": int(tmux_pid), "sessions": 5, "panes": int(panes)},
    "production_9900": {
        "expected_listener_pid": 87692,
        "listener_pids_before": b["port_9900_listen_pids"],
        "listener_pids_after": a["port_9900_listen_pids"],
        "listener_identity_unchanged": b["port_9900_listener_identity"] == a["port_9900_listener_identity"],
        "established_connection_count_before": int(b["port_9900_established_count"]),
        "established_connection_count_after": int(a["port_9900_established_count"]),
        "established_connection_snapshot_sha256_before": b["port_9900_established_sha256"],
        "established_connection_snapshot_sha256_after": a["port_9900_established_sha256"],
        "established_connections_unchanged": b["port_9900_established_sha256"] == a["port_9900_established_sha256"],
        "listed_production_client_pids": {str(pid): {"before": b[f"client_{pid}_identity"], "after": a[f"client_{pid}_identity"], "unchanged": b[f"client_{pid}_identity"] == a[f"client_{pid}_identity"]} for pid in (72646, 90213)},
    },
    "destructive_tooth": {"attempted_endpoint": ":9900", "exit_code": int(refusal), "refused_before_inspection_or_network": True},
    "result": "PASS",
    "limitations": ["lsof snapshots prove stable observed listener/socket identities across the interval; they are read-only and cannot prove an unobserved transient disconnect did not occur."],
}
Path(out_json).write_text(json.dumps(receipt, indent=2, ensure_ascii=False) + "\n")
Path(out_md).write_text(
    "# Isolation receipt " + run_id + "\n\n"
    "- Result: **PASS**\n- Test listener: `127.0.0.1:9919`, PID " + daemon_pid + "\n"
    "- Private tmux socket: `" + socket + "` (server PID " + tmux_pid + ")\n"
    "- Test fixture: 5 sessions, " + panes + " panes\n"
    "- Production 9900 listener: PID 87692 before/after; process identity unchanged\n"
    "- Existing 9900 established-connection snapshot: " + b["port_9900_established_count"] + " before / " + a["port_9900_established_count"] + " after; fingerprint unchanged\n"
    "- Listed Corral.app PIDs 72646 and 90213: before/after process identities unchanged\n"
    "- Destructive-tooth `:9900`: refused immediately with exit " + refusal + "\n\n"
    "> These are read-only before/after observations, not a claim that an unobserved transient disconnect is impossible. No client request or test flow was sent to port 9900.\n"
)
PY
cp "$AFTER" "$SCRIPT_DIR/receipts/isolation-$run_id.after.tsv"
cp "$BASELINE" "$SCRIPT_DIR/receipts/isolation-$run_id.before.tsv"
printf 'PASS: 9900 production identity/connection snapshots unchanged; 9919 and tmux are isolated.\nReceipt: %s\n' "$receipt_json"
