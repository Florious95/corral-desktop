#!/usr/bin/env node
/**
 * Controlled 2×2 garble repro: own tmux socket + own agentmirrord.
 * Token never printed. Does not touch the user's tmux or :9900 daemon.
 */
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import net from 'node:net';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import WebSocket from '/Volumes/nvme/Projects/tmux桌面端/node_modules/ws/index.js';
import { Client } from '../../../src/vendor/agentmirror/client.js';
import { detectGarble } from '../../../src/term/garbleDetect.js';
import { dump, resetDiag, resetHostGeom, liveHostGeomOf } from '../../../src/term/amDiag.js';

const here = dirname(fileURLToPath(import.meta.url));
const SERVER = '/Volumes/nvme/Projects/远程Agent安卓/server';
const SOCK = '/tmp/tmux-501/amr';
const LISTEN_HOST = '127.0.0.1';
const STATE = join(here, 'am-state-r3');
const BIN = join(here, 'bin');
const GROK = join(BIN, 'grok');
const DAEMON_BIN = join(BIN, 'agentmirrord-repro');
const TOKEN = randomBytes(18).toString('base64url').slice(0, 24);

/** 113 ASCII + one CJK → displayWidth 115; CJK occupies cells 114–115. */
export const CJK_LINE = `${'x'.repeat(113)}中`;
/** Pure ASCII hitting the 114-col boundary. */
export const ASCII_LINE = 'x'.repeat(114);

const CELLS = [
  { id: 'A', cols: 235, rows: 50, line: CJK_LINE, predict: 'red' },
  { id: 'B', cols: 235, rows: 50, line: ASCII_LINE, predict: 'green' },
  { id: 'C', cols: 114, rows: 39, line: CJK_LINE, predict: '?' },
  { id: 'D', cols: 137, rows: 42, line: CJK_LINE, predict: '?' },
];

function envNoTmux() {
  const env = { ...process.env };
  delete env.TMUX;
  return env;
}

function sh(cmd, args, opts = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { ...opts, stdio: opts.stdio || ['ignore', 'pipe', 'pipe'] });
    let out = '';
    let err = '';
    child.stdout?.on('data', (d) => { out += d; });
    child.stderr?.on('data', (d) => { err += d; });
    child.on('exit', (code) => resolve({ code, out, err, pid: child.pid }));
    child.on('error', reject);
  });
}

function waitTcp(host, port, timeoutMs) {
  const t0 = Date.now();
  return new Promise((resolve, reject) => {
    const tryOnce = () => {
      const sock = net.connect({ host, port });
      sock.once('connect', () => { sock.destroy(); resolve(true); });
      sock.once('error', () => {
        sock.destroy();
        if (Date.now() - t0 > timeoutMs) reject(new Error(`waitTcp ${host}:${port} timeout`));
        else setTimeout(tryOnce, 200);
      });
    };
    tryOnce();
  });
}

function portFree(port) {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.once('error', () => resolve(false));
    srv.once('listening', () => { srv.close(() => resolve(true)); });
    srv.listen(port, LISTEN_HOST);
  });
}

async function pickListenPort() {
  for (let p = 19971; p < 20040; p++) {
    if (await portFree(p)) return p;
  }
  throw new Error('no free listen port in 19971-20039');
}

async function tmux(args) {
  return sh('tmux', ['-S', SOCK, ...args], { env: envNoTmux() });
}

async function setupTmux() {
  await sh('mkdir', ['-p', '/tmp/tmux-501']);
  await tmux(['kill-server']).catch(() => {});
  await sleep(100);
  for (const cell of CELLS) {
    const cwd = join(here, `cwd-${cell.id}`);
    mkdirSync(cwd, { recursive: true });
    const r = await tmux([
      'new-session', '-d', '-s', `cell${cell.id}`,
      '-x', String(cell.cols), '-y', String(cell.rows),
      '-c', cwd, '-n', `cell${cell.id}`,
      GROK, '--noprofile', '--norc',
    ]);
    if (r.code !== 0) throw new Error(`new-session ${cell.id}: ${r.err || r.out}`);
    await sleep(80);
    const sent = await tmux(['send-keys', '-t', `cell${cell.id}`, '-l', '--', cell.line]);
    if (sent.code !== 0) throw new Error(`send-keys ${cell.id}: ${sent.err}`);
    await tmux(['send-keys', '-t', `cell${cell.id}`, 'Enter']);
  }
  const listed = await tmux(['list-sessions']);
  if (listed.code !== 0 || !listed.out.includes('cellA')) {
    throw new Error(`list-sessions failed: ${listed.out} ${listed.err}`);
  }
  const widths = {};
  for (const cell of CELLS) {
    const w = await tmux(['display-message', '-p', '-t', `cell${cell.id}`, '#{pane_width}x#{pane_height}']);
    widths[cell.id] = w.out.trim();
  }
  return { sessions: listed.out.trim(), widths };
}

function pickSession(workspaces, cellId) {
  const needle = `cwd-${cellId}`;
  for (const w of workspaces || []) {
    for (const s of w.sessions || []) {
      const cwd = `${s.cwd || ''}\n${w.cwd || ''}`;
      if (cwd.includes(needle)) return s;
    }
  }
  return null;
}

async function probeOne(client, session, cell) {
  const cap = await tmux(['capture-pane', '-J', '-p', '-t', `cell${cell.id}`]);
  const before = detectGarble({ snapshot: cap.out, termCols: 114, termRows: 39 });
  resetDiag();
  const snaps = [];
  const prev = client.onBinary;
  client.onBinary = (frame) => {
    snaps.push(frame);
    prev(frame);
  };
  client.subscribe(session.ref, 39, 114);
  const t0 = Date.now();
  let snap = null;
  while (Date.now() - t0 < 15000) {
    snap = snaps.find((f) => f.kind === 1 && f.ref === session.ref);
    if (snap) break;
    await sleep(50);
  }
  client.list();
  await sleep(800);
  client.unsubscribe(session.ref);
  client.onBinary = prev;
  const label = snap
    ? detectGarble({ snapshot: snap.data, termCols: 114, termRows: 39 })
    : null;
  const events = dump().events || [];
  const sub = [...events].reverse().find((e) => e.type === 'subscribe' && e.ref === session.ref);
  const snapEv = [...events].reverse().find((e) => e.type === 'snapshot' && e.ref === session.ref);
  const liveEv = [...events].reverse().find((e) =>
    (e.type === 'list_delta' || e.type === 'listing') && (e.panes || []).some((p) => p.ref === session.ref));
  const liveAfter = liveHostGeomOf(session.ref);
  const paneAfter = await tmux(['display-message', '-p', '-t', `cell${cell.id}`, '#{pane_width}']);
  return {
    id: cell.id,
    predict: cell.predict,
    host_set_cols: cell.cols,
    listing_cols_before: session.cols,
    listing_rows_before: session.rows,
    pane_width_after_sub: Number(paneAfter.out.trim()) || null,
    capture_mlw_before_sub: before.metrics.maxLineWidth,
    capture_garbled_at_114_before_sub: before.garbled,
    got_snapshot: !!snap,
    snapshot_bytes: snap ? snap.data.length : 0,
    garbled: label ? label.garbled : null,
    reasons: label ? label.reasons : [],
    mlw: label ? label.metrics.maxLineWidth : null,
    overwide_lines: label ? label.metrics.overwideLines : null,
    max_line_chars: label ? label.metrics.maxLineChars : null,
    max_line_has_wide: label ? label.metrics.maxLineHasWide : null,
    n_lines_width_eq_cols: label ? label.metrics.nLinesWidthEqCols : null,
    n_lines_width_cols_plus_1: label ? label.metrics.nLinesWidthColsPlus1 : null,
    host_cols: sub ? sub.host_cols : null,
    host_cols_live: liveAfter ? liveAfter.cols : (snapEv ? snapEv.host_cols_live : null),
    host_cols_at_snap: snapEv ? snapEv.host_cols_at_snap : null,
    live_listing_seq: snapEv ? snapEv.live_listing_seq : null,
    saw_post_sub_listing: !!liveEv,
  };
}

async function ensureGrokBin() {
  mkdirSync(BIN, { recursive: true });
  try { rmSync(GROK); } catch { /* */ }
  const src = join(here, 'grok-stub.c');
  const cc = await sh('cc', ['-O0', '-o', GROK, src]);
  if (cc.code !== 0) throw new Error(`cc grok-stub: ${cc.err || cc.out}`);
}

async function ensureDaemonBin() {
  mkdirSync(BIN, { recursive: true });
  const built = await sh('go', ['build', '-o', DAEMON_BIN, './cmd/agentmirrord'], { cwd: SERVER, env: envNoTmux() });
  if (built.code !== 0) throw new Error(`go build agentmirrord: ${built.err || built.out}`);
}

async function main() {
  mkdirSync(STATE, { recursive: true });
  const notes = [];
  const log = (m) => { notes.push(m); process.stderr.write(`${m}\n`); };

  let listenPort;
  try {
    await ensureGrokBin();
    await ensureDaemonBin();
    listenPort = await pickListenPort();
    log(`listen ${LISTEN_HOST}:${listenPort}`);
  } catch (e) {
    writeFileSync(join(here, 'repro-run.json'), JSON.stringify({ ok: false, step: 'prep', error: String(e.message || e) }, null, 2));
    process.exit(2);
  }

  let tmuxInfo;
  try {
    tmuxInfo = await setupTmux();
    log(`tmux ok sessions=${tmuxInfo.sessions.split('\n').length} widths=${JSON.stringify(tmuxInfo.widths)}`);
  } catch (e) {
    writeFileSync(join(here, 'repro-run.json'), JSON.stringify({ ok: false, step: 'tmux', error: String(e.message || e) }, null, 2));
    process.exit(2);
  }

  const daemonLog = [];
  const redact = (s) => String(s).split(TOKEN).join('[REDACTED]');
  const daemon = spawn(
    DAEMON_BIN,
    ['-listen', `${LISTEN_HOST}:${listenPort}`, '-state-dir', STATE, '-list-interval', '200ms'],
    {
      cwd: SERVER,
      env: { ...envNoTmux(), AGENTMIRROR_TOKEN: TOKEN, AGENTMIRROR_LISTEN: `${LISTEN_HOST}:${listenPort}` },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );
  daemon.stdout.on('data', (d) => daemonLog.push(redact(d.toString())));
  daemon.stderr.on('data', (d) => daemonLog.push(redact(d.toString())));

  try {
    await waitTcp(LISTEN_HOST, listenPort, 20000);
    log(`daemon tcp up pid=${daemon.pid}`);
  } catch (e) {
    writeFileSync(join(here, 'daemon.log'), redact(daemonLog.join('')).slice(-4000));
    writeFileSync(join(here, 'repro-run.json'), JSON.stringify({ ok: false, step: 'daemon', error: e.message, port: listenPort }, null, 2));
    try { process.kill(daemon.pid, 'SIGTERM'); } catch { /* */ }
    await tmux(['kill-server']);
    process.exit(3);
  }

  resetHostGeom();
  resetDiag();
  const frames = [];
  const client = new Client({
    url: `ws://${LISTEN_HOST}:${listenPort}/ws`,
    token: TOKEN,
    wsFactory: (u) => new WebSocket(u),
    onFrame: (type, payload) => { frames.push({ type, payload }); },
    onBinary: () => {},
    onLocalError: (c, m) => { log(`localError ${c}`); },
  });
  client.connect();
  const tList = Date.now();
  let workspaces = [];
  while (Date.now() - tList < 15000) {
    workspaces = client.workspaces || [];
    const found = CELLS.every((c) => pickSession(workspaces, c.id));
    if (found) break;
    const listing = [...frames].reverse().find((f) => f.type === 'listing');
    if (listing?.payload?.workspaces?.length) {
      workspaces = listing.payload.workspaces;
      if (CELLS.every((c) => pickSession(workspaces, c.id))) break;
    }
    await sleep(100);
  }

  const results = [];
  try {
    for (const cell of CELLS) {
      const session = pickSession(workspaces, cell.id);
      if (!session) {
        results.push({
          id: cell.id,
          error: 'not in listing',
          our_cwds: (workspaces || []).map((w) => w.cwd).filter((c) => String(c).includes('cwd-')),
        });
        continue;
      }
      const row = await probeOne(client, session, cell);
      results.push(row);
      log(`cell ${cell.id} garbled=${row.garbled} mlw=${row.mlw} live=${row.host_cols_live} pane=${row.pane_width_after_sub}`);
      await sleep(200);
    }
  } finally {
    try { client.disconnect(); } catch { /* */ }
    try { if (daemon.pid) process.kill(daemon.pid, 'SIGTERM'); } catch { /* */ }
    await sleep(200);
    await tmux(['kill-server']);
  }

  const A = results.find((r) => r.id === 'A');
  const B = results.find((r) => r.id === 'B');
  const ok = !!(A && B && A.garbled === true && B.garbled === false);
  const out = {
    ok,
    listen: `${LISTEN_HOST}:${listenPort}`,
    socket: SOCK,
    tmux: tmuxInfo,
    fixture: {
      cjk: '113 ASCII x + U+4E2D (displayWidth 115)',
      ascii: '114 ASCII x (displayWidth 114)',
    },
    subscribe: '39x114',
    results,
    a_red_b_green: ok,
  };
  writeFileSync(join(here, 'repro-run.json'), JSON.stringify(out, null, 2));
  writeFileSync(join(here, 'daemon.log'), redact(daemonLog.join('')).slice(-6000));
  process.exit(ok ? 0 : 1);
}

main().catch((e) => {
  writeFileSync(join(here, 'repro-run.json'), JSON.stringify({ ok: false, error: String(e && e.message) }, null, 2));
  process.exit(4);
});
