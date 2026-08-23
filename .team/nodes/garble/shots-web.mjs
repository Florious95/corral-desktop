/**
 * t.evidence: per-session Web screenshot + __amDiag.dump(), same run.
 * Viewport 1400x860. CDP DOM click only (no HID).
 *
 * Subscribe uses listing host geom when window.__amSubscribeAtHost is set
 * (product hook, default off) so daemon reshape is a no-op. Gate still notes
 * the fitted grid so paint proceeds. tmux geom is read before/after each click.
 *
 * ⛔ does not print token. ⛔ does not write pane text.
 */
import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { spawn } from 'node:child_process';
import net from 'node:net';
import { setTimeout as sleep } from 'node:timers/promises';
import WebSocket from '/Volumes/nvme/Projects/tmux桌面端/node_modules/ws/index.js';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const SOCKDIR = '/tmp/tmux-501';
const DEVICES_KEY = 'agentmirror.desktop.v1.devices';
const WT = '/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-evid';

function arg(name, dflt) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : dflt;
}

const ORIGIN = arg('--origin', 'http://127.0.0.1:1430');
const OUT = arg('--out', join(WT, '.team/nodes/garble/shots-web'));
const W = Number(arg('--w', '1400'));
const H = Number(arg('--h', '860'));
const CDP = Number(arg('--cdp', '0'));
const CHROME_DIR = arg('--chrome-dir', join(WT, '.team/nodes/garble/chrome-profile-web'));

function loadPairing() {
  const store = JSON.parse(readFileSync(
    `${homedir()}/Library/Application Support/com.agentmirror.desktop/devices.json`,
    'utf8',
  ));
  const devs = Array.isArray(store) ? store : (store.devices ?? []);
  const dev = Array.isArray(devs) ? devs[0] : devs;
  if (!dev?.url || !dev?.token) throw new Error('pairing missing url/token');
  return { url: dev.url, token: dev.token, name: dev.name || 'Local', id: dev.id || 'local' };
}

function envNoTmux() {
  const env = { ...process.env };
  delete env.TMUX;
  return env;
}

function sh(cmd, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { env: envNoTmux(), stdio: ['ignore', 'pipe', 'pipe'] });
    const chunks = [];
    let err = '';
    child.stdout.on('data', (d) => chunks.push(d));
    child.stderr.on('data', (d) => { err += d; });
    child.on('error', reject);
    child.on('exit', (code) => resolve({ code, out: Buffer.concat(chunks).toString('utf8'), err }));
  });
}

function parseRef(ref) {
  if (!ref) return { socket: '', pane: '' };
  const i = ref.indexOf('\x1f');
  if (i < 0) return { socket: '', pane: ref };
  return { socket: ref.slice(0, i), pane: ref.slice(i + 1) };
}

function socketPath(socket) {
  if (!socket) return '';
  if (socket.startsWith('/')) return socket;
  return join(SOCKDIR, socket);
}

async function tmuxGeom(socket, pane) {
  const sock = socketPath(socket);
  if (!sock || !pane || !existsSync(sock)) return { ok: false, geom: '', err: 'no-socket' };
  const r = await sh('tmux', ['-S', sock, 'display-message', '-p', '-t', pane, '#{pane_width}x#{pane_height}']);
  if (r.code !== 0) return { ok: false, geom: '', err: (r.err || r.out).trim().slice(0, 80) };
  return { ok: true, geom: r.out.trim(), err: '' };
}

function portFree(port) {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.once('error', () => resolve(false));
    srv.once('listening', () => { srv.close(() => resolve(true)); });
    srv.listen(port, '127.0.0.1');
  });
}

async function pickPort(lo, hi) {
  for (let p = lo; p < hi; p++) {
    if (await portFree(p)) return p;
  }
  throw new Error(`no free port ${lo}-${hi - 1}`);
}

class Tab {
  constructor(u) { this.u = u; this.id = 0; this.p = new Map(); }
  async open() {
    this.ws = new WebSocket(this.u);
    await new Promise((res, rej) => { this.ws.once('open', res); this.ws.once('error', rej); });
    this.ws.on('message', (raw) => {
      let m; try { m = JSON.parse(raw.toString()); } catch { return; }
      if (m.id && this.p.has(m.id)) {
        const { resolve, reject } = this.p.get(m.id); this.p.delete(m.id);
        m.error ? reject(new Error(m.error.message)) : resolve(m.result);
      }
    });
  }
  send(method, params = {}) {
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.p.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  async evaluate(expression) {
    const r = await this.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true });
    if (r.exceptionDetails) {
      throw new Error('evaluate: ' + (r.exceptionDetails.exception?.description || r.exceptionDetails.text));
    }
    return r.result?.value;
  }
}

async function waitOk(url, ms) {
  const t0 = Date.now();
  for (;;) {
    try { const r = await fetch(url); if (r.ok) return; } catch { /* */ }
    if (Date.now() - t0 > ms) throw new Error('timeout ' + url);
    await sleep(250);
  }
}

function sanitizeDump(dump) {
  const s = JSON.stringify(dump);
  if (/token|authkey|Bearer /i.test(s) && /"[A-Za-z0-9_-]{20,}"/.test(s)) {
    throw new Error('dump looks like it contains a secret — abort write');
  }
  return dump;
}

const main = async () => {
  mkdirSync(OUT, { recursive: true });
  mkdirSync(CHROME_DIR, { recursive: true });
  const pairing = loadPairing(); // ⛔ not printed

  const cdpPort = CDP > 0 ? CDP : await pickPort(9411, 9460);
  const chrome = spawn(CHROME, [
    `--remote-debugging-port=${cdpPort}`, `--user-data-dir=${CHROME_DIR}`,
    '--no-first-run', '--no-default-browser-check', '--disable-sync', '--disable-extensions',
    '--headless=new', `--window-size=${W},${H}`, 'about:blank',
  ], { stdio: 'ignore' });

  const rows = [];
  try {
    await waitOk(`http://127.0.0.1:${cdpPort}/json/version`, 20000);
    const t = await (await fetch(`http://127.0.0.1:${cdpPort}/json/new?${ORIGIN}/`, { method: 'PUT' })).json();
    const tab = new Tab(t.webSocketDebuggerUrl);
    await tab.open();
    await tab.send('Runtime.enable');
    await tab.send('Page.enable');
    await tab.send('Emulation.setDeviceMetricsOverride', {
      width: W, height: H, deviceScaleFactor: 1, mobile: false,
    });
    await sleep(400);

    const devicesJson = JSON.stringify([{ id: pairing.id, name: pairing.name, url: pairing.url, token: pairing.token }]);
    await tab.evaluate(`(() => { localStorage.setItem(${JSON.stringify(DEVICES_KEY)}, ${JSON.stringify(devicesJson)}); location.reload(); return 'paired'; })()`);
    await sleep(800);
    await tab.evaluate(`(() => { window.__amSubscribeAtHost = true; return true; })()`);

    let n = 0;
    for (let i = 0; i < 100; i++) {
      n = await tab.evaluate(`document.querySelectorAll('.agents-row').length`);
      if (n > 0) break;
      await sleep(300);
    }
    if (!n) throw new Error('no .agents-row（配对或 listing 失败）');

    const agents = await tab.evaluate(`([...document.querySelectorAll('.agents-row')].map((el,i)=>({
      i,
      title: (el.querySelector('.agents-row-title')?.textContent||'').trim(),
      ref: el.getAttribute('data-ref') || '',
      hostCols: el.getAttribute('data-host-cols') || '',
      hostRows: el.getAttribute('data-host-rows') || '',
      fav: el.getAttribute('data-fav') === '1',
    })))`);

    for (const a of agents) {
      if (a.fav) {
        rows.push({
          i: a.i, title: a.title, skipped: 'fav',
          png: '', json: '', geom_same: null,
        });
        process.stderr.write(`[${a.i + 1}/${agents.length}] SKIP fav ${a.title}\n`);
        continue;
      }
      const { socket, pane } = parseRef(a.ref);
      const before = await tmuxGeom(socket, pane);
      await tab.evaluate(`(() => { window.__amDiag && window.__amDiag.reset && window.__amDiag.reset(); window.__amSubscribeAtHost = true; return true; })()`);
      await tab.evaluate(`(()=>{const el=document.querySelectorAll('.agents-row')[${a.i}]; if(!el) return 'miss'; el.scrollIntoView({block:'center'}); el.click(); return 'ok';})()`);
      await sleep(2200);
      const after = await tmuxGeom(socket, pane);
      const shot = await tab.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
      const dump = sanitizeDump(await tab.evaluate(`(() => {
        if (!window.__amDiag || !window.__amDiag.dump) return { missing: true, events: [], settle: {} };
        return window.__amDiag.dump();
      })()`));
      const safe = String(a.i).padStart(2, '0') + '__' + (a.title || 'untitled').replace(/[^\w一-龥.-]+/g, '_').slice(0, 60);
      const png = safe + '.png';
      const json = safe + '.json';
      writeFileSync(join(OUT, png), Buffer.from(shot.data, 'base64'));
      writeFileSync(join(OUT, json), JSON.stringify(dump));
      const geomOk = before.ok && after.ok && before.geom === after.geom;
      rows.push({
        i: a.i,
        title: a.title,
        socket: socket.split('/').pop() || socket,
        pane,
        listing: (a.hostCols && a.hostRows) ? `${a.hostCols}x${a.hostRows}` : '',
        geom_before: before.geom || before.err,
        geom_after: after.geom || after.err,
        geom_same: geomOk,
        png,
        json,
        dump_events: dump.missing ? 0 : (dump.length || (dump.events || []).length),
      });
      process.stderr.write(`[${a.i + 1}/${agents.length}] ${png} geom ${before.geom}->${after.geom} same=${geomOk}\n`);
    }

    writeFileSync(join(OUT, 'run.json'), JSON.stringify({ w: W, h: H, n: rows.length, rows }, null, 2));
    process.stderr.write(`OK ${rows.length} pairs -> ${OUT}\n`);
  } finally {
    try { chrome.kill('SIGTERM'); } catch { /* */ }
  }
};

main().catch((e) => { process.stderr.write('FAIL ' + e.message + '\n'); process.exit(1); });
