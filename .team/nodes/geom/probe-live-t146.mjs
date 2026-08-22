#!/usr/bin/env node
/**
 * Live tester-t146: subscribe only (no input). Token from AGENTMIRROR_TOKEN.
 */
import { spawn, spawnSync } from 'node:child_process';
import { writeFileSync, appendFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import WebSocket from 'ws';
import { Client } from '../../../src/vendor/agentmirror/client.js';
import { BINARY_KIND } from '../../../src/vendor/agentmirror/binary.js';
import { TerminalView, GRID_DEBOUNCE_MS } from '../../../src/term/TerminalView.js';

const here = dirname(fileURLToPath(import.meta.url));
const PORT = process.env.AM_PROBE_PORT || '19926';
const SOCK = '/tmp/tmux-501/ta-a9fd5b7defbd';
const PANE = '%88';
const FOLLOW = process.env.GEOM_FOLLOW === '1';
const token = process.env.AGENTMIRROR_TOKEN;
if (!token) {
  console.error('missing AGENTMIRROR_TOKEN');
  process.exit(2);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const sanitize = (s) => String(s).split(token).join('<token>');

function tmux(...args) {
  const env = { ...process.env };
  delete env.TMUX;
  const r = spawnSync('tmux', ['-S', SOCK, ...args], { encoding: 'utf8', env });
  return { rc: r.status ?? 1, out: r.stdout || '', err: r.stderr || '' };
}

function paneGeom() {
  return tmux('display-message', '-p', '-t', PANE, '#{pane_width}x#{pane_height}').out.trim();
}

function stripAnsi(s) {
  return String(s)
    .replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, '')
    .replace(/\x1b\][^\x07]*(?:\x07|\x1b\\)/g, '')
    .replace(/\r/g, '');
}

function wrapBadge(text, paintCols, badge) {
  const lines = stripAnsi(text).split('\n');
  let line = '';
  let lineIdx = -1;
  for (let i = 0; i < lines.length; i += 1) {
    if (!lines[i].includes(badge)) continue;
    const cells = [...lines[i]].length;
    if (cells > (line ? [...line].length : -1)) {
      line = lines[i];
      lineIdx = i;
    }
  }
  if (lineIdx < 0) {
    const dash = lines.findIndex((l) => l.includes('─') && l.length > 80);
    if (dash >= 0) {
      line = lines[dash];
      lineIdx = dash;
    }
  }
  if (lineIdx < 0) return { found: false, paintCols };
  const i = line.indexOf(badge);
  const cells = [...line].length;
  const visualRows = Math.max(1, Math.ceil(cells / paintCols));
  const badgeRow = i >= 0 ? Math.floor(i / paintCols) : -1;
  return {
    found: i >= 0,
    paintCols,
    hostLineIndex: lineIdx,
    hostLineCells: cells,
    badgeStartCell: i,
    visualRowsForLine: visualRows,
    badgeOnVisualRow: badgeRow,
    torn: i >= 0 && (badgeRow !== 0 || visualRows > 1),
  };
}

class FakeTerminal {
  constructor() {
    this.cols = 80;
    this.rows = 24;
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
  resize(c, r) { this.cols = c; this.rows = r; }
  reset() {}
  write() {}
  focus() {}
  blur() {}
  scrollToBottom() {}
  dispose() {}
}

function makeContainer(w, h) {
  return {
    isConnected: true,
    clientWidth: w,
    clientHeight: h,
    scrollHeight: h,
    scrollTop: 0,
    style: {},
    addEventListener() {},
    removeEventListener() {},
  };
}

function startDaemon() {
  const stateDir = join(here, 'dstate-live');
  mkdirSync(stateDir, { recursive: true });
  mkdirSync(join(stateDir, 'up'), { recursive: true });
  const errPath = join(here, 'daemon-live.stderr');
  writeFileSync(errPath, '');
  const child = spawn('/Volumes/nvme/Projects/远程Agent安卓/server/agentmirrord', [
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

function findT146(client) {
  const all = [];
  for (const s of client.sessionsByRef.values()) {
    all.push({
      name: s.name,
      cols: s.cols,
      rows: s.rows,
      cwd: typeof s.cwd === 'string' ? s.cwd.slice(-40) : '',
      refHas88: typeof s.ref === 'string' && s.ref.includes('%88'),
    });
    if (typeof s.ref === 'string' && s.ref.includes('%88')) return s;
  }
  report.listedAll = all;
  return null;
}

const report = {
  follow: FOLLOW,
  paneBefore: paneGeom(),
  captureWrap100: wrapBadge(tmux('capture-pane', '-t', PANE, '-p').out, 100, 'tester-t146'),
  captureWrap235: wrapBadge(tmux('capture-pane', '-t', PANE, '-p').out, 235, 'tester-t146'),
  chromeMcp: 'unavailable (only team_orchestrator in this seat)',
};

let daemon;
try {
  daemon = startDaemon();
  for (let i = 0; i < 40; i += 1) {
    await sleep(150);
    if (daemon.exitCode != null) throw new Error('daemon exited ' + daemon.exitCode);
    const hit = spawnSync('lsof', ['-nP', `-iTCP:${PORT}`, '-sTCP:LISTEN'], { encoding: 'utf8' });
    if ((hit.status ?? 1) === 0 && hit.stdout.includes(String(PORT)) && hit.stdout.includes(String(daemon.pid))) break;
    if (i === 39) throw new Error('daemon never listened');
  }

  const reports = [];
  const view = new TerminalView(makeContainer(800, 400), {
    TerminalCtor: FakeTerminal,
    onResize: (rows, cols) => reports.push([rows, cols]),
  });
  view.open();
  await sleep(GRID_DEBOUNCE_MS + 80);

  const snaps = [];
  const client = new Client({
    url: `ws://127.0.0.1:${PORT}/ws`,
    token,
    wsFactory: (u) => {
      const sock = new WebSocket(u);
      return {
        get readyState() { return sock.readyState; },
        send(x) { sock.send(x); },
        close() { sock.close(); },
        set binaryType(_v) {},
        set onopen(fn) { sock.on('open', () => fn({})); },
        set onclose(fn) { sock.on('close', (c, r) => fn({ code: c, reason: String(r || '') })); },
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
  client.onBinary = (frame) => {
    if (frame.kind !== BINARY_KIND.SNAPSHOT) return;
    const text = Buffer.from(frame.data).toString('utf8');
    snaps.push({ bytes: frame.data.length, text, wrap100: wrapBadge(text, 100, 'tester-t146'), wrap235: wrapBadge(text, 235, 'tester-t146') });
    view.writeSnapshot(frame.data);
  };
  client.connect();
  const t0 = Date.now();
  while (Date.now() - t0 < 15000) {
    await sleep(200);
    if (!client.isReady) continue;
    const sess = findT146(client);
    if (!sess) continue;
    await sleep(1500);
    const live = paneGeom();
    const [lw, lh] = live.split('x').map(Number);
    report.listed = { rows: sess.rows, cols: sess.cols, name: sess.name, refHas88: true };
    report.seeded = { rows: view.rows, cols: view.cols, onResize: reports.length };
    report.paneBeforeSubscribe = live;
    const subRows = (Number.isFinite(lh) && lh > 0) ? lh : sess.rows;
    const subCols = (Number.isFinite(lw) && lw > 0) ? lw : sess.cols;
    if (FOLLOW && typeof view.followHostGrid === 'function') {
      view.followHostGrid(subCols, subRows);
    } else if (FOLLOW) {
      view.term.resize(subCols, subRows);
    }
    report.subscribeSent = { rows: subRows, cols: subCols, mode: FOLLOW ? 'follow-host' : 'match-live-geom-no-shrink' };
    client.subscribe(sess.ref, subRows, subCols);
    for (let w = 0; w < 25 && snaps.length === 0; w += 1) await sleep(100);
    report.paneAfterSubscribe = paneGeom();
    report.termAfter = { rows: view.rows, cols: view.cols };
    report.snapshot = snaps[0] || null;
    report.tornAtTermCols = snaps[0]
      ? wrapBadge(Buffer.from([]).toString(), view.cols, 'tester-t146')
      : null;
    if (snaps[0]) {
      const text = null;
      report.wrapAtTermCols = wrapBadge(
        // re-wrap from stored fields
        'x',
        view.cols,
        'tester-t146',
      );
    }
    const cap = tmux('capture-pane', '-t', PANE, '-p').out;
    report.wrapLiveSnapshotAtTerm = snaps[0]
      ? (snaps[0].wrap100.paintCols === view.cols ? snaps[0].wrap100
        : snaps[0].wrap235.paintCols === view.cols ? snaps[0].wrap235
          : wrapBadge(cap, view.cols, 'tester-t146'))
      : wrapBadge(cap, view.cols, 'tester-t146');
    if (snaps[0]) {
      report.snapWrap100 = snaps[0].wrap100;
      report.snapWrap235 = snaps[0].wrap235;
      report.wrapAtTermCols = wrapBadge(snaps[0].text, view.cols, 'tester-t146');
    }
    // parent-vs-#54: 800px canvas vs 1880px canvas on the same snapshot wrap tables
    report.abc = {
      at800px_termWouldBe: 100,
      tornIfLocked100: snaps[0] ? snaps[0].wrap100.torn : report.captureWrap100.torn,
      at1880px_parentFitCols: Math.floor(1880 / 8),
      tornIfFollow235: snaps[0] ? snaps[0].wrap235.torn : report.captureWrap235.torn,
    };
    client.disconnect();
    view.dispose();
    break;
  }
  if (!report.subscribeSent) throw new Error('tester-t146 not in listing');
} catch (e) {
  report.error = sanitize(e.message || String(e));
} finally {
  if (daemon && daemon.pid) {
    try { process.kill(daemon.pid); } catch { /* */ }
  }
}

writeFileSync(join(here, FOLLOW ? 'live-t146-post.json' : 'live-t146-pre.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify({
  error: report.error || null,
  paneBefore: report.paneBefore,
  paneAfter: report.paneAfterSubscribe,
  listed: report.listed,
  seeded: report.seeded,
  subscribeSent: report.subscribeSent,
  termAfter: report.termAfter,
  snapWrap100: report.snapWrap100,
  snapWrap235: report.snapWrap235,
  abc: report.abc,
}));
process.exit(report.error ? 1 : 0);
