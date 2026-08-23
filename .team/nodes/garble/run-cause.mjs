#!/usr/bin/env node
/**
 * t.cause: own tmux socket + own daemon. Byte-compare captures to a control pane
 * drawn at the target size. No detectGarble. Token never printed. Never :9900.
 * Does not write pane text or PNGs into artifacts that get committed.
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
const SOCK = '/tmp/amc-tmux/tmux-501/amc';
const SOCK_DIR = '/tmp/amc-tmux/tmux-501';
const LISTEN_HOST = '127.0.0.1';
const STATE = join(here, 'am-state-cause');
const BIN = join(here, 'bin');
const GROK = join(BIN, 'grok');
const DAEMON_BIN = join(BIN, 'agentmirrord-cause');
const CWD_ROOT = join(here, 'cwd-cause');
const TOKEN = randomBytes(18).toString('base64url').slice(0, 24);
const HOST = { cols: 235, rows: 50 };
const NARROW = { cols: 157, rows: 47 };

const SESSIONS = [
  { name: 'want235', cols: HOST.cols, rows: HOST.rows, ignore: false },
  { name: 'want157', cols: NARROW.cols, rows: NARROW.rows, ignore: false },
  { name: 'armA', cols: HOST.cols, rows: HOST.rows, ignore: true },
  { name: 'armB', cols: HOST.cols, rows: HOST.rows, ignore: false },
  { name: 'armC', cols: HOST.cols, rows: HOST.rows, ignore: true },
  { name: 'armD', cols: HOST.cols, rows: HOST.rows, ignore: true },
  { name: 'armE1', cols: HOST.cols, rows: HOST.rows, ignore: false },
  { name: 'armE2', cols: HOST.cols, rows: HOST.rows, ignore: false },
  { name: 'armF1', cols: HOST.cols, rows: HOST.rows, ignore: false },
  { name: 'armF2', cols: HOST.cols, rows: HOST.rows, ignore: false },
];

function envNoTmux() {
  const env = { ...process.env };
  delete env.TMUX;
  return env;
}

function envCause() {
  const env = envNoTmux();
  env.TMUX_TMPDIR = '/tmp/amc-tmux';
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
  for (let p = 19171; p < 19240; p++) {
    if (await portFree(p)) return p;
  }
  throw new Error('no free listen port in 19171-19239');
}

async function tmux(args) {
  return sh('tmux', ['-S', SOCK, ...args], { env: envCause() });
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

async function panePid(name) {
  const r = await tmux(['display-message', '-p', '-t', `${name}:`, '#{pane_pid}']);
  return Number(String(r.out.trim())) || null;
}

async function capturePlain(name) {
  const r = await tmux(['capture-pane', '-p', '-t', `${name}:`]);
  if (r.code !== 0) throw new Error(`capture ${name}: ${r.err || r.out}`);
  return r.out;
}

async function setupTmux() {
  mkdirSync(CWD_ROOT, { recursive: true });
  mkdirSync(SOCK_DIR, { recursive: true });
  await tmux(['kill-server']).catch(() => {});
  await sleep(120);
  for (const s of SESSIONS) {
    const cwd = join(CWD_ROOT, s.name);
    mkdirSync(cwd, { recursive: true });
    const cmd = [GROK];
    if (s.ignore) cmd.push('--ignore-winch');
    const r = await tmux([
      'new-session', '-d', '-s', s.name,
      '-x', String(s.cols), '-y', String(s.rows),
      '-c', cwd, '-n', s.name,
      ...cmd,
    ]);
    if (r.code !== 0) throw new Error(`new-session ${s.name}: ${r.err || r.out}`);
  }
  await sleep(250);
  const listed = await tmux(['list-sessions']);
  if (listed.code !== 0 || !listed.out.includes('want235')) {
    throw new Error(`list-sessions failed: ${listed.out} ${listed.err}`);
  }
  const geoms = {};
  for (const s of SESSIONS) geoms[s.name] = (await paneGeom(s.name)).raw;
  return { sessions: listed.out.trim(), geoms };
}

function pickSession(workspaces, sessName) {
  const needle = `cwd-cause/${sessName}`;
  for (const w of workspaces || []) {
    for (const s of w.sessions || []) {
      const cwd = `${s.cwd || ''}\n${w.cwd || ''}`;
      if (cwd.includes(needle)) return s;
    }
  }
  return null;
}

async function subscribeWait(client, session, rows, cols, sessName, expectCols) {
  const snaps = [];
  const prev = client.onBinary;
  client.onBinary = (frame) => {
    snaps.push(frame);
    prev(frame);
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
  await sleep(200);
  const mine2 = snaps.filter((f) => f.kind === 1 && f.ref === session.ref);
  if (mine2.length) snap = mine2[mine2.length - 1];
  geom = await paneGeom(sessName);
  client.onBinary = prev;
  return { geom, snap, ms: Date.now() - t0, snapshot_count: mine2.length };
}

async function ensureBins() {
  mkdirSync(BIN, { recursive: true });
  try { rmSync(GROK); } catch { /* */ }
  const cc = await sh('cc', ['-O0', '-o', GROK, join(here, 'grok-tui.c')]);
  if (cc.code !== 0) throw new Error(`cc grok-tui: ${cc.err || cc.out}`);
  const built = await sh('go', ['build', '-o', DAEMON_BIN, './cmd/agentmirrord'], {
    cwd: SERVER,
    env: envCause(),
  });
  if (built.code !== 0) throw new Error(`go build agentmirrord: ${built.err || built.out}`);
}

function verdictRow(id, predict, diff, extra = {}) {
  const actual = colorOf(diff.equal);
  return {
    id,
    predict,
    actual,
    match_predict: predict === actual,
    first_mismatch_row: diff.row,
    first_mismatch_col: diff.col,
    got_len: diff.got_len,
    exp_len: diff.exp_len,
    got_fp: extra.got_fp || null,
    exp_fp: extra.exp_fp || null,
    pane_after: extra.pane_after || null,
    ...extra.more,
  };
}

async function main() {
  mkdirSync(STATE, { recursive: true });
  const log = (m) => { process.stderr.write(`${m}\n`); };
  const listenPort = await (async () => {
    await ensureBins();
    return pickListenPort();
  })();
  log(`listen ${LISTEN_HOST}:${listenPort} sock=${SOCK}`);

  const tmuxInfo = await setupTmux();
  log(`tmux sessions=${tmuxInfo.sessions.split('\n').length}`);

  const want235 = await capturePlain('want235');
  const want157 = await capturePlain('want157');
  const want = {
    fp235: fingerprint(want235),
    fp157: fingerprint(want157),
    geom235: (await paneGeom('want235')).raw,
    geom157: (await paneGeom('want157')).raw,
  };

  const daemonLog = [];
  const redact = (s) => String(s).split(TOKEN).join('[REDACTED]');
  const daemon = spawn(
    DAEMON_BIN,
    ['-listen', `${LISTEN_HOST}:${listenPort}`, '-state-dir', STATE, '-list-interval', '200ms'],
    {
      cwd: SERVER,
      env: {
        ...envCause(),
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
  const timings = [];
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
    let workspaces = [];
    while (Date.now() - tList < 15000) {
      workspaces = client.workspaces || [];
      if (pickSession(workspaces, 'armA') && pickSession(workspaces, 'armD')) break;
      await sleep(100);
    }
    log(`workspaces=${(client.workspaces || []).length} ready=${client.isReady}`);

    const sess = (name) => {
      const s = pickSession(client.workspaces || workspaces, name);
      if (!s) {
        const cwds = [];
        for (const w of client.workspaces || workspaces || []) {
          cwds.push(w.cwd);
          for (const se of w.sessions || []) cwds.push(se.cwd);
        }
        throw new Error(`session ${name} not in listing cwds=${JSON.stringify(cwds.filter(Boolean).slice(0, 40))}`);
      }
      return s;
    };

    // D first: subscribe at host size (no squeeze)
    {
      const name = 'armD';
      const sub = await subscribeWait(client, sess(name), HOST.rows, HOST.cols, name, HOST.cols);
      const got = await capturePlain(name);
      const diff = firstMismatch(got, want235);
      arms.push(verdictRow('D', 'green', diff, {
        got_fp: fingerprint(got), exp_fp: want.fp235, pane_after: sub.geom,
        more: { subscribe: `${HOST.rows}x${HOST.cols}`, snapshot_count: sub.snapshot_count },
      }));
      client.unsubscribe(sess(name).ref);
      log(`D actual=${arms.at(-1).actual} pane=${sub.geom.raw}`);
    }

    // A: ignore-winch, squeeze to 157
    {
      const name = 'armA';
      const sub = await subscribeWait(client, sess(name), NARROW.rows, NARROW.cols, name, NARROW.cols);
      const got = await capturePlain(name);
      const diff = firstMismatch(got, want157);
      arms.push(verdictRow('A', 'red', diff, {
        got_fp: fingerprint(got), exp_fp: want.fp157, pane_after: sub.geom,
        more: { subscribe: `${NARROW.rows}x${NARROW.cols}`, snapshot_count: sub.snapshot_count },
      }));
      client.unsubscribe(sess(name).ref);
      log(`A actual=${arms.at(-1).actual} pane=${sub.geom.raw} mismatch=${diff.row}:${diff.col}`);
    }

    // B: redraw on SIGWINCH, squeeze
    {
      const name = 'armB';
      const t0 = Date.now();
      const sub = await subscribeWait(client, sess(name), NARROW.rows, NARROW.cols, name, NARROW.cols);
      let got = await capturePlain(name);
      let diff = firstMismatch(got, want157);
      const deadline = Date.now() + 3000;
      while (!diff.equal && Date.now() < deadline) {
        await sleep(50);
        got = await capturePlain(name);
        diff = firstMismatch(got, want157);
      }
      const ms = Date.now() - t0;
      arms.push(verdictRow('B', 'green', diff, {
        got_fp: fingerprint(got), exp_fp: want.fp157, pane_after: sub.geom,
        more: { subscribe: `${NARROW.rows}x${NARROW.cols}`, settle_ms: ms, snapshot_count: sub.snapshot_count },
      }));
      client.unsubscribe(sess(name).ref);
      log(`B actual=${arms.at(-1).actual} pane=${sub.geom.raw} settle_ms=${ms}`);
    }

    // C: ignore-winch, squeeze, then SIGUSR1 one line
    {
      const name = 'armC';
      const sub = await subscribeWait(client, sess(name), NARROW.rows, NARROW.cols, name, NARROW.cols);
      const pid = await panePid(name);
      if (pid) {
        try { process.kill(pid, 'SIGUSR1'); } catch { /* */ }
      }
      await sleep(200);
      const got = await capturePlain(name);
      const diff = firstMismatch(got, want157);
      arms.push(verdictRow('C', 'green', diff, {
        got_fp: fingerprint(got), exp_fp: want.fp157, pane_after: sub.geom,
        more: { subscribe: `${NARROW.rows}x${NARROW.cols}`, usr1_pid: pid, snapshot_count: sub.snapshot_count },
      }));
      client.unsubscribe(sess(name).ref);
      log(`C actual=${arms.at(-1).actual} pane=${sub.geom.raw} mismatch=${diff.row}:${diff.col}`);
    }

    async function flicker(name1, name2, dwellMs, rounds) {
      const s1 = sess(name1);
      const s2 = sess(name2);
      const mismatches = [];
      for (let i = 0; i < rounds; i++) {
        const target = i % 2 === 0 ? { s: s1, n: name1 } : { s: s2, n: name2 };
        const other = i % 2 === 0 ? s2 : s1;
        client.unsubscribe(other.ref);
        await subscribeWait(client, target.s, NARROW.rows, NARROW.cols, target.n, NARROW.cols);
        await sleep(dwellMs);
        const got = await capturePlain(target.n);
        const diff = firstMismatch(got, want157);
        if (!diff.equal) mismatches.push({ i, row: diff.row, col: diff.col, pane: target.n });
      }
      client.unsubscribe(s1.ref);
      client.unsubscribe(s2.ref);
      return mismatches;
    }

    {
      const bad = await flicker('armE1', 'armE2', 600, 16);
      const actual = bad.length ? 'red' : 'green';
      arms.push({
        id: 'E',
        predict: 'red',
        actual,
        match_predict: actual === 'red',
        first_mismatch_row: bad[0] ? bad[0].row : null,
        first_mismatch_col: bad[0] ? bad[0].col : null,
        mismatch_rounds: bad.length,
        rounds: 16,
        dwell_ms: 600,
      });
      log(`E actual=${actual} mismatch_rounds=${bad.length}`);
    }
    {
      const bad = await flicker('armF1', 'armF2', 2200, 16);
      const actual = bad.length ? 'red' : 'green';
      arms.push({
        id: 'F',
        predict: 'green',
        actual,
        match_predict: actual === 'green',
        first_mismatch_row: bad[0] ? bad[0].row : null,
        first_mismatch_col: bad[0] ? bad[0].col : null,
        mismatch_rounds: bad.length,
        rounds: 16,
        dwell_ms: 2200,
      });
      log(`F actual=${actual} mismatch_rounds=${bad.length}`);
    }

    // 3.4 timings: 10× subscribe redrawing pane already at 235, wait until match 157
    for (let i = 0; i < 10; i++) {
      const name = 'armB';
      await tmux(['resize-window', '-t', `${name}:`, '-x', String(HOST.cols), '-y', String(HOST.rows)]);
      await sleep(80);
      const t0 = Date.now();
      await subscribeWait(client, sess(name), NARROW.rows, NARROW.cols, name, NARROW.cols);
      let got = await capturePlain(name);
      let diff = firstMismatch(got, want157);
      while (!diff.equal && Date.now() - t0 < 5000) {
        await sleep(10);
        got = await capturePlain(name);
        diff = firstMismatch(got, want157);
      }
      const ms = Date.now() - t0;
      timings.push({ i, ms, matched: diff.equal });
      client.unsubscribe(sess(name).ref);
      await sleep(50);
    }

    try { client.disconnect(); } catch { /* */ }
  } finally {
    try { if (daemon.pid) process.kill(daemon.pid, 'SIGTERM'); } catch { /* */ }
    await sleep(150);
    await tmux(['kill-server']).catch(() => {});
  }

  const byId = Object.fromEntries(arms.map((a) => [a.id, a]));
  const hyp = !!(byId.A && byId.B && byId.D
    && byId.A.actual === 'red' && byId.B.actual === 'green' && byId.D.actual === 'green');
  const mean = timings.length
    ? Math.round(timings.reduce((s, t) => s + t.ms, 0) / timings.length)
    : null;

  const out = {
    ok: arms.length === 6,
    hypothesis_holds: hyp,
    listen: `${LISTEN_HOST}:${listenPort}`,
    socket: SOCK,
    used_9900: false,
    want,
    arms,
    timings_ms: timings,
    timing_mean_ms: mean,
  };
  writeFileSync(join(here, 'CAUSE-run.json'), JSON.stringify(out, null, 2));
  writeFileSync(join(here, 'cause-daemon.log'), redact(daemonLog.join('')).slice(-4000));
  process.exit(0);
}

main().catch((e) => {
  writeFileSync(join(here, 'CAUSE-run.json'), JSON.stringify({ ok: false, error: String(e && e.message) }, null, 2));
  try {
    writeFileSync(join(here, 'cause-daemon.log'), String(e && e.stack || e).slice(0, 2000));
  } catch { /* */ }
  process.exit(4);
});
