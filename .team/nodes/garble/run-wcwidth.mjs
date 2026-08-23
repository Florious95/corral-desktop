#!/usr/bin/env node
/**
 * t.wcwidth: find codepoints whose tmux cell width ≠ xterm cell width.
 * ⛔ Does not write pane text / tokens. Own tmux socket only for isolated measure.
 */
import { spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { Terminal } from '/Volumes/nvme/Projects/tmux桌面端/node_modules/@xterm/xterm/lib/xterm.mjs';
import WebSocket from '/Volumes/nvme/Projects/tmux桌面端/node_modules/ws/index.js';
import { Client } from '../../../src/vendor/agentmirror/client.js';
import { detectGarble } from '../../../src/term/garbleDetect.js';
import { parseSessionRef } from './tmux-pane-query.mjs';
import { unicodeBlock, uPlus } from './unicode-block.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const SOCK = '/tmp/tmux-501/amw';
const TERM_ROWS = 39;
const TERM_COLS = 114;
const CSI_OR_ESC = /\x1b(?:\[[0-?]*[ -/]*[@-~]|].*?(?:\x07|\x1b\\)|[PX^_].*?\x1b\\|[\[\]()#%][0-9;]*[0-9A-Za-z]|.)/gs;

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

function stripAnsi(text) {
  return text.replace(CSI_OR_ESC, '');
}

function envNoTmux() {
  const env = { ...process.env };
  delete env.TMUX;
  return env;
}

function sh(args, input) {
  return spawnSync('tmux', ['-S', SOCK, ...args], {
    encoding: 'utf8',
    env: envNoTmux(),
    input: input || undefined,
    timeout: 2000,
  });
}

const xtermCache = new Map();

async function xtermWidth(cp) {
  if (xtermCache.has(cp)) return xtermCache.get(cp);
  const ch = String.fromCodePoint(cp);
  const term = new Terminal({
    cols: 8, rows: 3, scrollback: 0, allowProposedApi: true, convertEol: false,
  });
  await new Promise((resolve) => {
    term.reset();
    term.write(ch, () => resolve());
  });
  let w = 1;
  const line = term.buffer.active.getLine(0);
  if (line) {
    const cell = line.getCell(0);
    if (cell) w = cell.getWidth();
  }
  term.dispose();
  xtermCache.set(cp, w);
  return w;
}

function setupMeasureTmux() {
  spawnSync('mkdir', ['-p', '/tmp/tmux-501']);
  sh(['kill-server']);
  const r = sh([
    'new-session', '-d', '-s', 'm', '-x', '20', '-y', '4',
    '-e', 'PS1=',
    'bash', '--noprofile', '--norc',
  ]);
  if (r.status !== 0) throw new Error(`measure tmux: ${r.stderr || r.stdout}`);
}

function tmuxWidth(cp) {
  const ch = String.fromCodePoint(cp);
  sh(['send-keys', '-t', 'm', 'C-u']);
  const base = sh(['display-message', '-p', '-t', 'm', '#{cursor_x}']);
  const b = Number(String(base.stdout || '').trim());
  sh(['send-keys', '-t', 'm', '-l', '--', ch]);
  const cur = sh(['display-message', '-p', '-t', 'm', '#{cursor_x}']);
  const x = Number(String(cur.stdout || '').trim());
  if (!Number.isFinite(x) || !Number.isFinite(b)) return { w: null, err: 'cursor' };
  return { w: x - b, err: null };
}

function capturePane(ref) {
  const p = parseSessionRef(ref);
  if (!p) return null;
  const r = spawnSync(
    'tmux',
    ['-S', p.socket, 'capture-pane', '-p', '-t', p.pane],
    { encoding: 'utf8', env: envNoTmux(), timeout: 1500 },
  );
  if (r.status !== 0) return null;
  return r.stdout;
}

async function walkOverwide(text, paneCols, counts, overflowHits) {
  const lines = stripAnsi(text).replace(/\r/g, '').split('\n');
  for (const line0 of lines) {
    const line = line0.replace(/\s+$/g, '');
    if (!line) continue;
    const cps = [];
    for (const ch of line) cps.push(ch.codePointAt(0));
    const widths = [];
    for (const cp of cps) widths.push(await xtermWidth(cp));
    let acc = 0;
    let overflowAt = -1;
    for (let i = 0; i < cps.length; i++) {
      acc += widths[i];
      if (overflowAt < 0 && acc > paneCols) overflowAt = i;
    }
    if (acc <= paneCols) continue;
    overflowHits.n += 1;
    overflowHits.xterm_sum.push(acc);
    if (overflowAt >= 0) {
      const cp = cps[overflowAt];
      const key = String(cp);
      if (!counts.has(key)) {
        counts.set(key, { cp, n: 0, xterm_w: widths[overflowAt], at_overflow: 0 });
      }
      const row = counts.get(key);
      row.n += 1;
      row.at_overflow += 1;
    }
    for (let i = 0; i < cps.length; i++) {
      if (widths[i] !== 2) continue;
      const cp = cps[i];
      const key = String(cp);
      if (!counts.has(key)) {
        counts.set(key, { cp, n: 0, xterm_w: 2, at_overflow: 0 });
      }
      counts.get(key).n += 1;
    }
  }
}

async function waitReady(client, ms) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (client.workspaces?.length) return true;
    await sleep(50);
  }
  return false;
}

function collectSessions(workspaces) {
  const out = [];
  for (const w of workspaces || []) {
    for (const s of w.sessions || []) {
      if (s?.ref) out.push({ ref: s.ref, cols: s.cols, rows: s.rows });
    }
  }
  return out;
}

async function main() {
  mkdirSync(here, { recursive: true });
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
  if (!await waitReady(client, 15000)) {
    writeFileSync(join(here, 'wcwidth-run.json'), JSON.stringify({ ok: false, step: 'listing' }));
    try { client.disconnect(); } catch { /* */ }
    process.exit(2);
  }
  const sessions = collectSessions(client.workspaces);
  process.stderr.write(`sessions=${sessions.length}\n`);

  const counts = new Map();
  const overflowHits = { n: 0, xterm_sum: [], from_snap: 0, from_cap: 0 };
  let snaps = 0;
  let garbled115 = 0;

  try {
    for (const session of sessions) {
      let snap = null;
      const prev = client.onBinary;
      client.onBinary = (frame) => {
        if (!snap && frame.kind === 1 && frame.ref === session.ref) snap = frame;
        prev(frame);
      };
      client.subscribe(session.ref, TERM_ROWS, TERM_COLS);
      const t0 = Date.now();
      while (Date.now() - t0 < 4000 && !snap) await sleep(20);
      const cap = capturePane(session.ref);
      client.unsubscribe(session.ref);
      client.onBinary = prev;
      if (!snap) continue;
      snaps += 1;
      const label = detectGarble({ snapshot: snap.data, termCols: TERM_COLS, termRows: TERM_ROWS });
      if (label.garbled && label.metrics.maxLineWidth === 115) garbled115 += 1;
      const raw = new TextDecoder('utf-8', { fatal: false }).decode(snap.data);
      const nBefore = overflowHits.n;
      await walkOverwide(raw, TERM_COLS, counts, overflowHits);
      overflowHits.from_snap += overflowHits.n - nBefore;
      if (cap) {
        const n2 = overflowHits.n;
        await walkOverwide(cap, TERM_COLS, counts, overflowHits);
        overflowHits.from_cap += overflowHits.n - n2;
      }
      await sleep(40);
    }
  } finally {
    try { client.disconnect(); } catch { /* */ }
  }

  process.stderr.write(`snaps=${snaps} garbled115=${garbled115} overwide_lines=${overflowHits.n} unique_cp=${counts.size}\n`);

  setupMeasureTmux();
  const toMeasure = [...counts.values()].filter((row) => {
    if (row.at_overflow > 0) return true;
    const b = unicodeBlock(row.cp);
    return b !== 'CJK Unified Ideographs' && b !== 'Hiragana' && b !== 'Katakana' && b !== 'Hangul Syllables';
  });
  process.stderr.write(`measure_cps=${toMeasure.length}\n`);
  const table = [];
  for (const row of toMeasure.sort((a, b) => b.at_overflow - a.at_overflow || b.n - a.n)) {
    const tw = tmuxWidth(row.cp);
    table.push({
      cp: uPlus(row.cp),
      block: unicodeBlock(row.cp),
      tmux_w: tw.w,
      xterm_w: row.xterm_w,
      n: row.n,
      n_at_overflow: row.at_overflow,
      mismatch: tw.w != null && tw.w !== row.xterm_w,
      tmux_err: tw.err,
    });
  }
  sh(['kill-server']);

  const mismatch = table.filter((r) => r.mismatch);
  writeFileSync(join(here, 'wcwidth-table.json'), JSON.stringify({
    snaps,
    garbled115,
    overwide_lines_seen: overflowHits.n,
    overwide_from_snapshot: overflowHits.from_snap,
    overwide_from_capture_p: overflowHits.from_cap,
    table,
    mismatch,
  }, null, 2));
  process.stderr.write(`mismatch=${mismatch.length}\n`);
}

main().catch((e) => {
  writeFileSync(join(here, 'wcwidth-table.json'), JSON.stringify({ ok: false, error: String(e && e.message) }));
  process.exit(4);
});
