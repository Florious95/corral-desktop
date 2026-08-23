#!/usr/bin/env node
/**
 * t.edge: replay overwide lines into our own 114-col pane; read #{cursor_x/y}.
 * ⛔ no pane text / token in artifacts. ⛔ no send-keys to user panes.
 */
import { spawnSync } from 'node:child_process';
import { openSync, writeSync, closeSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import WebSocket from '/Volumes/nvme/Projects/tmux桌面端/node_modules/ws/index.js';
import { Client } from '../../../src/vendor/agentmirror/client.js';
import { detectGarble } from '../../../src/term/garbleDetect.js';
import { parseSessionRef, queryTmuxPane } from './tmux-pane-query.mjs';
import { unicodeBlock, uPlus } from './unicode-block.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const SOCK = '/tmp/tmux-501/ame';
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

function stripAnsi(text) {
  return String(text || '').replace(CSI_OR_ESC, '');
}

/** Same rules as garbleDetect.js displayWidth (copy; ⛔ do not edit product). */
function displayWidth(str) {
  let w = 0;
  for (const ch of str) {
    const c = ch.codePointAt(0);
    if (c <= 0x1f || (c >= 0x7f && c <= 0x9f)) continue;
    if (c >= 0x300 && c <= 0x36f) continue;
    if (isWide(c)) w += 2;
    else w += 1;
  }
  return w;
}

function isWide(c) {
  return (c >= 0x1100 && c <= 0x115f)
    || (c >= 0x2e80 && c <= 0x9fff)
    || (c >= 0xac00 && c <= 0xd7af)
    || (c >= 0xf900 && c <= 0xfaff)
    || (c >= 0xfe10 && c <= 0xfe19)
    || (c >= 0xff01 && c <= 0xff60)
    || (c >= 0xffe0 && c <= 0xffe6)
    || (c >= 0x1f300 && c <= 0x1faff);
}

function setupLab() {
  spawnSync('mkdir', ['-p', '/tmp/tmux-501']);
  sh(['kill-server']);
  const r = sh([
    'new-session', '-d', '-s', 'e', '-x', String(TERM_COLS), '-y', '8',
    'sleep', '3600',
  ]);
  if (r.status !== 0) throw new Error(`lab tmux: ${r.stderr || r.stdout}`);
  const tty = String(sh(['display-message', '-p', '-t', 'e', '#{pane_tty}']).stdout || '').trim();
  const pw = Number(String(sh(['display-message', '-p', '-t', 'e', '#{pane_width}']).stdout || '').trim());
  if (!tty.startsWith('/dev/')) throw new Error(`bad tty ${tty}`);
  if (pw !== TERM_COLS) throw new Error(`lab pane_width=${pw}`);
  return { tty, pane_width: pw };
}

function cursor() {
  const out = String(sh(['display-message', '-p', '-t', 'e', '#{cursor_x} #{cursor_y}']).stdout || '').trim();
  const m = out.match(/^(\d+)\s+(\d+)$/);
  if (!m) return { ok: false, raw: out };
  return { ok: true, cursor_x: Number(m[1]), cursor_y: Number(m[2]) };
}

function printfToPane(tty, bytes) {
  const fd = openSync(tty, 'w');
  try {
    writeSync(fd, bytes);
  } finally {
    closeSync(fd);
  }
}

function measureLine(tty, text) {
  printfToPane(tty, '\x1b[H\x1b[2J');
  printfToPane(tty, Buffer.from(text, 'utf8'));
  const c = cursor();
  const our = displayWidth(text);
  const wrapped = c.ok && c.cursor_y > 0;
  const tmux_fits_114 = c.ok && !wrapped && c.cursor_x <= TERM_COLS;
  let ruling;
  if (!c.ok) ruling = 'cursor_unreadable';
  else if (our > TERM_COLS && tmux_fits_114) ruling = 'we_overcount';
  else if (wrapped) ruling = 'tmux_overflow';
  else if (our <= TERM_COLS && tmux_fits_114) ruling = 'both_fit';
  else ruling = 'other';
  return {
    our_w: our,
    n_chars: [...text].length,
    ...c,
    wrapped: !!wrapped,
    tmux_fits_114: !!tmux_fits_114,
    ruling,
  };
}

function prefixAgree(m, our) {
  const tmuxSameRow = m.ok && m.cursor_y === 0;
  return tmuxSameRow ? our === m.cursor_x : our > TERM_COLS && m.wrapped;
}

function firstWrap(tty, text) {
  const chars = [...text];
  const n = chars.length;
  const cy = (i) => {
    const m = measureLine(tty, chars.slice(0, i).join(''));
    return m;
  };
  const whole = cy(n);
  if (!whole.wrapped) {
    return { wrapped: false, at: null };
  }
  let lo = 1;
  let hi = n;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (cy(mid).wrapped) hi = mid;
    else lo = mid + 1;
  }
  const at = cy(lo);
  const prev = lo > 1 ? cy(lo - 1) : null;
  const ch = chars[lo - 1];
  const cp = ch.codePointAt(0);
  return {
    wrapped: true,
    wrap_char_index: lo,
    wrap_u: uPlus(cp),
    wrap_block: unicodeBlock(cp),
    wrap_our_w: at.our_w,
    wrap_cursor_x: at.cursor_x,
    wrap_cursor_y: at.cursor_y,
    prev_char_index: prev ? lo - 1 : null,
    prev_u: prev ? uPlus(chars[lo - 2].codePointAt(0)) : null,
    prev_our_w: prev && prev.our_w,
    prev_cursor_x: prev && prev.cursor_x,
    prev_cursor_y: prev && prev.cursor_y,
    our_delta: prev ? at.our_w - prev.our_w : at.our_w,
    col_before_wrap: prev ? prev.cursor_x : 0,
  };
}

function firstFork(tty, text) {
  const chars = [...text];
  const n = chars.length;
  if (n < 1) return { ok: true, fork: null, last_agree: null };
  const meas = (i) => {
    const prefix = chars.slice(0, i).join('');
    const m = measureLine(tty, prefix);
    const rec = {
      i,
      cp: chars[i - 1].codePointAt(0),
      u: uPlus(chars[i - 1].codePointAt(0)),
      block: unicodeBlock(chars[i - 1].codePointAt(0)),
      our_w: m.our_w,
      cursor_x: m.cursor_x,
      cursor_y: m.cursor_y,
      wrapped: m.wrapped,
      agree: prefixAgree(m, m.our_w),
    };
    return rec;
  };
  const last = meas(n);
  if (last.agree) {
    return { ok: true, fork: null, last_agree: {
      i: last.i, u: last.u, our_w: last.our_w, cursor_x: last.cursor_x, cursor_y: last.cursor_y,
    } };
  }
  let lo = 1;
  let hi = n;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    const r = meas(mid);
    if (r.agree) lo = mid + 1;
    else hi = mid;
  }
  const fork = meas(lo);
  const prev = lo > 1 ? meas(lo - 1) : null;
  return {
    ok: true,
    fork,
    last_agree: prev && prev.agree ? {
      i: prev.i, u: prev.u, our_w: prev.our_w, cursor_x: prev.cursor_x, cursor_y: prev.cursor_y,
    } : null,
  };
}

function controls(tty) {
  const a = 'x'.repeat(113) + '中';
  const b = 'x'.repeat(114);
  const c = '中'.repeat(57);
  const d = 'x'.repeat(113);
  return {
    wide_straddle: { fixture: '113 ASCII x + U+4E2D', ...measureLine(tty, a), wrap: firstWrap(tty, a) },
    fill_ascii: { fixture: '114 ASCII x', ...measureLine(tty, b) },
    fill_cjk: { fixture: '57 U+4E2D', ...measureLine(tty, c) },
    almost_fill: { fixture: '113 ASCII x', ...measureLine(tty, d) },
  };
}

function capP(ref) {
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

function overwideLines(text) {
  const lines = stripAnsi(text).replace(/\r/g, '').split('\n').map((l) => l.replace(/\s+$/g, ''));
  const out = [];
  for (const line of lines) {
    const g = detectGarble({ snapshot: line, termCols: TERM_COLS });
    if (g.metrics.maxLineWidth > TERM_COLS) {
      out.push({ line, our_w: g.metrics.maxLineWidth, n_chars: [...line].length });
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

function collectSessions(workspaces) {
  const out = [];
  for (const w of workspaces || []) {
    for (const s of w.sessions || []) {
      if (s?.ref) out.push({ ref: s.ref });
    }
  }
  return out;
}

async function liveLines() {
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
  process.stderr.write('ws connecting\n');
  const found = [];
  let n_sessions = 0;
  try {
    if (!await waitReady(client, 15000)) return { ok: false, step: 'listing', n_sessions, found };
    const sessions = collectSessions(client.workspaces);
    n_sessions = sessions.length;
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
      const text = capP(session.ref);
      const geom = queryTmuxPane(session.ref);
      client.unsubscribe(session.ref);
      client.onBinary = prev;
      if (!text || geom.tmux_pane_w !== TERM_COLS) continue;
      for (const row of overwideLines(text)) {
        if (row.our_w !== 115) continue;
        found.push(row);
      }
      await sleep(20);
    }
  } finally {
    try { client.disconnect(); } catch { /* */ }
  }
  return { ok: true, n_sessions, found };
}

async function main() {
  const lab = setupLab();
  process.stderr.write(`lab pane_width=${lab.pane_width}\n`);
  const ctrl = controls(lab.tty);
  process.stderr.write(`controls done\n`);
  const live = await liveLines();
  const replay = [];
  if (live.ok) {
    process.stderr.write(`live n_sessions=${live.n_sessions} overwide_lines=${live.found.length}\n`);
    for (const row of live.found) {
      const whole = measureLine(lab.tty, row.line);
      const wrap = firstWrap(lab.tty, row.line);
      const fork = whole.ruling === 'we_overcount' ? firstFork(lab.tty, row.line) : { fork: null, last_agree: null };
      replay.push({
        our_w: row.our_w,
        n_chars: row.n_chars,
        whole,
        wrap,
        fork: fork.fork && {
          i: fork.fork.i,
          u: fork.fork.u,
          block: fork.fork.block,
          our_w: fork.fork.our_w,
          cursor_x: fork.fork.cursor_x,
          cursor_y: fork.fork.cursor_y,
          wrapped: fork.fork.wrapped,
        },
        last_agree: fork.last_agree,
      });
    }
  }
  sh(['kill-server']);
  const tot = {
    n_live: replay.length,
    we_overcount: replay.filter((r) => r.whole.ruling === 'we_overcount').length,
    tmux_overflow: replay.filter((r) => r.whole.ruling === 'tmux_overflow').length,
    both_fit: replay.filter((r) => r.whole.ruling === 'both_fit').length,
    other: replay.filter((r) => r.whole.ruling === 'other').length,
  };
  const out = {
    lab: { pane_width: lab.pane_width, method: 'printf to #{pane_tty} after CSI home+erase; sleep 3600 pane' },
    controls: ctrl,
    live: { ok: live.ok, step: live.step, n_sessions: live.n_sessions, tot, replay },
  };
  writeFileSync(join(here, 'edge-run.json'), JSON.stringify(out, null, 2));
  process.stderr.write(`${JSON.stringify({
    controls: {
      wide_straddle: { ruling: ctrl.wide_straddle.ruling, cx: ctrl.wide_straddle.cursor_x, cy: ctrl.wide_straddle.cursor_y, our: ctrl.wide_straddle.our_w },
      fill_ascii: { ruling: ctrl.fill_ascii.ruling, cx: ctrl.fill_ascii.cursor_x, cy: ctrl.fill_ascii.cursor_y, our: ctrl.fill_ascii.our_w },
      fill_cjk: { ruling: ctrl.fill_cjk.ruling, cx: ctrl.fill_cjk.cursor_x, cy: ctrl.fill_cjk.cursor_y, our: ctrl.fill_cjk.our_w },
    },
    tot,
  }, null, 2)}\n`);
}

main().catch((e) => {
  try { sh(['kill-server']); } catch { /* */ }
  writeFileSync(join(here, 'edge-run.json'), JSON.stringify({ ok: false, error: String(e && e.message) }));
  process.exit(4);
});
