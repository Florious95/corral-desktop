#!/usr/bin/env node
/**
 * Real Client.subscribe + product TerminalView.fit (jittered cell probe).
 * Token from env AGENTMIRROR_TOKEN only; never printed.
 *
 * r20: r19 probe never called fit(), so reverting the host-pixel lock was a
 * no-op. This file drives fit() like ResizeObserver. Pre-fix arm temporarily
 * strips the lock in TerminalView.js, then git-restores it.
 */
import { spawn, spawnSync } from 'node:child_process';
import { writeFileSync, readFileSync, mkdirSync, appendFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import WebSocket from 'ws';
import { Client } from '../../../src/vendor/agentmirror/client.js';
import { BINARY_KIND } from '../../../src/vendor/agentmirror/binary.js';
import { createResizeAnnouncer } from '../../../src/term/resizeAnnounce.js';

const here = dirname(fileURLToPath(import.meta.url));
const worktree = join(here, '../../..');
const viewFile = join(worktree, 'src/term/TerminalView.js');
const N = 20;
const PORT = process.env.AM_PROBE_PORT || '19912';
const BETWEEN_PASTE_ENTER_MS = 140;
const uid = process.getuid();
const sockDir = `/private/tmp/tmux-${uid}`;
const sock = join(sockDir, 'amrsz');
const gotLog = join(here, 'got.log');
const stateDir = join(here, 'dstate');
const daemonBin = '/Volumes/nvme/Projects/远程Agent安卓/server/agentmirrord';
const token = process.env.AGENTMIRROR_TOKEN;
if (!token) {
  console.error('missing AGENTMIRROR_TOKEN');
  process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sanitize = (s) => String(s).split(token).join('<token>');
const LOCK_LINES = `    if (!force && w === this._lastHostW && h === this._lastHostH) return;\n    this._lastHostW = w;\n    this._lastHostH = h;\n`;
const originalViewSrc = readFileSync(viewFile, 'utf8');

const tmux = (...args) => {
  const env = { ...process.env };
  delete env.TMUX;
  const r = spawnSync('tmux', args, { encoding: 'utf8', env });
  return { rc: r.status ?? 1, out: r.stdout || '', err: r.stderr || '' };
};

function restoreView() {
  writeFileSync(viewFile, originalViewSrc);
}

function stripPixelLock() {
  if (!originalViewSrc.includes(LOCK_LINES)) {
    throw new Error('host-pixel lock snippet not found in TerminalView.js');
  }
  writeFileSync(viewFile, originalViewSrc.replace(LOCK_LINES, '    // r20 pre-fix: host-pixel lock stripped\n'));
}

async function loadTerminalView(bust) {
  const href = `${pathToFileURL(viewFile).href}?bust=${bust}`;
  return import(href);
}

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

async function injectAll(onBetweenPasteAndEnter) {
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
    if (onBetweenPasteAndEnter) await onBetweenPasteAndEnter();
    else await sleep(BETWEEN_PASTE_ENTER_MS);
    const e = tmux('send-keys', '-t', 'amrsz', 'Enter');
    if (e.rc !== 0) throw new Error(`Enter ${e.err}`);
    await sleep(80);
  }
  await sleep(300);
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
  const errPath = join(here, 'daemon.stderr');
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
  child.stderr.on('data', (b) => {
    appendFileSync(errPath, sanitize(String(b)));
  });
  return { child, errPath };
}

function findAmrsz(client) {
  for (const s of client.sessionsByRef.values()) {
    if (s.name === 'amrsz') return s;
    if (typeof s.cwd === 'string' && s.cwd.includes('.team/nodes/resize')) return s;
    if (typeof s.ref === 'string' && s.ref.includes('/amrsz')) return s;
  }
  return null;
}

function makeJitterHost() {
  let ticks = 0;
  class FakeTerminal {
    constructor() {
      this.cols = 80;
      this.rows = 24;
      this.element = {
        querySelector: () => ({
          getBoundingClientRect: () => {
            ticks += 1;
            const j = ticks % 2 === 0 ? 0 : 16;
            return { width: this.cols * 8 + j, height: this.rows * 16 };
          },
        }),
      };
      this.buffer = { active: { viewportY: 0 } };
    }
    open() {}
    onScroll() { return { dispose() {} }; }
    onData() { return { dispose() {} }; }
    attachCustomKeyEventHandler() { return true; }
    resize(cols, rows) { this.cols = cols; this.rows = rows; }
    reset() {}
    write() {}
    focus() {}
    blur() {}
    scrollToBottom() {}
    dispose() {}
  }
  const container = {
    isConnected: true,
    clientWidth: 800,
    clientHeight: 400,
    addEventListener() {},
    removeEventListener() {},
  };
  return { FakeTerminal, container, ticks: () => ticks };
}

async function withSubscribe(TerminalView, rows, cols) {
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
      const names = [];
      for (const w of payload.workspaces || []) {
        for (const s of w.sessions || []) names.push(s.name);
      }
      appendFileSync(join(here, 'client-trace.txt'), `${type} hasAmrsz=${names.includes('amrsz')} nnames=${names.length}\n`);
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
  const jitter = makeJitterHost();
  const view = new TerminalView(jitter.container, {
    TerminalCtor: jitter.FakeTerminal,
    onResize: (r, c) => announcer.fromFit(r, c),
  });
  view.open();
  await sleep(180);

  client.onBinary = (frame) => {
    if (frame.kind === BINARY_KIND.SNAPSHOT) snapshots += 1;
  };
  client.connect();
  const t0 = Date.now();
  try {
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
        resizeCount = 0;
        const result = await injectAll(async () => {
          for (let k = 0; k < 6; k += 1) view.fit();
          await sleep(BETWEEN_PASTE_ENTER_MS);
        });
        return {
          ...result,
          resizeCount,
          snapshots,
          listedRows: sess.rows,
          listedCols: sess.cols,
          sessionName: sess.name,
          fitTicks: jitter.ticks(),
        };
      }
    }
    throw new Error('listing never contained amrsz (ready=' + client.isReady + ' sessions=' + client.sessionsByRef.size + ')');
  } finally {
    client.disconnect();
    announcer.dispose();
    view.dispose();
  }
}

const report = {
  n: N,
  port: PORT,
  betweenPasteEnterMs: BETWEEN_PASTE_ENTER_MS,
  notes: 'token via env AGENTMIRROR_TOKEN (generated). Session amrsz on default tmux server; kill-session amrsz only. r20 drives TerminalView.fit with cell-probe jitter between paste and Enter. Pre-fix arm strips host-pixel lock then restores the file.',
  taskDefinitionChange: 'BRIEF said run the same probe after reverting the lock. r19 probe never called fit(), so that would stay resizeCount=0 by construction. This round wires fit()+jitter (same WS subscribe + paste-buffer+Enter). Explicit, not silent.',
};

let daemon;
try {
  startTmux();
  await sleep(350);
  daemon = startDaemon();
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
  const control = await injectAll(null);
  report.control = {
    name: 'no_ws_subscribe',
    submitted: control.ok,
    failRate: control.failRate,
    missing: control.missing,
  };
  writeFileSync(join(here, 'ws-control.capture.txt'), control.capture);

  restoreView();
  const { TerminalView: ViewPost } = await loadTerminalView('post');
  const post = await withSubscribe(ViewPost, 24, 100);
  report.postFix = {
    name: 'subscribe_fit_pixel_lock_on',
    submitted: post.ok,
    failRate: post.failRate,
    missing: post.missing,
    resizeCount: post.resizeCount,
    snapshots: post.snapshots,
    listedRows: post.listedRows,
    listedCols: post.listedCols,
    sessionName: post.sessionName,
    fitTicks: post.fitTicks,
  };
  writeFileSync(join(here, 'ws-subscribed.capture.txt'), post.capture);

  stripPixelLock();
  const { TerminalView: ViewPre } = await loadTerminalView('pre');
  const pre = await withSubscribe(ViewPre, 24, 100);
  report.preFix = {
    name: 'subscribe_fit_pixel_lock_off',
    submitted: pre.ok,
    failRate: pre.failRate,
    missing: pre.missing,
    resizeCount: pre.resizeCount,
    snapshots: pre.snapshots,
    listedRows: pre.listedRows,
    listedCols: pre.listedCols,
    sessionName: pre.sessionName,
    fitTicks: pre.fitTicks,
  };
  writeFileSync(join(here, 'ws-pre-fix.capture.txt'), pre.capture);
} catch (e) {
  report.error = sanitize(e.message || String(e));
} finally {
  restoreView();
  if (daemon && daemon.child && daemon.child.pid) {
    try { process.kill(daemon.child.pid); } catch { /* gone */ }
  }
  try { stopTmux(); } catch { /* */ }
}

writeFileSync(join(here, 'ws-subscribe-probe.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({
  control: report.control,
  postFix: report.postFix,
  preFix: report.preFix,
  error: report.error || null,
}));
process.exit(report.error ? 1 : 0);
