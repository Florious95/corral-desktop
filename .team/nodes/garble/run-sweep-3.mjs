#!/usr/bin/env node
/**
 * t.panewidth: on each snapshot, read-only tmux display-message for real pane size.
 * ⛔ no send-keys / resize-window / kill. Token never printed.
 * Same 39×114 subscribe as the desktop sweep; WS in-process so the query
 * runs in the snapshot handler (not after a CDP dump round-trip).
 */
import { createWriteStream, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import WebSocket from '/Volumes/nvme/Projects/tmux桌面端/node_modules/ws/index.js';
import { Client } from '../../../src/vendor/agentmirror/client.js';
import { detectGarble } from '../../../src/term/garbleDetect.js';
import { queryTmuxPane } from './tmux-pane-query.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const OUT = join(here, 'sweep-full-3.jsonl');
const ROUNDS = 10;
const TERM_ROWS = 39;
const TERM_COLS = 114;
const SNAP_WAIT_MS = 5000;

function loadPairing() {
  const store = JSON.parse(readFileSync(
    `${homedir()}/Library/Application Support/com.agentmirror.desktop/devices.json`,
    'utf8',
  ));
  const devs = Array.isArray(store) ? store : (store.devices ?? []);
  const dev = Array.isArray(devs) ? devs[0] : devs;
  if (!dev?.url || !dev?.token) throw new Error('pairing missing');
  return { url: dev.url, token: dev.token };
}

function collectSessions(workspaces) {
  const out = [];
  for (const w of workspaces || []) {
    for (const s of w.sessions || []) {
      if (s?.ref) out.push({ ref: s.ref, cols: s.cols, rows: s.rows, cwd: w.cwd });
    }
  }
  return out;
}

async function waitReady(client, ms) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (client.workspaces?.length) return true;
    await sleep(50);
  }
  return false;
}

async function probe(client, session, round) {
  let snap = null;
  let tmuxQ = null;
  let snapToQueryMs = null;
  const prev = client.onBinary;
  client.onBinary = (frame) => {
    if (!snap && frame.kind === 1 && frame.ref === session.ref) {
      const tSnap = process.hrtime.bigint();
      snap = frame;
      tmuxQ = queryTmuxPane(frame.ref);
      snapToQueryMs = Number(process.hrtime.bigint() - tSnap) / 1e6;
    }
    prev(frame);
  };
  client.subscribe(session.ref, TERM_ROWS, TERM_COLS);
  const t0 = Date.now();
  while (Date.now() - t0 < SNAP_WAIT_MS && !snap) await sleep(20);
  client.unsubscribe(session.ref);
  client.onBinary = prev;
  const label = snap
    ? detectGarble({ snapshot: snap.data, termCols: TERM_COLS, termRows: TERM_ROWS })
    : null;
  return {
    round,
    session_ref: session.ref,
    listing_cols: session.cols ?? null,
    listing_rows: session.rows ?? null,
    local_cols: TERM_COLS,
    local_rows: TERM_ROWS,
    got_snapshot: !!snap,
    snapshot_bytes: snap ? snap.data.length : 0,
    garbled: label ? label.garbled : null,
    reasons: label ? label.reasons : [],
    mlw: label ? label.metrics.maxLineWidth : null,
    overwide_lines: label ? label.metrics.overwideLines : null,
    cup_clamped: label ? label.metrics.cupClamped : null,
    max_line_has_wide: label ? label.metrics.maxLineHasWide : null,
    tmux_pane_w: tmuxQ ? tmuxQ.tmux_pane_w : null,
    tmux_pane_h: tmuxQ ? tmuxQ.tmux_pane_h : null,
    tmux_window_size: tmuxQ ? tmuxQ.tmux_window_size : null,
    tmux_clients: tmuxQ ? tmuxQ.tmux_clients : null,
    t_query: tmuxQ ? tmuxQ.t_query : null,
    query_ms: tmuxQ ? tmuxQ.query_ms : null,
    snap_to_query_ms: snapToQueryMs,
    query_err: tmuxQ ? tmuxQ.query_err : (snap ? null : 'no_snapshot'),
  };
}

function summarize(rows) {
  const withQ = rows.filter((r) => Number.isFinite(r.tmux_pane_w) && r.garbled != null);
  const cell = (garbled, pred) => withQ.filter((r) => r.garbled === garbled && pred(r.tmux_pane_w)).length;
  return {
    n_rows: rows.length,
    n_with_query_and_label: withQ.length,
    n_query_fail: rows.filter((r) => r.tmux_pane_w == null).length,
    n_no_snap: rows.filter((r) => !r.got_snapshot).length,
    table: {
      garbled_eq_114: cell(true, (w) => w === 114),
      garbled_ge_115: cell(true, (w) => w >= 115),
      normal_eq_114: cell(false, (w) => w === 114),
      normal_ge_115: cell(false, (w) => w >= 115),
    },
    lags: {
      snap_to_query_ms_max: Math.max(0, ...rows.map((r) => r.snap_to_query_ms || 0)),
      query_ms_max: Math.max(0, ...rows.map((r) => r.query_ms || 0)),
    },
  };
}

async function main() {
  const pairing = loadPairing();
  const client = new Client({
    url: pairing.url,
    token: pairing.token,
    wsFactory: (u) => new WebSocket(u),
    onFrame: () => {},
    onBinary: () => {},
    onLocalError: (c) => { process.stderr.write(`localError ${c}\n`); },
  });
  client.connect();
  const listed = await waitReady(client, 15000);
  if (!listed) {
    writeFileSync(join(here, 'sweep3-fail.json'), JSON.stringify({ ok: false, step: 'listing' }));
    try { client.disconnect(); } catch { /* */ }
    process.exit(2);
  }
  const sessions = collectSessions(client.workspaces);
  process.stderr.write(`sessions=${sessions.length} rounds=${ROUNDS}\n`);
  const ws = createWriteStream(OUT);
  const rows = [];
  try {
    for (let round = 1; round <= ROUNDS; round++) {
      process.stderr.write(`round ${round}/${ROUNDS}\n`);
      const live = collectSessions(client.workspaces);
      const list = live.length ? live : sessions;
      for (const session of list) {
        const row = await probe(client, session, round);
        rows.push(row);
        ws.write(`${JSON.stringify(row)}\n`);
        process.stderr.write(
          `  r${round} garbled=${row.garbled} mlw=${row.mlw} pane=${row.tmux_pane_w} err=${row.query_err || '-'}\n`,
        );
        await sleep(80);
      }
    }
  } finally {
    try { client.disconnect(); } catch { /* */ }
    ws.end();
  }
  const sum = summarize(rows);
  writeFileSync(join(here, 'sweep3-summary.json'), JSON.stringify(sum, null, 2));
  process.stderr.write(`wrote ${OUT} rows=${rows.length} ${JSON.stringify(sum.table)}\n`);
  process.exit(0);
}

main().catch((e) => {
  writeFileSync(join(here, 'sweep3-fail.json'), JSON.stringify({ ok: false, error: String(e && e.message) }));
  process.exit(4);
});
