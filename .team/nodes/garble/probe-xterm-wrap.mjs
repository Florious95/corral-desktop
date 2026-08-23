// Capture live snapshots at sweep geometry (39×114), label with detectGarble,
// then feed a real @xterm/xterm and read buffer isWrapped.
// Token is read from tauri store and never printed.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import WebSocket from '/Volumes/nvme/Projects/tmux桌面端/node_modules/ws/index.js';
import { decodeBinary, BINARY_KIND } from '../../../src/vendor/agentmirror/binary.js';
import { detectGarble } from '../../../src/term/garbleDetect.js';
import { Terminal } from '@xterm/xterm/lib/xterm.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const outDir = join(here, 'wrap-probe');
mkdirSync(outDir, { recursive: true });

const store = JSON.parse(readFileSync(
  `${homedir()}/Library/Application Support/com.agentmirror.desktop/devices.json`,
  'utf8',
));
const devs = Array.isArray(store) ? store : (store.devices ?? Object.values(store)[0]);
const dev = Array.isArray(devs) ? devs[0] : devs;
const URL0 = dev.url;
const TOKEN = dev.token;
if (!URL0 || !TOKEN) {
  console.error('no url/token in store (shape?)', Object.keys(dev || {}));
  process.exit(2);
}

function send(ws, type, payload) {
  ws.send(JSON.stringify({ v: 1, type, payload }));
}

function paneIdOf(ref) {
  const m = String(ref).match(/%\d+/);
  return m ? m[0] : 'unknown';
}

function nameHint(ref) {
  const s = String(ref);
  if (s.includes('ta-a9fd5b7defbd')) return 'pair-session';
  if (s.includes('/default')) return 'default-socket';
  return 'other';
}

function wrapStats(term) {
  const buf = term.buffer.active;
  let wrapped = 0;
  for (let i = 0; i < buf.length; i++) {
    const line = buf.getLine(i);
    if (line && line.isWrapped) wrapped += 1;
  }
  return { bufferLength: buf.length, wrappedLines: wrapped };
}

function feedXterm(bytes, cols, rows) {
  return new Promise((resolve) => {
    const term = new Terminal({
      cols, rows, scrollback: 2000, allowProposedApi: true, convertEol: false,
    });
    term.reset();
    term.write(bytes, () => {
      const stats = wrapStats(term);
      term.dispose();
      resolve(stats);
    });
  });
}

const ws = new WebSocket(URL0);
ws.binaryType = 'arraybuffer';
const sessions = [];
const snaps = new Map();
let listed = false;

ws.on('open', () => { console.error('ws open'); send(ws, 'auth', { token: TOKEN }); });
ws.on('message', (data, isBinary) => {
  const buf = Buffer.isBuffer(data) ? data : Buffer.from(data);
  const looksBinary = isBinary === true || (buf.length >= 2 && buf[0] === 0x52 && buf[1] === 0x41);
  if (looksBinary) {
    let frame;
    try { frame = decodeBinary(new Uint8Array(buf)); } catch { return; }
    if (frame.kind === BINARY_KIND.SNAPSHOT) snaps.set(frame.ref, frame.data);
    return;
  }
  let f;
  try { f = JSON.parse(buf.toString('utf8')); } catch { return; }
  if (f.type === 'auth_ack') {
    if (!f.payload?.ok) { console.error('AUTH REJECTED'); process.exit(3); }
    send(ws, 'list', { req_id: 1 });
  } else if (f.type === 'listing' && !listed) {
    listed = true;
    for (const w of f.payload?.workspaces ?? []) {
      for (const s of w.sessions ?? []) {
        if (s.ref && s.cols >= 1 && s.rows >= 1) sessions.push(s);
      }
    }
    run().catch((e) => { console.error(String(e && e.message ? e.message : e)); process.exit(3); });
  }
});
ws.on('error', (e) => { console.error('ws error', e.message); });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function grab(session, rows, cols) {
  snaps.delete(session.ref);
  send(ws, 'subscribe', { ref: session.ref, rows, cols });
  const t0 = Date.now();
  while (Date.now() - t0 < 4000) {
    if (snaps.has(session.ref)) break;
    await sleep(50);
  }
  const data = snaps.get(session.ref) || null;
  send(ws, 'unsubscribe', { ref: session.ref });
  await sleep(60);
  return data;
}

async function run() {
  const wanted = sessions.filter((s) => {
    const hint = nameHint(s.ref);
    const pane = paneIdOf(s.ref);
    return hint === 'pair-session' || (hint === 'default-socket' && pane === '%1');
  });
  const targets = wanted.length ? wanted : sessions.slice(0, 3);
  const rows = [];

  const wideFix = new Uint8Array(readFileSync(join(here, '../../../test/testdata/garble/wide-host.snapshot.bin')));
  const pos114 = await feedXterm(wideFix, 114, 39);
  const pos80 = await feedXterm(wideFix, 80, 24);
  const pos235 = await feedXterm(wideFix, 235, 50);

  for (const s of targets) {
    const data = await grab(s, 39, 114);
    const pane = paneIdOf(s.ref);
    const hint = nameHint(s.ref);
    if (!data) {
      rows.push({
        hint, pane, listing_cols: s.cols, listing_rows: s.rows,
        got: false,
      });
      continue;
    }
    const label = detectGarble({ snapshot: data, termCols: 114, termRows: 39 });
    const xterm114 = await feedXterm(data, 114, 39);
    const rec = {
      hint, pane,
      listing_cols: s.cols, listing_rows: s.rows,
      bytes: data.length,
      garbled: label.garbled,
      reasons: label.reasons,
      maxLineWidth: label.metrics.maxLineWidth,
      overwideLines: label.metrics.overwideLines,
      maxBoxRun: label.metrics.maxBoxRun,
      xterm114,
    };
    rows.push(rec);
    if (label.metrics.maxLineWidth === 115 || label.garbled) {
      writeFileSync(join(outDir, `${hint}-${pane.replace('%', 'p')}.snapshot.bin`), Buffer.from(data));
    }
  }

  const report = {
    captured_at: new Date().toISOString(),
    subscribe_geom: '39x114 (same as sweep headless)',
    positive_control: {
      file: 'test/testdata/garble/wide-host.snapshot.bin',
      xterm_114: pos114,
      xterm_80: pos80,
      xterm_235: pos235,
      gauge_ok: pos114.wrappedLines > 0 && pos80.wrappedLines > 0,
    },
    live: rows,
  };
  writeFileSync(join(outDir, 'report.json'), JSON.stringify(report, null, 2));
  console.error(`wrote report live=${rows.length} pos_wrapped_114=${pos114.wrappedLines}`);
  try { ws.close(); } catch { /* */ }
  process.exit(0);
}

setTimeout(() => { console.error('TIMEOUT'); process.exit(3); }, 30000);
