/**
 * Read-only tmux pane geometry. No send-keys / resize / kill.
 * Protocol ref = `${socket}\x1f${pane_id}` e.g. `/tmp/tmux-501/default\x1f%0`.
 */
import { spawnSync } from 'node:child_process';

export const TMUX_FMT =
  '#{pane_width}x#{pane_height} win=#{window_width}x#{window_height} ws=#{window-size} clients=#{session_attached}';

export function parseSessionRef(ref) {
  const s = String(ref || '');
  const i = s.indexOf('\x1f');
  if (i <= 0) return null;
  const socket = s.slice(0, i);
  const pane = s.slice(i + 1);
  if (!socket.startsWith('/') || !/^%\d+$/.test(pane)) return null;
  return { socket, pane };
}

export function parseDisplay(out) {
  const line = String(out || '').trim().split('\n')[0] || '';
  const m = line.match(/^(\d+)x(\d+)\s+win=(\d+)x(\d+)\s+ws=(\S+)\s+clients=(\d+)\s*$/);
  if (!m) return null;
  return {
    tmux_pane_w: Number(m[1]),
    tmux_pane_h: Number(m[2]),
    tmux_window_w: Number(m[3]),
    tmux_window_h: Number(m[4]),
    tmux_window_size: m[5],
    tmux_clients: Number(m[6]),
    raw: line,
  };
}

/**
 * Snapshot-adjacent query. Returns parsed fields + t_query / query_ms.
 * Never prints pane text. spawnSync only (display-message -p).
 */
export function queryTmuxPane(ref) {
  const parsed = parseSessionRef(ref);
  const t0 = Date.now();
  const tCpu0 = process.hrtime.bigint();
  if (!parsed) {
    return {
      tmux_pane_w: null,
      tmux_pane_h: null,
      tmux_window_size: null,
      tmux_clients: null,
      t_query: t0,
      query_ms: 0,
      query_err: 'bad_ref',
    };
  }
  const env = { ...process.env };
  delete env.TMUX;
  const r = spawnSync(
    'tmux',
    ['-S', parsed.socket, 'display-message', '-p', '-t', parsed.pane, TMUX_FMT],
    { encoding: 'utf8', timeout: 1500, env },
  );
  const query_ms = Number(process.hrtime.bigint() - tCpu0) / 1e6;
  const t_query = Date.now();
  if (r.error || r.status !== 0) {
    return {
      tmux_pane_w: null,
      tmux_pane_h: null,
      tmux_window_size: null,
      tmux_clients: null,
      t_query,
      query_ms,
      query_err: r.error ? r.error.code : `tmux_exit_${r.status}`,
    };
  }
  const geom = parseDisplay(r.stdout);
  if (!geom) {
    return {
      tmux_pane_w: null,
      tmux_pane_h: null,
      tmux_window_size: null,
      tmux_clients: null,
      t_query,
      query_ms,
      query_err: 'parse_fail',
    };
  }
  return {
    tmux_pane_w: geom.tmux_pane_w,
    tmux_pane_h: geom.tmux_pane_h,
    tmux_window_w: geom.tmux_window_w,
    tmux_window_h: geom.tmux_window_h,
    tmux_window_size: geom.tmux_window_size,
    tmux_clients: geom.tmux_clients,
    t_query,
    query_ms,
    query_err: null,
  };
}
