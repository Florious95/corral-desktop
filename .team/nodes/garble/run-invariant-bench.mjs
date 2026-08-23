#!/usr/bin/env node
/**
 * Self-built tmux + daemon. Token never printed. Does not touch :9900.
 * Three perturbations: open / window-width / split. Each painted snapshot
 * must have capture cols == grid cols. Screen lines only our INVBOX marker.
 */
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { mkdirSync, writeFileSync, rmSync } from 'node:fs';
import net from 'node:net';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import WebSocket from '/Volumes/nvme/Projects/tmux桌面端/node_modules/ws/index.js';
import { Terminal } from '@xterm/xterm/lib/xterm.mjs';
import { Client } from '../../../src/vendor/agentmirror/client.js';
import { SameWidthController, wrapStats } from '../../../src/term/sameWidth.js';

const here = dirname(fileURLToPath(import.meta.url));
const SERVER = '/Volumes/nvme/Projects/远程Agent安卓/server';
const SOCK = '/tmp/tmux-501/aminv';
const LISTEN_HOST = '127.0.0.1';
const STATE = join(here, 'am-state-inv');
const BIN = join(here, 'bin');
const GROK = join(BIN, 'grok');
const DAEMON_BIN = join(BIN, 'agentmirrord-repro');
const TOKEN = randomBytes(18).toString('base64url').slice(0, 24);
const MARK = 'INVBOX';

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
  for (let p = 20110; p < 20140; p++) {
    if (await portFree(p)) return p;
  }
  throw new Error('no free listen port in 20110-20139');
}

async function tmux(args) {
  return sh('tmux', ['-S', SOCK, ...args], { env: envNoTmux() });
}

function rowHasMark(term, cols) {
  const rows = term.rows;
  for (let y = 0; y < rows; y++) {
    const line = term.buffer.active.getLine(y);
    if (!line) continue;
    let s = '';
    for (let x = 0; x < cols; x++) {
      const cell = line.getCell(x);
      if (cell) s += cell.getChars() || '';
    }
    if (s.includes(MARK)) {
      let first = null;
      for (let x = 0; x < cols; x++) {
        const cell = line.getCell(x);
        if (cell && cell.getChars() === 'I') { first = x; break; }
      }
      return { y, firstCol: first, hasMark: true };
    }
  }
  return { y: null, firstCol: null, hasMark: false };
}

async function paint(bytes, cols, rows) {
  const term = new Terminal({
    cols, rows, scrollback: 0, convertEol: false, allowProposedApi: true,
  });
  await new Promise((r) => term.write(bytes, () => r()));
  const st = wrapStats(term);
  const mark = rowHasMark(term, cols);
  term.dispose();
  return { wrap: st, mark, grid: { cols, rows } };
}

async function waitReady(client, ms) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    if (client.workspaces?.length) return true;
    await sleep(50);
  }
  return false;
}

function fail(step, error, extra = {}) {
  writeFileSync(join(here, 'invariant-bench.json'), JSON.stringify({
    ok: false, step, error: String(error), ...extra,
  }, null, 2));
}

async function main() {
  mkdirSync(STATE, { recursive: true });
  mkdirSync(BIN, { recursive: true });
  try { rmSync(GROK); } catch { /* */ }
  const cc = await sh('cc', ['-O0', '-o', GROK, join(here, 'grok-stub.c')]);
  if (cc.code !== 0) {
    fail('cc', cc.err || cc.out);
    process.exit(2);
  }
  const built = await sh('go', ['build', '-o', DAEMON_BIN, './cmd/agentmirrord'], {
    cwd: SERVER, env: envNoTmux(),
  });
  if (built.code !== 0) {
    fail('go-build', built.err || built.out);
    process.exit(2);
  }
  const listenPort = await pickListenPort();
  await sh('mkdir', ['-p', '/tmp/tmux-501']);
  await tmux(['kill-server']).catch(() => {});
  await sleep(100);
  const cwd = join(here, 'cwd-inv');
  mkdirSync(cwd, { recursive: true });
  const created = await tmux([
    'new-session', '-d', '-s', 'inv', '-x', '80', '-y', '24',
    '-c', cwd, '-n', 'inv', GROK, '--noprofile', '--norc',
  ]);
  if (created.code !== 0) {
    fail('tmux', created.err || created.out);
    process.exit(2);
  }
  await tmux(['send-keys', '-t', 'inv', '-l', '--', MARK]);
  await tmux(['send-keys', '-t', 'inv', 'Enter']);

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

  const cleanup = async () => {
    try { process.kill(daemon.pid, 'SIGTERM'); } catch { /* */ }
    await tmux(['kill-server']).catch(() => {});
  };

  try {
    await waitTcp(LISTEN_HOST, listenPort, 20000);
  } catch (e) {
    fail('daemon', e.message, { log_tail: redact(daemonLog.join('')).slice(-1500) });
    await cleanup();
    process.exit(3);
  }

  const client = new Client({
    url: `ws://${LISTEN_HOST}:${listenPort}/ws`,
    token: TOKEN,
    wsFactory: (u) => new WebSocket(u),
    onFrame: () => {},
    onBinary: () => {},
    onLocalError: () => {},
  });
  client.connect();
  if (!await waitReady(client, 15000)) {
    fail('listing', 'no workspaces');
    client.disconnect();
    await cleanup();
    process.exit(2);
  }

  let session = null;
  for (const w of client.workspaces || []) {
    for (const s of w.sessions || []) {
      if (`${s.cwd || ''}\n${w.cwd || ''}`.includes('cwd-inv')) session = s;
    }
  }
  if (!session) {
    fail('session', 'cwd-inv not listed');
    client.disconnect();
    await cleanup();
    process.exit(2);
  }

  const gate = new SameWidthController();
  const phases = [
    { name: 'open', rows: 24, cols: 80 },
    { name: 'window-width', rows: 24, cols: 100 },
    { name: 'split', rows: 24, cols: 40 },
  ];
  const outPhases = [];
  let mismatchBytes = null;

  try {
    for (const ph of phases) {
      const act = gate.settle(ph.rows, ph.cols);
      if (act.type !== 'subscribe') {
        outPhases.push({ ...ph, error: 'expected subscribe' });
        continue;
      }
      gate.noteSent(act.rows, act.cols);
      let snap = null;
      const prev = client.onBinary;
      client.onBinary = (frame) => {
        if (!snap && frame.kind === 1 && frame.ref === session.ref) snap = frame;
        prev(frame);
      };
      client.subscribe(session.ref, act.rows, act.cols);
      const t0 = Date.now();
      while (Date.now() - t0 < 8000 && !snap) await sleep(20);
      client.onBinary = prev;
      const accepted = gate.acceptSnapshot();
      const matched = snap ? await paint(snap.data, ph.cols, ph.rows) : null;
      let mismatched = null;
      if (ph.name === 'open' && snap) {
        mismatchBytes = snap.data;
        mismatched = await paint(snap.data, 40, 24);
      } else if (mismatchBytes && ph.name === 'split') {
        mismatched = await paint(mismatchBytes, 40, 24);
      }
      outPhases.push({
        name: ph.name,
        sent: { rows: act.rows, cols: act.cols },
        accepted,
        invariant: accepted && matched ? matched.grid.cols === act.cols : false,
        matched_screen: matched ? { wrap: matched.wrap, mark: matched.mark } : null,
        mismatch_40: mismatched ? { wrap: mismatched.wrap, mark: mismatched.mark } : null,
        got_snapshot: !!snap,
        snapshot_bytes: snap ? snap.data.length : 0,
      });
      await sleep(50);
    }
  } finally {
    try { client.unsubscribe(session.ref); } catch { /* */ }
    try { client.disconnect(); } catch { /* */ }
    await cleanup();
  }

  const ok = outPhases.length === 3
    && outPhases.every((p) => p.got_snapshot && p.accepted && p.invariant);
  writeFileSync(join(here, 'invariant-bench.json'), JSON.stringify({
    ok, n_phases: outPhases.length, phases: outPhases,
  }, null, 2));
  process.stderr.write(`${JSON.stringify({ ok, phases: outPhases.map((p) => ({
    name: p.name, sent: p.sent, accepted: p.accepted, invariant: p.invariant,
    mark: p.matched_screen && p.matched_screen.mark,
    mismatch_mark: p.mismatch_40 && p.mismatch_40.mark,
  })) }, null, 2)}\n`);
  process.exit(ok ? 0 : 1);
}

main().catch((e) => {
  fail('crash', e && e.message);
  process.exit(4);
});
