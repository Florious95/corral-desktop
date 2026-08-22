/*
 * Headless-ish session sweep via Chrome DevTools Protocol.
 * Clicks use Runtime.evaluate → HTMLElement.click() (DOM), never CGEvent/HID.
 *
 * Usage:
 *   node scripts/garble-sweep.mjs [--rounds N] [--out path] [--timeout-ms 8000]
 *        [--port 1437] [--cdp 9333] [--app-root <dir>] [--skip-self-check]
 *
 * Web app is served from APP_ROOT (default: sibling wt-inst) because this
 * worktree cannot write src/ and __amDiag lives in the t.inst tree.
 */
import { spawn } from 'node:child_process';
import { createWriteStream, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import WebSocket from '/Volumes/nvme/Projects/tmux桌面端/node_modules/ws/index.js';

export const DEFAULT_TIMEOUT_MS = 8000;
export const DEVICES_KEY = 'agentmirror.desktop.v1.devices';

const here = dirname(fileURLToPath(import.meta.url));
const WT = join(here, '..');
const DEFAULT_APP_ROOT = resolve(WT, '../wt-inst');
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const WS_PKG_OK = true;

export function loadPairing() {
  const store = JSON.parse(readFileSync(
    `${homedir()}/Library/Application Support/com.agentmirror.desktop/devices.json`,
    'utf8',
  ));
  const devs = Array.isArray(store) ? store : (store.devices ?? []);
  const dev = Array.isArray(devs) ? devs[0] : devs;
  if (!dev?.url || !dev?.token) throw new Error('pairing missing url/token');
  return { url: dev.url, token: dev.token, name: dev.name || 'Local', id: dev.id || 'local' };
}

export function lastListingPane(events, protoRef) {
  let hit = null;
  for (const ev of events) {
    if (ev.type !== 'listing' && ev.type !== 'list_delta') continue;
    for (const p of ev.panes || []) {
      if (p.ref === protoRef) hit = p;
    }
  }
  return hit;
}

export function lastGarble(events, protoRef) {
  let hit = null;
  for (const ev of events) {
    if (ev.type === 'garble_label' && ev.ref === protoRef) hit = ev;
  }
  return hit;
}

export function parseGeom(geom) {
  if (typeof geom !== 'string') return { rows: null, cols: null };
  const m = geom.match(/^(\d+)x(\d+)$/);
  return m ? { rows: Number(m[1]), cols: Number(m[2]) } : { rows: null, cols: null };
}

export function mergeSettle(dump, uid, protoRef) {
  const a = (dump.settle && dump.settle[uid]) || {};
  const b = (dump.settle && dump.settle[protoRef]) || {};
  const t0 = a.t0 ?? b.t0 ?? null;
  const t_sub_sent = b.t_sub_sent ?? a.t_sub_sent ?? null;
  const t_snap_first = b.t_snap_first ?? a.t_snap_first ?? null;
  const t_last_resize = b.t_last_resize ?? a.t_last_resize ?? null;
  const t_stable = b.t_stable ?? a.t_stable ?? null;
  const settle_ms = t0 != null && t_stable != null ? t_stable - t0 : null;
  return {
    t0, t_sub_sent, t_snap_first, t_last_resize, t_stable, settle_ms,
    click_to_sub: t0 != null && t_sub_sent != null ? t_sub_sent - t0 : null,
    sub_to_snap: t_sub_sent != null && t_snap_first != null ? t_snap_first - t_sub_sent : null,
    snap_to_last_resize: t_snap_first != null && t_last_resize != null ? t_last_resize - t_snap_first : null,
    last_resize_to_stable: t_last_resize != null && t_stable != null ? t_stable - t_last_resize : null,
  };
}

export function rowFromDump({ round, uid, protoRef, dump, timedOut, now = Date.now() }) {
  const events = dump.events || [];
  const label = lastGarble(events, protoRef);
  const listing = lastListingPane(events, protoRef);
  const geom = parseGeom(label?.geom);
  const seg = mergeSettle(dump, uid, protoRef);
  return {
    round,
    session_uid: uid,
    session_ref: protoRef,
    garbled: label ? !!label.garbled : null,
    reasons: label?.reasons || [],
    settle_ms: seg.settle_ms,
    t0: seg.t0,
    t_sub_sent: seg.t_sub_sent,
    t_snap_first: seg.t_snap_first,
    t_last_resize: seg.t_last_resize,
    t_stable: seg.t_stable,
    click_to_sub: seg.click_to_sub,
    sub_to_snap: seg.sub_to_snap,
    snap_to_last_resize: seg.snap_to_last_resize,
    last_resize_to_stable: seg.last_resize_to_stable,
    local_rows: geom.rows,
    local_cols: geom.cols,
    listing_rows: listing?.rows ?? null,
    listing_cols: listing?.cols ?? null,
    timed_out: !!timedOut,
    ts: now,
  };
}

function parseArgs(argv) {
  const out = {
    rounds: 1,
    timeoutMs: DEFAULT_TIMEOUT_MS,
    port: 1437,
    cdp: 9333,
    appRoot: DEFAULT_APP_ROOT,
    out: join(WT, '.team/nodes/garble/sweep-sample.jsonl'),
    skipSelfCheck: false,
    selfCheckOnly: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    const n = () => argv[++i];
    if (a === '--rounds') out.rounds = Number(n());
    else if (a === '--timeout-ms') out.timeoutMs = Number(n());
    else if (a === '--port') out.port = Number(n());
    else if (a === '--cdp') out.cdp = Number(n());
    else if (a === '--app-root') out.appRoot = resolve(n());
    else if (a === '--out') out.out = resolve(n());
    else if (a === '--skip-self-check') out.skipSelfCheck = true;
    else if (a === '--self-check-only') out.selfCheckOnly = true;
  }
  return out;
}

class CdpTab {
  constructor(wsUrl) {
    this.wsUrl = wsUrl;
    this.ws = null;
    this.id = 0;
    this.pending = new Map();
  }
  async open() {
    this.ws = new WebSocket(this.wsUrl);
    await new Promise((res, rej) => {
      this.ws.once('open', res);
      this.ws.once('error', rej);
    });
    this.ws.on('message', (raw) => {
      let msg;
      try { msg = JSON.parse(raw.toString()); } catch { return; }
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(msg.error.message || 'cdp error'));
        else resolve(msg.result);
      }
    });
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  async evaluate(expression) {
    const r = await this.send('Runtime.evaluate', {
      expression,
      awaitPromise: true,
      returnByValue: true,
    });
    if (r.exceptionDetails) {
      const t = r.exceptionDetails.exception?.description || r.exceptionDetails.text;
      throw new Error(`evaluate: ${t}`);
    }
    return r.result?.value;
  }
  close() {
    try { this.ws?.close(); } catch { /* */ }
  }
}

async function waitHttpOk(url, ms) {
  const t0 = Date.now();
  while (Date.now() - t0 < ms) {
    try {
      const r = await fetch(url);
      if (r.ok || r.status === 404 || r.status === 200) return;
    } catch { /* not up */ }
    await sleep(150);
  }
  throw new Error(`timeout waiting ${url}`);
}

async function pickFreePort(preferred) {
  const { createServer } = await import('node:net');
  return await new Promise((resolve) => {
    const s = createServer();
    s.listen(preferred, '127.0.0.1', () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
    s.on('error', () => {
      const s2 = createServer();
      s2.listen(0, '127.0.0.1', () => {
        const { port } = s2.address();
        s2.close(() => resolve(port));
      });
    });
  });
}

function spawnLogged(cmd, args, opts) {
  const child = spawn(cmd, args, { ...opts, stdio: ['ignore', 'pipe', 'pipe'] });
  child.stdout.on('data', () => {});
  child.stderr.on('data', () => {});
  return child;
}

async function jsonGet(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`${url} ${r.status}`);
  return r.json();
}

export async function main(argv = process.argv.slice(2)) {
  if (!WS_PKG_OK) throw new Error('ws missing');
  const opt = parseArgs(argv);
  mkdirSync(dirname(opt.out), { recursive: true });
  const chromeDir = join(WT, '.team/nodes/garble/chrome-profile');
  mkdirSync(chromeDir, { recursive: true });

  opt.port = await pickFreePort(opt.port);
  opt.cdp = await pickFreePort(opt.cdp);

  const kids = [];
  const origin = `http://127.0.0.1:${opt.port}`;
  let tab;
  const notes = {
    app_root: opt.appRoot,
    origin,
    cdp: opt.cdp,
    timeout_ms: opt.timeoutMs,
    session_count: 0,
    self_check: {},
  };

  const pairing = loadPairing();

  try {
    const viteBin = '/Volumes/nvme/Projects/tmux桌面端/node_modules/.bin/vite';
    const vite = spawnLogged(viteBin, ['--host', '127.0.0.1', '--port', String(opt.port), '--strictPort'], {
      cwd: opt.appRoot,
      env: { ...process.env, BROWSER: 'none' },
    });
    kids.push(vite);
    await waitHttpOk(origin, 20000);

    const chrome = spawnLogged(CHROME, [
      `--remote-debugging-port=${opt.cdp}`,
      `--user-data-dir=${chromeDir}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--disable-sync',
      '--disable-extensions',
      '--headless=new',
      `--window-size=1100,800`,
      'about:blank',
    ], { cwd: chromeDir });
    kids.push(chrome);
    await waitHttpOk(`http://127.0.0.1:${opt.cdp}/json/version`, 20000);

    const created = await fetch(`http://127.0.0.1:${opt.cdp}/json/new?${origin}/`, { method: 'PUT' });
    const target = await created.json();
    const wsUrl = target.webSocketDebuggerUrl;
    if (!wsUrl) throw new Error('no tab websocket');
    tab = new CdpTab(wsUrl);
    await tab.open();
    await tab.send('Runtime.enable');
    await tab.send('Page.enable');
    await sleep(400);

    const devicesJson = JSON.stringify([{
      id: pairing.id, name: pairing.name, url: pairing.url, token: pairing.token,
    }]);
    await tab.evaluate(
      `(() => { localStorage.setItem(${JSON.stringify(DEVICES_KEY)}, ${JSON.stringify(devicesJson)}); location.reload(); return 'paired'; })()`,
    );
    await sleep(800);
    await waitForRows(tab, 25000);

    const agents = await listAgents(tab);
    notes.session_count = agents.length;
    if (agents.length === 0) throw new Error('listing produced zero agents');

    const sampleRows = [];

    if (!opt.skipSelfCheck) {
      notes.self_check = await runSelfCheck(tab, agents, opt, pairing);
    }

    if (opt.selfCheckOnly) {
      writeFileSync(
        join(WT, '.team/nodes/garble/harness-run.json'),
        JSON.stringify(notes, null, 2),
      );
      console.error(`self-check-only sessions_listed=${agents.length}`);
      return notes;
    }

    const out = createWriteStream(opt.out, { flags: 'w' });
    for (let round = 1; round <= opt.rounds; round++) {
      for (const ag of agents) {
        const row = await probeOne(tab, ag, round, opt.timeoutMs);
        out.write(`${JSON.stringify(row)}\n`);
        sampleRows.push(row);
      }
    }
    out.end();
    await new Promise((res) => out.on('finish', res));

    notes.sample_rows = sampleRows.length;
    notes.out = opt.out;
    writeFileSync(
      join(WT, '.team/nodes/garble/harness-run.json'),
      JSON.stringify(notes, null, 2),
    );
    console.error(`sweep rows=${sampleRows.length} sessions=${agents.length} rounds=${opt.rounds} out=${opt.out}`);
    return notes;
  } finally {
    try { tab?.close(); } catch { /* */ }
    for (const k of kids) {
      try { if (k.pid) process.kill(k.pid, 'SIGTERM'); } catch { /* */ }
    }
    await sleep(300);
    for (const k of kids) {
      try { if (k.pid) process.kill(k.pid, 'SIGKILL'); } catch { /* */ }
    }
  }
}

async function waitForRows(tab, ms) {
  const t0 = Date.now();
  let last = 0;
  while (Date.now() - t0 < ms) {
    const n = await tab.evaluate(`document.querySelectorAll('.agents-row').length`);
    if (n > 0 && n === last) return n;
    last = n;
    await sleep(400);
  }
  const n = await tab.evaluate(`document.querySelectorAll('.agents-row').length`);
  if (n > 0) return n;
  throw new Error('no .agents-row after pairing');
}

async function listAgents(tab) {
  return tab.evaluate(`([...document.querySelectorAll('.agents-row')].map((el, i) => {
    const title = el.querySelector('.agents-row-title')?.textContent || '';
    const reactKey = el.getAttribute('data-key');
    return { index: i, title, top: el.style.top };
  }))`);
}

async function clickIndex(tab, index) {
  await tab.evaluate(`(() => {
    const el = document.querySelectorAll('.agents-row')[${Number(index)}];
    if (!el) throw new Error('missing row');
    el.scrollIntoView({ block: 'nearest' });
    el.click();
    return 'clicked';
  })()`);
}

async function dumpDiag(tab) {
  return tab.evaluate(`(() => {
    if (!window.__amDiag) return { missing: true, events: [], settle: {} };
    window.__amDiag.dump ? null : null;
    return window.__amDiag.dump();
  })()`);
}

async function resetDiag(tab) {
  await tab.evaluate(`(() => { window.__amDiag && window.__amDiag.reset && window.__amDiag.reset(); return 'ok'; })()`);
}

async function probeOne(tab, ag, round, timeoutMs) {
  await resetDiag(tab);
  await clickIndex(tab, ag.index);
  const t0 = Date.now();
  let dump = { events: [], settle: {} };
  while (Date.now() - t0 < timeoutMs) {
    dump = await dumpDiag(tab);
    if (dump.missing) throw new Error('window.__amDiag missing (app root must be instrumented wt-inst)');
    const activate = [...(dump.events || [])].reverse().find((e) => e.type === 'activate');
    const uid = activate?.ref;
    const proto = inferProtoRef(dump, uid);
    const label = lastGarble(dump.events || [], proto);
    const snap = (dump.events || []).some((e) => e.type === 'snapshot' && (!proto || e.ref === proto));
    if (snap && label) break;
    await sleep(80);
  }
  dump = await dumpDiag(tab);
  const activate = [...(dump.events || [])].reverse().find((e) => e.type === 'activate');
  const uid = activate?.ref || `unknown:${ag.index}`;
  const proto = inferProtoRef(dump, uid);
  const timedOut = mergeSettle(dump, uid, proto).t_stable == null;
  return rowFromDump({ round, uid, protoRef: proto, dump, timedOut });
}

function inferProtoRef(dump, uid) {
  const events = dump.events || [];
  const sub = events.find((e) => e.type === 'subscribe' && e.sent);
  if (sub?.ref) return sub.ref;
  const snap = events.find((e) => e.type === 'snapshot');
  if (snap?.ref) return snap.ref;
  const g = events.find((e) => e.type === 'garble_label');
  if (g?.ref) return g.ref;
  if (typeof uid === 'string' && uid.includes('::')) return uid.slice(uid.indexOf('::') + 2);
  return uid;
}

async function runSelfCheck(tab, agents, opt, pairing) {
  const result = { good: null, bad: null };

  // Good: first real session, unmodified subscribe (daemon reshape → local geom).
  const goodAg = agents[0];
  const goodRow = await probeOne(tab, goodAg, 0, opt.timeoutMs);
  result.good = {
    session_ref: goodRow.session_ref,
    garbled: goodRow.garbled,
    reasons: goodRow.reasons,
    local_cols: goodRow.local_cols,
    listing_cols: goodRow.listing_cols,
    settle_ms: goodRow.settle_ms,
    timed_out: goodRow.timed_out,
  };

  // Bad: patch Client.subscribe to declare 235×50 while the headless viewport
  // stays ~1100px (local grid ≪ 235). Snapshot is host-width into a narrow xterm.
  // Uses our click on a listed session (same product path as the sweep).
  await tab.evaluate(`(() => {
    if (WebSocket.prototype.__amSweepOrigSend) return 'already';
    WebSocket.prototype.__amSweepOrigSend = WebSocket.prototype.send;
    WebSocket.prototype.send = function(data) {
      if (typeof data === 'string') {
        try {
          const f = JSON.parse(data);
          if (f && f.type === 'subscribe' && f.payload) {
            f.payload.rows = 50;
            f.payload.cols = 235;
            data = JSON.stringify(f);
          }
        } catch { /* not json */ }
      }
      return WebSocket.prototype.__amSweepOrigSend.call(this, data);
    };
    return 'hooked';
  })()`);

  const badAg = agents.find((a, i) => i !== goodAg.index) || goodAg;
  const badRow = await probeOne(tab, badAg, 0, opt.timeoutMs);
  result.bad = {
    session_ref: badRow.session_ref,
    garbled: badRow.garbled,
    reasons: badRow.reasons,
    local_cols: badRow.local_cols,
    listing_cols: badRow.listing_cols,
    settle_ms: badRow.settle_ms,
    timed_out: badRow.timed_out,
    method: 'WebSocket.send rewrite subscribe → 235×50 + DOM click',
  };

  await tab.evaluate(`(() => {
    if (WebSocket.prototype.__amSweepOrigSend) {
      WebSocket.prototype.send = WebSocket.prototype.__amSweepOrigSend;
      delete WebSocket.prototype.__amSweepOrigSend;
    }
    return 'unhooked';
  })()`);

  // In-page labeler on t.inst wide fixture as a second tooth if live path stayed green.
  if (result.bad.garbled !== true) {
    const fixturePath = join(opt.appRoot, 'test/testdata/garble/wide-host.snapshot.bin');
    let bytes;
    try { bytes = [...readFileSync(fixturePath)]; } catch { bytes = null; }
    if (bytes) {
      const lab = await tab.evaluate(`(async () => {
        const m = await import('/src/term/garbleDetect.js');
        const u8 = new Uint8Array(${JSON.stringify(bytes)});
        return m.detectGarble({ snapshot: u8, termCols: 80, termRows: 24 });
      })()`);
      result.bad_fixture = {
        garbled: lab.garbled,
        reasons: lab.reasons,
        method: 'detectGarble(wide-host.snapshot.bin, 80×24) via Vite import',
      };
    }
  }

  writeFileSync(
    join(WT, '.team/nodes/garble/self-check.json'),
    JSON.stringify(result, null, 2),
  );
  return result;
}

const launchedAsMain = process.argv[1]
  && pathToFileURL(resolve(process.argv[1])).href === import.meta.url;
if (launchedAsMain) {
  main().then(() => process.exit(0)).catch((e) => {
    console.error(e.message || e);
    process.exit(1);
  });
}
