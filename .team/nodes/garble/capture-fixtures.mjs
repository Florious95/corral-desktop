// Capture real snapshot payloads from a live daemon. Token never printed.
// Usage: node capture-fixtures.mjs
// Writes test/testdata/garble/*.snapshot.bin + fixture-source.json (no secrets).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import WebSocket from '/Volumes/nvme/Projects/tmux桌面端/node_modules/ws/index.js';
import { decodeBinary, BINARY_KIND } from '../../../src/vendor/agentmirror/binary.js';

const here = dirname(fileURLToPath(import.meta.url));
const wt = join(here, '../../..');
const outDir = join(wt, 'test/testdata/garble');
const metaPath = join(here, 'fixture-source.json');

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

function maxLineWidth(u8) {
  const text = new TextDecoder('utf-8', { fatal: false }).decode(u8)
    .replace(/\x1b(?:\[[0-?]*[ -/]*[@-~]|].*?(?:\x07|\x1b\\)|.)/gs, '');
  let max = 0;
  for (const line of text.replace(/\r/g, '').split('\n')) {
    const s = line.replace(/\s+$/g, '');
    let w = 0;
    for (const ch of s) w += 1;
    if (w > max) max = w;
  }
  return max;
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
    run().catch((e) => { console.error(e.message); process.exit(3); });
  } else if (f.type === 'error') {
    console.error('error frame (no payload dump)');
  }
});
ws.on('error', (e) => { console.error('ws error', e.message); });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function grab(session) {
  snaps.delete(session.ref);
  send(ws, 'subscribe', { ref: session.ref, rows: session.rows, cols: session.cols });
  const t0 = Date.now();
  while (Date.now() - t0 < 4000) {
    if (snaps.has(session.ref)) break;
    await sleep(50);
  }
  const data = snaps.get(session.ref) || null;
  send(ws, 'unsubscribe', { ref: session.ref });
  await sleep(80);
  return data;
}

async function run() {
  if (sessions.length === 0) {
    console.error('listing empty');
    process.exit(3);
  }
  sessions.sort((a, b) => b.cols - a.cols);
  const wide = sessions[0];
  const matched = sessions.find((s) => s.cols <= 120 && s.ref !== wide.ref) || sessions[sessions.length - 1];

  const wideBytes = await grab(wide);
  const matchBytes = await grab(matched);
  if (!wideBytes || !matchBytes) {
    writeFileSync(metaPath, JSON.stringify({
      ok: false,
      reason: 'snapshot timeout',
      wide_got: !!wideBytes,
      match_got: !!matchBytes,
      wide_listing: { pane: paneIdOf(wide.ref), cols: wide.cols, rows: wide.rows },
      match_listing: { pane: paneIdOf(matched.ref), cols: matched.cols, rows: matched.rows },
    }, null, 2));
    try { ws.close(); } catch { /* */ }
    process.exit(3);
  }

  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, 'wide-host.snapshot.bin'), Buffer.from(wideBytes));
  writeFileSync(join(outDir, 'matched-host.snapshot.bin'), Buffer.from(matchBytes));
  const meta = {
    ok: true,
    captured_at: new Date().toISOString(),
    host: 'local daemon via tauri devices.json (token not stored here)',
    subscribe_geom: 'listing.rows x listing.cols (reshape no-op when already matching)',
    wide: {
      file: 'test/testdata/garble/wide-host.snapshot.bin',
      pane: paneIdOf(wide.ref),
      listing_cols: wide.cols,
      listing_rows: wide.rows,
      bytes: wideBytes.length,
      stripped_max_line: maxLineWidth(wideBytes),
    },
    matched: {
      file: 'test/testdata/garble/matched-host.snapshot.bin',
      pane: paneIdOf(matched.ref),
      listing_cols: matched.cols,
      listing_rows: matched.rows,
      bytes: matchBytes.length,
      stripped_max_line: maxLineWidth(matchBytes),
    },
  };
  writeFileSync(metaPath, JSON.stringify(meta, null, 2));
  console.error(`wrote wide ${wideBytes.length}B pane=${meta.wide.pane} ${wide.cols}x${wide.rows}`);
  console.error(`wrote match ${matchBytes.length}B pane=${meta.matched.pane} ${matched.cols}x${matched.rows}`);
  try { ws.close(); } catch { /* */ }
  process.exit(0);
}

setTimeout(() => { console.error('TIMEOUT'); process.exit(3); }, 20000);
