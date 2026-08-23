#!/usr/bin/env node
/**
 * t.precedent: own tmux + own daemon. Drive click-open geometry
 * (SameWidthController settle → subscribe + App-like resize). Numbers only.
 * Never :9900. Never user sockets. Token never printed.
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
import { SameWidthController } from '../../../src/term/sameWidth.js';
import {
  resetGeomTrace, dumpGeomTrace, geomTrace, formatLine, bookOf,
} from '../../../src/term/geomTrace.js';

const here = dirname(fileURLToPath(import.meta.url));
const SERVER = '/Volumes/nvme/Projects/远程Agent安卓/server';
const SOCK = '/tmp/amp-tmux/tmux-501/amp';
const SOCK_DIR = '/tmp/amp-tmux/tmux-501';
const LISTEN_HOST = '127.0.0.1';
const STATE = join(here, 'am-state-precedent');
const BIN = join(here, 'bin');
const GROK = join(BIN, 'grok');
const DAEMON_BIN = join(BIN, 'agentmirrord-precedent');
const CWD_ROOT = join(here, 'cwd-precedent');
const TOKEN = randomBytes(18).toString('base64url').slice(0, 24);
const HOST = { cols: 235, rows: 50 };
const FIT = { cols: 157, rows: 47 };

const SESSIONS = [
  { name: 'host235', cols: HOST.cols, rows: HOST.rows },
  { name: 'alt80', cols: 80, rows: 24 },
];

function envNoTmux() {
  const env = { ...process.env };
  delete env.TMUX;
  return env;
}

function envIso() {
  const env = envNoTmux();
  env.TMUX_TMPDIR = '/tmp/amp-tmux';
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
  for (let p = 19371; p < 19440; p++) {
    if (await portFree(p)) return p;
  }
  throw new Error('no free listen port in 19371-19439');
}

async function tmux(args) {
  return sh('tmux', ['-S', SOCK, ...args], { env: envIso() });
}

async function paneGeom(name) {
  const w = await tmux(['display-message', '-p', '-t', `${name}:`, '#{pane_width}x#{pane_height}']);
  const m = String(w.out.trim()).match(/^(\d+)x(\d+)$/);
  return { cols: m ? Number(m[1]) : null, rows: m ? Number(m[2]) : null, raw: w.out.trim() };
}

async function setupTmux() {
  mkdirSync(CWD_ROOT, { recursive: true });
  mkdirSync(SOCK_DIR, { recursive: true });
  await tmux(['kill-server']).catch(() => {});
  await sleep(120);
  for (const s of SESSIONS) {
    const cwd = join(CWD_ROOT, s.name);
    mkdirSync(cwd, { recursive: true });
    const r = await tmux([
      'new-session', '-d', '-s', s.name,
      '-x', String(s.cols), '-y', String(s.rows),
      '-c', cwd, '-n', s.name,
      GROK,
    ]);
    if (r.code !== 0) throw new Error(`new-session ${s.name}: ${r.err || r.out}`);
  }
  const listed = await tmux(['list-sessions']);
  if (listed.code !== 0 || !listed.out.includes('host235')) {
    throw new Error(`list-sessions failed: ${listed.out} ${listed.err}`);
  }
  return listed.out.trim();
}

function pickSession(workspaces, sessName) {
  const needle = `cwd-precedent/${sessName}`;
  for (const w of workspaces || []) {
    for (const s of w.sessions || []) {
      const cwd = `${s.cwd || ''}\n${w.cwd || ''}`;
      if (cwd.includes(needle)) return s;
    }
  }
  return null;
}

/** Product click-open: activate → xterm default propose → fit settle subscribe → App resize. */
function clickOpen(client, session, fitRows, fitCols) {
  geomTrace('activate', { ref: session.ref });
  const gate = new SameWidthController();
  gate.proposeGrid(24, 80);
  geomTrace('derived', {
    ref: session.ref,
    derived_cols: 80,
    derived_rows: 24,
    last_sent_cols: null,
    note: 'xterm_default_before_fit',
  });
  const act = gate.settle(fitRows, fitCols);
  if (!act || act.type !== 'subscribe') {
    geomTrace('subscribe', {
      ref: session.ref, rows: fitRows, cols: fitCols, reason: 'activate',
      ok: false, skipped: 'gate_none', ...bookOf(session.ref),
    });
  } else {
    client.subscribe(session.ref, act.rows, act.cols, 'activate');
    gate.noteSent(act.rows, act.cols);
  }
  client.resize(session.ref, fitRows, fitCols, 'fit');
  return gate;
}

async function waitListing(client, name, timeoutMs = 15000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    const s = pickSession(client.workspaces || [], name);
    if (s) return s;
    await sleep(100);
  }
  const cwds = [];
  for (const w of client.workspaces || []) {
    cwds.push(w.cwd);
    for (const se of w.sessions || []) cwds.push(se.cwd);
  }
  throw new Error(`session ${name} not in listing ready=${client.isReady} workspaces=${(client.workspaces || []).length} cwds=${JSON.stringify(cwds.filter(Boolean).slice(0, 40))}`);
}

async function ensureBins() {
  mkdirSync(BIN, { recursive: true });
  try { rmSync(GROK); } catch { /* */ }
  const cc = await sh('cc', ['-O0', '-o', GROK, join(here, 'grok-tui.c')]);
  if (cc.code !== 0) throw new Error(`cc grok-tui: ${cc.err || cc.out}`);
  const built = await sh('go', ['build', '-o', DAEMON_BIN, './cmd/agentmirrord'], {
    cwd: SERVER,
    env: envIso(),
  });
  if (built.code !== 0) throw new Error(`go build agentmirrord: ${built.err || built.out}`);
}

async function main() {
  resetGeomTrace();
  mkdirSync(STATE, { recursive: true });
  const log = (m) => { process.stderr.write(`${m}\n`); };
  await ensureBins();
  const listenPort = await pickListenPort();
  log(`listen ${LISTEN_HOST}:${listenPort} sock=${SOCK}`);
  await setupTmux();
  log(`tmux up geom host235=${(await paneGeom('host235')).raw} alt80=${(await paneGeom('alt80')).raw}`);

  const daemonLog = [];
  const redact = (s) => String(s).split(TOKEN).join('[REDACTED]');
  const daemon = spawn(
    DAEMON_BIN,
    ['-listen', `${LISTEN_HOST}:${listenPort}`, '-state-dir', STATE, '-list-interval', '200ms'],
    {
      cwd: SERVER,
      env: {
        ...envIso(),
        AGENTMIRROR_TOKEN: TOKEN,
        AGENTMIRROR_LISTEN: `${LISTEN_HOST}:${listenPort}`,
        AGENTMIRROR_E2E_DISCOVERY_SOCKET_DIRS: SOCK_DIR,
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  );
  daemon.stdout.on('data', (d) => daemonLog.push(redact(d.toString())));
  daemon.stderr.on('data', (d) => daemonLog.push(redact(d.toString())));

  const out = {
    ok: false,
    listen: `${LISTEN_HOST}:${listenPort}`,
    socket: SOCK,
    discovery_dirs: SOCK_DIR,
    used_9900: false,
    scanned_user_tmux: false,
  };

  try {
    await waitTcp(LISTEN_HOST, listenPort, 20000);
    const client = new Client({
      url: `ws://${LISTEN_HOST}:${listenPort}/ws`,
      token: TOKEN,
      wsFactory: (u) => new WebSocket(u),
      onLocalError: (c) => log(`localError ${c}`),
    });
    client.connect();
    const tList = Date.now();
    while (Date.now() - tList < 15000) {
      if (pickSession(client.workspaces || [], 'host235') && pickSession(client.workspaces || [], 'alt80')) break;
      await sleep(100);
    }
    log(`workspaces=${(client.workspaces || []).length} ready=${client.isReady}`);
    const s235 = await waitListing(client, 'host235', 2000);
    const s80 = await waitListing(client, 'alt80', 2000);
    log(`listed host235 cols=${s235.cols} alt80 cols=${s80.cols}`);

    clickOpen(client, s235, FIT.rows, FIT.cols);
    const t0 = Date.now();
    while (Date.now() - t0 < 8000) {
      const g = await paneGeom('host235');
      const listed = pickSession(client.workspaces || [], 'host235');
      if (g.cols === FIT.cols && listed && listed.cols === FIT.cols) break;
      await sleep(80);
    }
    const afterFit = {
      pane: await paneGeom('host235'),
      listing_cols: pickSession(client.workspaces || [], 'host235')?.cols ?? null,
      listing_rows: pickSession(client.workspaces || [], 'host235')?.rows ?? null,
    };
    log(`after click-open pane=${afterFit.pane.raw} listing_cols=${afterFit.listing_cols}`);

    clickOpen(client, s80, 24, 80);
    await sleep(1500);
    const afterAlt = {
      pane: await paneGeom('alt80'),
      listing_cols: pickSession(client.workspaces || [], 'alt80')?.cols ?? null,
      book235: bookOf(s235.ref),
      book80: bookOf(s80.ref),
    };
    log(`after alt pane=${afterAlt.pane.raw} book235=${afterAlt.book235.bookkept_cols} book80=${afterAlt.book80.bookkept_cols}`);

    try { client.disconnect(); } catch { /* */ }

    const events = dumpGeomTrace();
    out.lines = events.map(formatLine);
    out.events = events;
    out.after_fit = afterFit;
    out.after_alt = afterAlt;
    out.ok = true;
  } finally {
    try { if (daemon.pid) process.kill(daemon.pid, 'SIGTERM'); } catch { /* */ }
    await sleep(150);
    await tmux(['kill-server']).catch(() => {});
  }

  writeFileSync(join(here, 'PRECEDENT-run.json'), JSON.stringify(out, null, 2));
  writeFileSync(join(here, 'precedent-daemon.log'), redact(daemonLog.join('')).slice(-4000));
  process.exit(out.ok ? 0 : 4);
}

main().catch((e) => {
  writeFileSync(join(here, 'PRECEDENT-run.json'), JSON.stringify({ ok: false, error: String(e && e.message) }, null, 2));
  process.stderr.write(`${e && e.stack ? e.stack : e}\n`);
  process.exit(4);
});
