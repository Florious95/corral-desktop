#!/usr/bin/env node
/**
 * Real Client.subscribe against an isolated agentmirrord.
 * Token from env AGENTMIRROR_TOKEN only; never printed.
 */
import { spawn, spawnSync } from 'node:child_process';
import { writeFileSync, readFileSync, mkdirSync, appendFileSync, unlinkSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';
import { Client } from '../../../src/vendor/agentmirror/client.js';
import { BINARY_KIND } from '../../../src/vendor/agentmirror/binary.js';
import { createResizeAnnouncer, inferCapturedCols } from '../../../src/term/resizeAnnounce.js';

const here = dirname(fileURLToPath(import.meta.url));
const N = 20;
const PORT = process.env.AM_PROBE_PORT || '19911';
const uid = process.getuid();
const sockDir = `/private/tmp/tmux-${uid}`;
const sock = join(sockDir, 'amrsz');
const gotLog = join(here, 'got.log');
const py = join(here, 'tui-reader.py');
const stateDir = join(here, 'dstate');
const daemonBin = '/Volumes/nvme/Projects/远程Agent安卓/server/agentmirrord';
const token = process.env.AGENTMIRROR_TOKEN;
if (!token) {
  console.error('missing AGENTMIRROR_TOKEN');
  process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sanitize = (s) => String(s).split(token).join('<token>');

const tmux = (...args) => {
  const env = { ...process.env };
  delete env.TMUX;
  const r = spawnSync('tmux', args, { encoding: 'utf8', env });
  return { rc: r.status ?? 1, out: r.stdout || '', err: r.stderr || '' };
};

function score() {
  const text = readFileSync(gotLog, 'utf8');
  let ok = 0;
  const missing = [];
  for (let i = 1; i <= N; i++) {
    if (text.includes(`GOT:AM-PROBE-${i}`)) ok += 1;
    else missing.push(i);
  }
  const cap = tmux('capture-pane', '-t', 'amrsz', '-p', '-J', '-S', '-80');
  return { ok, missing, failRate: (N - ok) / N, log: text, capture: cap.out };
}

function injectAll() {
  for (let i = 1; i <= N; i++) {
    const marker = `AM-PROBE-${i}`;
    const load = spawnSync('tmux', ['load-buffer', '-'], {
      encoding: 'utf8',
      input: marker,
      env: (() => { const e = { ...process.env }; delete e.TMUX; return e; })(),
    });
    if ((load.status ?? 1) !== 0) throw new Error(`load-buffer ${load.stderr}`);
    const p = tmux('paste-buffer', '-d', '-t', 'amrsz');
    if (p.rc !== 0) throw new Error(`paste-buffer ${p.err}`);
    const e = tmux('send-keys', '-t', 'amrsz', 'Enter');
    if (e.rc !== 0) throw new Error(`Enter ${e.err}`);
    spawnSync('sleep', ['0.08']);
  }
  spawnSync('sleep', ['0.3']);
  return score();
}

function startTmux() {
  tmux('kill-session', '-t', 'amrsz');
  writeFileSync(gotLog, '');
  const grokBin = join(here, 'grok');
  const csrc = join(here, 'grok-tui.c');
  const built = spawnSync('cc', ['-O1', '-o', grokBin, csrc], { encoding: 'utf8' });
  if ((built.status ?? 1) !== 0) throw new Error(`cc grok ${built.stderr}`);
  const r = tmux(
    'new-session', '-d', '-s', 'amrsz', '-n', 'amrsz', '-x', '80', '-y', '24',
    '-c', here, '--', grokBin, gotLog,
  );
  if (r.rc !== 0) throw new Error(`new-session ${r.err || r.out}`);
  const list = tmux('list-sessions');
  if (list.rc !== 0) throw new Error(`list-sessions ${list.err}`);
  if (!list.out.includes('amrsz')) throw new Error('session amrsz missing');
  const panes = tmux('list-panes', '-t', 'amrsz', '-F', '#{session_name}|#{window_name}|#{pane_width}x#{pane_height}');
  writeFileSync(join(here, 'tmux-selfcheck.txt'), panes.out);
}

function stopTmux() {
  tmux('kill-session', '-t', 'amrsz');
}

function startDaemon() {
  mkdirSync(stateDir, { recursive: true });
  mkdirSync(join(stateDir, 'up'), { recursive: true });
  const outPath = join(here, 'daemon.stdout');
  const errPath = join(here, 'daemon.stderr');
  writeFileSync(outPath, '');
  writeFileSync(errPath, '');
  const child = spawn(daemonBin, [
    '-listen', `127.0.0.1:${PORT}`,
    '-state-dir', stateDir,
    '-upload-dir', join(stateDir, 'up'),
    '-log-level', 'warn',
    '-list-interval', '1s',
  ], {
    cwd: '/Volumes/nvme/Projects/远程Agent安卓/server',
    env: (() => {
      const env = { ...process.env, AGENTMIRROR_TOKEN: token };
      delete env.TMUX;
      delete env.TS_AUTHKEY;
      delete env.TMUX_TMPDIR;
      delete env.AGENTMIRROR_E2E_DISCOVERY_SOCKET_DIRS;
      return env;
    })(),
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let errBuf = '';
  child.stderr.on('data', (b) => {
    const s = sanitize(String(b));
    errBuf += s;
    appendFileSync(errPath, s);
  });
  return { child, errPath, getErr: () => errBuf };
}

function findAmrsz(client) {
  for (const s of client.sessionsByRef.values()) {
    if (s.name === 'amrsz') return s;
    if (typeof s.cwd === 'string' && s.cwd.includes('.team/nodes/resize')) return s;
    if (typeof s.ref === 'string' && s.ref.includes('/amrsz')) return s;
  }
  return null;
}

async function withSubscribe(rows, cols) {
  writeFileSync(gotLog, '');
  let resizeCount = 0;
  let snapshots = 0;
  const client = new Client({
    url: `ws://127.0.0.1:${PORT}/ws`,
    token,
    wsFactory: (u) => new WebSocket(u),
    backoff: { baseMs: 200, maxMs: 800, factor: 1.5, jitter: 0 },
    onStateChange: (s) => {
      appendFileSync(join(here, 'client-trace.txt'), `state ${s}\n`);
    },
    onFrame: (type, payload) => {
      if (type !== 'listing' && type !== 'auth_ack') return;
      const n = (payload.workspaces || []).reduce((a, w) => a + (w.sessions || []).length, 0);
      const names = [];
      for (const w of payload.workspaces || []) {
        for (const s of w.sessions || []) names.push(s.name);
      }
      appendFileSync(join(here, 'client-trace.txt'), `${type} sessions=${n} hasAmrsz=${names.includes('amrsz')} nnames=${names.length}\n`);
    },
    onConnectionIssue: (msg) => {
      appendFileSync(join(here, 'client-trace.txt'), `issue ${sanitize(msg)}\n`);
    },
    onLocalError: (code, message) => {
      appendFileSync(join(here, 'client-errors.txt'), sanitize(`${code}: ${message}\n`));
    },
  });
  const _hm = client.handleMessage.bind(client);
  client.handleMessage = (data) => {
    if (typeof Buffer !== 'undefined' && Buffer.isBuffer(data)) {
      if (data.length && data[0] === 0x7b) data = data.toString('utf8');
      else data = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    }
    return _hm(data);
  };
  const announcer = createResizeAnnouncer({
    send: (r, c) => {
      resizeCount += 1;
      client.resize(refHolder.ref, r, c);
    },
  });
  const refHolder = { ref: null };
  client.onBinary = (frame) => {
    if (frame.kind !== BINARY_KIND.SNAPSHOT) return;
    snapshots += 1;
    const text = new TextDecoder().decode(frame.data);
    const captured = inferCapturedCols(text);
    if (captured != null && cols > captured + 1) announcer.reassert();
  };
  client.connect();
  const t0 = Date.now();
  while (Date.now() - t0 < 8000) {
    await sleep(150);
    if (!client.isReady) continue;
    client.list();
    await sleep(200);
    const sess = findAmrsz(client);
    if (sess) {
      refHolder.ref = sess.ref;
      announcer.note(rows, cols);
      client.subscribe(sess.ref, rows, cols);
      await sleep(600);
      const result = injectAll();
      client.disconnect();
      announcer.dispose();
      return {
        ...result,
        resizeCount,
        snapshots,
        listedRows: sess.rows,
        listedCols: sess.cols,
        sessionName: sess.name,
      };
    }
  }
  client.disconnect();
  announcer.dispose();
  throw new Error('listing never contained amrsz (ready=' + client.isReady + ' sessions=' + client.sessionsByRef.size + ')');
}

const report = { n: N, port: PORT, notes: 'token via env AGENTMIRROR_TOKEN (generated). Session amrsz on default tmux server (daemon binary ignores private sockets); kill-session amrsz only, never kill-server.' };

try {
  startTmux();
  spawnSync('sleep', ['0.35']);
  const daemon = startDaemon();
  for (let i = 0; i < 40; i++) {
    await sleep(150);
    if (daemon.child.exitCode != null) {
      throw new Error('daemon exited ' + daemon.child.exitCode);
    }
    const hit = spawnSync('lsof', ['-nP', `-iTCP:${PORT}`, '-sTCP:LISTEN'], { encoding: 'utf8' });
    if ((hit.status ?? 1) === 0 && hit.stdout.includes(String(PORT))) break;
    if (i === 39) throw new Error('daemon never listened');
  }

  writeFileSync(gotLog, '');
  const control = injectAll();
  report.control = {
    name: 'no_ws_subscribe',
    submitted: control.ok,
    failRate: control.failRate,
    missing: control.missing,
  };
  writeFileSync(join(here, 'ws-control.capture.txt'), control.capture);

  const subscribed = await withSubscribe(24, 100);
  report.subscribed = {
    name: 'Client.subscribe_plus_announcer',
    submitted: subscribed.ok,
    failRate: subscribed.failRate,
    missing: subscribed.missing,
    resizeCount: subscribed.resizeCount,
    snapshots: subscribed.snapshots,
    listedRows: subscribed.listedRows,
    listedCols: subscribed.listedCols,
    sessionName: subscribed.sessionName,
  };
  writeFileSync(join(here, 'ws-subscribed.capture.txt'), subscribed.capture);

  try { process.kill(daemon.child.pid); } catch { /* gone */ }
  stopTmux();
} catch (e) {
  report.error = sanitize(e.message || String(e));
  try { stopTmux(); } catch { /* */ }
}

writeFileSync(join(here, 'ws-subscribe-probe.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({
  control: report.control,
  subscribed: report.subscribed,
  error: report.error || null,
}));
process.exit(report.error ? 1 : 0);
