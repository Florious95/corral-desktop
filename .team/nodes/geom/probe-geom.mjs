#!/usr/bin/env node
/**
 * Two-headed clamp: legacy fit vs once-seed TerminalView (n=30).
 * Host arm: own daemon + amgeom; fit n=30 must not keep changing pane_width.
 * Token from AGENTMIRROR_TOKEN only; never printed.
 */
import { spawn, spawnSync } from 'node:child_process';
import { writeFileSync, appendFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';
import { Client } from '../../../src/vendor/agentmirror/client.js';
import { TerminalView, GRID_DEBOUNCE_MS } from '../../../src/term/TerminalView.js';

const here = dirname(fileURLToPath(import.meta.url));
const PORT = '19924';
const SESSION = 'amgeom';
const N = 30;
const stateDir = join(here, 'dstate');
const daemonBin = '/Volumes/nvme/Projects/远程Agent安卓/server/agentmirrord';
const token = process.env.AGENTMIRROR_TOKEN;
if (!token) {
  console.error('missing AGENTMIRROR_TOKEN');
  process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sanitize = (s) => String(s).split(token).join('<token>');

class FakeTerminal {
  constructor() {
    this.cols = 80;
    this.rows = 24;
    this.resizes = [];
    this.buffer = { active: { viewportY: 0 } };
    this.element = {
      querySelector: () => ({
        getBoundingClientRect: () => ({ width: this.cols * 8, height: this.rows * 16 }),
      }),
    };
  }
  open() {}
  onScroll() { return { dispose() {} }; }
  onData() { return { dispose() {} }; }
  attachCustomKeyEventHandler() { return true; }
  resize(cols, rows) { this.resizes.push([rows, cols]); this.cols = cols; this.rows = rows; }
  reset() {}
  write() {}
  focus() {}
  blur() {}
  scrollToBottom() {}
  dispose() {}
}

function makeContainer() {
  return {
    isConnected: true,
    clientWidth: 800,
    clientHeight: 400,
    scrollHeight: 400,
    scrollTop: 0,
    style: {},
    addEventListener() {},
    removeEventListener() {},
  };
}

/** Pre-fix: every fit() after first real size recomputes and resizes (old TerminalView). */
function legacyFitCount(n) {
  const reports = [];
  let cols = 80;
  let rows = 24;
  const seed = (w, h) => {
    const c = Math.max(2, Math.floor(w / 8));
    const r = Math.max(2, Math.floor(h / 16));
    if (c !== cols || r !== rows) {
      cols = c;
      rows = r;
      reports.push([rows, cols]);
    }
  };
  seed(800, 400);
  for (let i = 0; i < n; i += 1) {
    seed(i % 2 === 0 ? 400 : 800, 400);
  }
  return { reports: reports.length, last: reports[reports.length - 1], all: reports };
}

async function productFitCount(n) {
  const reports = [];
  const container = makeContainer();
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminal,
    onResize: (rows, cols) => reports.push([rows, cols]),
  });
  view.open();
  await sleep(GRID_DEBOUNCE_MS + 80);
  const afterSeed = reports.length;
  for (let i = 0; i < n; i += 1) {
    container.clientWidth = i % 2 === 0 ? 400 : 800;
    view.fit({ immediate: true });
  }
  await sleep(GRID_DEBOUNCE_MS + 80);
  const layout = view._layout;
  view.dispose();
  return { reports: reports.length, afterSeed, last: reports[reports.length - 1], layout };
}

const tmux = (...args) => {
  const env = { ...process.env };
  delete env.TMUX;
  const r = spawnSync('tmux', args, { encoding: 'utf8', env });
  return { rc: r.status ?? 1, out: r.stdout || '', err: r.stderr || '' };
};

function paneGeom() {
  return tmux('display-message', '-p', '-t', SESSION, '#{pane_width}x#{pane_height}').out.trim();
}

function startTmux() {
  tmux('kill-session', '-t', SESSION);
  const grokBin = join(here, 'grok');
  const built = spawnSync('cc', ['-O1', '-o', grokBin, join(here, 'grok-tui.c')], { encoding: 'utf8' });
  if ((built.status ?? 1) !== 0) throw new Error(`cc grok ${built.stderr}`);
  const r = tmux(
    'new-session', '-d', '-s', SESSION, '-n', SESSION, '-x', '80', '-y', '24',
    '-c', here, '--', grokBin, join(here, 'got.log'),
  );
  if (r.rc !== 0) throw new Error(`new-session ${r.err || r.out}`);
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
  child.stderr.on('data', (b) => appendFileSync(errPath, sanitize(String(b))));
  return child;
}

function findSess(client) {
  for (const s of client.sessionsByRef.values()) {
    if (s.name === SESSION) return s;
    if (typeof s.cwd === 'string' && s.cwd.includes('.team/nodes/geom')) return s;
  }
  return null;
}

async function hostArm() {
  const widths = [];
  const resizeFrames = [];
  const sendTypes = [];
  const client = new Client({
    url: `ws://127.0.0.1:${PORT}/ws`,
    token,
    wsFactory: (u) => {
      const sock = new WebSocket(u);
      return {
        get readyState() { return sock.readyState; },
        send(x) {
          try {
            const t = JSON.parse(String(x));
            sendTypes.push(t.type);
            if (t.type === 'resize') resizeFrames.push(t.payload);
          } catch { /* binary */ }
          sock.send(x);
        },
        close() { sock.close(); },
        set binaryType(_v) {},
        set onopen(fn) { sock.on('open', () => fn({})); },
        set onclose(fn) { sock.on('close', (code, reason) => fn({ code, reason: String(reason || '') })); },
        set onerror(fn) { sock.on('error', () => fn({})); },
        set onmessage(fn) {
          sock.on('message', (data, isBinary) => {
            if (isBinary) {
              const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
              fn({ data: new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength) });
            } else fn({ data: String(data) });
          });
        },
      };
    },
    backoff: { baseMs: 200, maxMs: 800, factor: 1.5, jitter: 0 },
  });
  const container = makeContainer();
  const reports = [];
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminal,
    onResize: (rows, cols) => {
      reports.push([rows, cols]);
    },
  });
  view.open();
  await sleep(GRID_DEBOUNCE_MS + 80);
  client.connect();
  const t0 = Date.now();
  try {
    while (Date.now() - t0 < 12000) {
      await sleep(200);
      if (!client.isReady) continue;
      const sess = findSess(client);
      if (!sess) continue;
      await sleep(1500);
      const before = paneGeom();
      client.subscribe(sess.ref, view.rows, view.cols);
      await sleep(600);
      const afterSub = paneGeom();
      for (let i = 0; i < N; i += 1) {
        container.clientWidth = i % 2 === 0 ? 400 : 800;
        view.fit({ immediate: true });
        widths.push(paneGeom());
        await sleep(40);
      }
      return {
        beforeSubscribe: before,
        afterSubscribe: afterSub,
        uniqueAfterSubscribe: [...new Set(widths)],
        onResizeCount: reports.length,
        protocolResizeCount: resizeFrames.length,
        sendTypes,
        termCols: view.cols,
      };
    }
    throw new Error('listing never contained amgeom');
  } finally {
    client.disconnect();
    view.dispose();
  }
}

const report = { n: N, port: PORT };
let daemon;
try {
  report.preFix = legacyFitCount(N);
  report.postFix = await productFitCount(N);
  startTmux();
  await sleep(350);
  daemon = startDaemon();
  for (let i = 0; i < 40; i += 1) {
    await sleep(150);
    if (daemon.exitCode != null) throw new Error('daemon exited ' + daemon.exitCode);
    const hit = spawnSync('lsof', ['-nP', `-iTCP:${PORT}`, '-sTCP:LISTEN'], { encoding: 'utf8' });
    if ((hit.status ?? 1) === 0 && hit.stdout.includes(String(PORT)) && hit.stdout.includes(String(daemon.pid))) break;
    if (i === 39) throw new Error('daemon never listened');
  }
  report.host = await hostArm();
} catch (e) {
  report.error = sanitize(e.message || String(e));
} finally {
  if (daemon && daemon.pid) {
    try { process.kill(daemon.pid); } catch { /* */ }
  }
  try { tmux('kill-session', '-t', SESSION); } catch { /* */ }
}

writeFileSync(join(here, 'geom-probe.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({
  error: report.error || null,
  preFixReports: report.preFix && report.preFix.reports,
  postFixReports: report.postFix && report.postFix.reports,
  host: report.host || null,
}));
process.exit(report.error ? 1 : 0);
