#!/usr/bin/env node
/**
 * t.realcli: own tmux + own daemon. Real cursor-agent TUI, no prompts.
 * Byte-compare to a control pane started at 157x47. No pane text/PNGs committed.
 * Never :9900. Discovery scoped off the user's tmux sockets.
 */
import { spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import net from 'node:net';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import WebSocket from '/Volumes/nvme/Projects/tmux桌面端/node_modules/ws/index.js';
import { Client } from '../../../src/vendor/agentmirror/client.js';
import { firstMismatch } from './cause-diff.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const SERVER = '/Volumes/nvme/Projects/远程Agent安卓/server';
const SOCK = '/tmp/amr-tmux/tmux-501/amr';
const SOCK_DIR = '/tmp/amr-tmux/tmux-501';
const LISTEN_HOST = '127.0.0.1';
const STATE = join(here, 'am-state-realcli');
const BIN = join(here, 'bin');
const DAEMON_BIN = join(BIN, 'agentmirrord-realcli');
const CWD_ROOT = join(here, 'cwd-realcli');
const CLI = process.env.REALCLI_BIN || '/Users/alauda/.local/bin/cursor-agent';
const TOKEN = randomBytes(18).toString('base64url').slice(0, 24);
const HOST = { cols: 235, rows: 50 };
const NARROW = { cols: 157, rows: 47 };

function envNoTmux() {
  const env = { ...process.env };
  delete env.TMUX;
  return env;
}

function envIso() {
  const env = envNoTmux();
  env.TMUX_TMPDIR = '/tmp/amr-tmux';
  env.TERM = env.TERM || 'xterm-256color';
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
  for (let p = 19271; p < 19340; p++) {
    if (await portFree(p)) return p;
  }
  throw new Error('no free listen port in 19271-19339');
}

async function tmux(args) {
  return sh('tmux', ['-S', SOCK, ...args], { env: envIso() });
}

function fingerprint(text) {
  return createHash('sha256').update(String(text ?? ''), 'utf8').digest('hex').slice(0, 16);
}

function colorOf(match) {
  return match ? 'green' : 'red';
}

async function paneGeom(name) {
  const w = await tmux(['display-message', '-p', '-t', `${name}:`, '#{pane_width}x#{pane_height}']);
  const m = String(w.out.trim()).match(/^(\d+)x(\d+)$/);
  return { cols: m ? Number(m[1]) : null, rows: m ? Number(m[2]) : null, raw: w.out.trim() };
}

async function capturePlain(name) {
  const r = await tmux(['capture-pane', '-p', '-t', `${name}:`]);
  if (r.code !== 0) throw new Error(`capture ${name}: ${r.err || r.out}`);
  return r.out;
}

async function waitStable(name, { minMs = 800, maxMs = 25000, quietMs = 1000 } = {}) {
  const t0 = Date.now();
  let last = fingerprint(await capturePlain(name));
  let lastChange = Date.now();
  while (Date.now() - t0 < maxMs) {
    await sleep(200);
    const fp = fingerprint(await capturePlain(name));
    if (fp !== last) {
      last = fp;
      lastChange = Date.now();
    }
    const cap = await capturePlain(name);
    const nonempty = cap.replace(/\s+/g, '').length > 40;
    if (nonempty && Date.now() - t0 >= minMs && Date.now() - lastChange >= quietMs) {
      return { fp: last, wait_ms: Date.now() - t0, nonempty: true, timed_out: false };
    }
  }
  const cap = await capturePlain(name);
  return {
    fp: fingerprint(cap),
    wait_ms: Date.now() - t0,
    nonempty: cap.replace(/\s+/g, '').length > 40,
    timed_out: true,
  };
}

async function watchFp(name, durationMs, fp0) {
  const t0 = Date.now();
  let last = fp0;
  const changes = [];
  while (Date.now() - t0 < durationMs) {
    await sleep(200);
    const fp = fingerprint(await capturePlain(name));
    if (fp !== last) {
      changes.push({ t_ms: Date.now() - t0, fp });
      last = fp;
    }
  }
  return { changes, last_fp: last, duration_ms: durationMs };
}

async function newSess(name, cols, rows) {
  const cwd = join(CWD_ROOT, 'shared');
  mkdirSync(cwd, { recursive: true });
  const r = await tmux([
    'new-session', '-d', '-s', name,
    '-x', String(cols), '-y', String(rows),
    '-c', cwd, '-n', name,
    CLI,
  ]);
  if (r.code !== 0) throw new Error(`new-session ${name}: ${r.err || r.out}`);
}

function pickSession(workspaces, sessName) {
  for (const w of workspaces || []) {
    for (const s of w.sessions || []) {
      if (s.name === sessName) return s;
    }
  }
  return null;
}

async function subscribeWait(client, session, rows, cols, sessName, expectCols) {
  const snaps = [];
  const prev = client.onBinary;
  client.onBinary = (frame) => {
    snaps.push(frame);
    prev.call(client, frame);
  };
  const t0 = Date.now();
  client.subscribe(session.ref, rows, cols);
  let geom = { cols: null, rows: null };
  let snap = null;
  while (Date.now() - t0 < 12000) {
    geom = await paneGeom(sessName);
    const mine = snaps.filter((f) => f.kind === 1 && f.ref === session.ref);
    if (mine.length) snap = mine[mine.length - 1];
    if (expectCols == null || geom.cols === expectCols) {
      if (snap) break;
    }
    await sleep(50);
  }
  await sleep(150);
  const mine2 = snaps.filter((f) => f.kind === 1 && f.ref === session.ref);
  if (mine2.length) snap = mine2[mine2.length - 1];
  geom = await paneGeom(sessName);
  client.onBinary = prev;
  return { geom, snap, ms: Date.now() - t0, snapshot_count: mine2.length };
}

async function ensureDaemon() {
  mkdirSync(BIN, { recursive: true });
  const built = await sh('go', ['build', '-o', DAEMON_BIN, './cmd/agentmirrord'], {
    cwd: SERVER,
    env: envIso(),
  });
  if (built.code !== 0) throw new Error(`go build agentmirrord: ${built.err || built.out}`);
}

async function setupTmux() {
  mkdirSync(CWD_ROOT, { recursive: true });
  mkdirSync(SOCK_DIR, { recursive: true });
  await tmux(['kill-server']).catch(() => {});
  await sleep(120);
  await newSess('want235', HOST.cols, HOST.rows);
  await newSess('want157', NARROW.cols, NARROW.rows);
  await newSess('armAp', HOST.cols, HOST.rows);
  await newSess('armApp', HOST.cols, HOST.rows);
  await newSess('armBp', HOST.cols, HOST.rows);
  await newSess('armDp', HOST.cols, HOST.rows);
  const listed = await tmux(['list-sessions']);
  if (listed.code !== 0 || !listed.out.includes('want157')) {
    throw new Error(`list-sessions failed: ${listed.out} ${listed.err}`);
  }
  return { sessions: listed.out.trim(), cli: CLI };
}

async function main() {
  mkdirSync(STATE, { recursive: true });
  const log = (m) => { process.stderr.write(`${m}\n`); };
  await ensureDaemon();
  const listenPort = await pickListenPort();
  log(`cli=${CLI} listen ${LISTEN_HOST}:${listenPort} sock=${SOCK}`);

  const tmuxInfo = await setupTmux();
  log(`tmux up; waiting first paint`);
  const paint235 = await waitStable('want235');
  const paint157 = await waitStable('want157');
  log(`paint want235 nonempty=${paint235.nonempty} ${paint235.wait_ms}ms want157 nonempty=${paint157.nonempty} ${paint157.wait_ms}ms`);
  const want235 = await capturePlain('want235');
  const want157 = await capturePlain('want157');
  const want = {
    fp235: fingerprint(want235),
    fp157: fingerprint(want157),
    geom235: (await paneGeom('want235')).raw,
    geom157: (await paneGeom('want157')).raw,
    paint235,
    paint157,
  };

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

  const arms = [];
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
    while (Date.now() - tList < 20000) {
      if (pickSession(client.workspaces || [], 'armAp') && pickSession(client.workspaces || [], 'want157')) break;
      await sleep(100);
    }
    log(`workspaces=${(client.workspaces || []).length}`);

    const sess = (name) => {
      const s = pickSession(client.workspaces || [], name);
      if (!s) throw new Error(`session ${name} not in listing`);
      return s;
    };

    async function armSqueeze(id, name, predict, waitMs, extraFn) {
      await waitStable(name, { minMs: 600, maxMs: 20000, quietMs: 800 });
      const fpBefore = fingerprint(await capturePlain(name));
      const sub = await subscribeWait(client, sess(name), NARROW.rows, NARROW.cols, name, NARROW.cols);
      const fpAtResize = fingerprint(await capturePlain(name));
      if (extraFn) await extraFn(name);
      const watched = await watchFp(name, waitMs, fpAtResize);
      const got = await capturePlain(name);
      const diff = firstMismatch(got, want157);
      const firstChange = watched.changes[0] || null;
      const row = {
        id,
        predict,
        actual: colorOf(diff.equal),
        match_predict: predict === colorOf(diff.equal),
        first_mismatch_row: diff.row,
        first_mismatch_col: diff.col,
        got_len: diff.got_len,
        exp_len: diff.exp_len,
        got_fp: fingerprint(got),
        exp_fp: want.fp157,
        pane_after: sub.geom,
        fp_before_sub: fpBefore,
        fp_at_resize: fpAtResize,
        fp_changed_at_reshape: fpBefore !== fpAtResize,
        fp_changed_after_reshape: watched.changes.length > 0,
        first_fp_change_ms: firstChange ? firstChange.t_ms : null,
        fp_change_count: watched.changes.length,
        wait_ms: waitMs,
        snapshot_count: sub.snapshot_count,
      };
      client.unsubscribe(sess(name).ref);
      arms.push(row);
      log(`${id} actual=${row.actual} pane=${sub.geom.raw} fp_change_ms=${row.first_fp_change_ms} mismatch=${diff.row}:${diff.col}`);
      return row;
    }

    await armSqueeze('A′', 'armAp', 'red', 3000);
    await armSqueeze('A″', 'armApp', 'red', 30000);
    await armSqueeze('B′', 'armBp', 'green', 3000, async (name) => {
      await tmux(['send-keys', '-t', `${name}:`, 'Up']);
    });

    {
      const name = 'armDp';
      await waitStable(name, { minMs: 600, maxMs: 20000, quietMs: 800 });
      const fpBefore = fingerprint(await capturePlain(name));
      const sub = await subscribeWait(client, sess(name), HOST.rows, HOST.cols, name, HOST.cols);
      await sleep(800);
      const got = await capturePlain(name);
      const diff = firstMismatch(got, want235);
      const want235Later = await capturePlain('want235');
      const row = {
        id: 'D′',
        predict: 'green',
        actual: colorOf(diff.equal),
        match_predict: 'green' === colorOf(diff.equal),
        first_mismatch_row: diff.row,
        first_mismatch_col: diff.col,
        got_len: diff.got_len,
        exp_len: diff.exp_len,
        got_fp: fingerprint(got),
        exp_fp: want.fp235,
        pane_after: sub.geom,
        snapshot_count: sub.snapshot_count,
        fp_before_sub: fpBefore,
        fp_after_sub: fingerprint(got),
        fp_changed_by_subscribe: fpBefore !== fingerprint(got),
        control_want235_still_same: fingerprint(want235Later) === want.fp235,
      };
      client.unsubscribe(sess(name).ref);
      arms.push(row);
      log(`D′ actual=${row.actual} pane=${sub.geom.raw}`);
    }

    try { client.disconnect(); } catch { /* */ }
  } finally {
    try { if (daemon.pid) process.kill(daemon.pid, 'SIGTERM'); } catch { /* */ }
    await sleep(150);
    await tmux(['kill-server']).catch(() => {});
  }

  const out = {
    ok: arms.length === 4,
    cli: CLI,
    listen: `${LISTEN_HOST}:${listenPort}`,
    socket: SOCK,
    discovery_dirs: SOCK_DIR,
    used_9900: false,
    scanned_user_tmux: false,
    want,
    tmux: { sessions: tmuxInfo.sessions.split('\n').length },
    arms,
  };
  writeFileSync(join(here, 'REALCLI-run.json'), JSON.stringify(out, null, 2));
  writeFileSync(join(here, 'realcli-daemon.log'), redact(daemonLog.join('')).slice(-4000));
  process.exit(0);
}

main().catch((e) => {
  writeFileSync(join(here, 'REALCLI-run.json'), JSON.stringify({ ok: false, error: String(e && e.message) }, null, 2));
  process.exit(4);
});
