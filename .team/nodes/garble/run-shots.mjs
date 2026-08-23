#!/usr/bin/env node
/**
 * Route B: read-only tmux capture-pane -e, render in headless Chrome + xterm.
 * Never subscribe, never send-keys, never resize-window, never touch :9900.
 * Does not write pane text to artifacts (PNG only). Token never printed.
 */
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { readdirSync, readFileSync, mkdirSync, writeFileSync, existsSync } from 'node:fs';
import net from 'node:net';
import { dirname, join, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import WebSocket from '/Volumes/nvme/Projects/tmux桌面端/node_modules/ws/index.js';

const here = dirname(fileURLToPath(import.meta.url));
const SHOTS = join(here, 'shots');
const SOCKDIR = '/tmp/tmux-501';
const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const XTERM_ROOT = '/Volumes/nvme/Projects/tmux桌面端/node_modules/@xterm/xterm';
const CELL_W = 8;
const CELL_H = 17;

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
    child.on('exit', (code) => resolve({ code, out: Buffer.concat(chunks), err }));
  });
}

async function tmux(sock, args) {
  return sh('tmux', ['-S', sock, ...args]);
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

function startStaticServer(port) {
  const files = {
    '/render.html': { path: join(SHOTS, 'render.html'), type: 'text/html; charset=utf-8' },
    '/xterm.css': { path: join(XTERM_ROOT, 'css/xterm.css'), type: 'text/css' },
    '/xterm.mjs': { path: join(XTERM_ROOT, 'lib/xterm.mjs'), type: 'text/javascript' },
  };
  const server = createServer((req, res) => {
    const f = files[req.url.split('?')[0]];
    if (!f || !existsSync(f.path)) {
      res.writeHead(404); res.end(); return;
    }
    res.writeHead(200, { 'content-type': f.type, 'cache-control': 'no-store' });
    res.end(readFileSync(f.path));
  });
  return new Promise((resolve) => {
    server.listen(port, '127.0.0.1', () => resolve(server));
  });
}

async function cdpConnect(cdpPort) {
  const t0 = Date.now();
  let version;
  while (Date.now() - t0 < 15000) {
    try {
      const r = await fetch(`http://127.0.0.1:${cdpPort}/json/version`);
      if (r.ok) { version = await r.json(); break; }
    } catch { /* chrome starting */ }
    await sleep(150);
  }
  if (!version?.webSocketDebuggerUrl) throw new Error('chrome cdp not up');
  const ws = new WebSocket(version.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    ws.once('open', resolve);
    ws.once('error', reject);
  });
  let nextId = 1;
  const pending = new Map();
  ws.on('message', (raw) => {
    const msg = JSON.parse(String(raw));
    if (msg.id && pending.has(msg.id)) {
      const { resolve, reject } = pending.get(msg.id);
      pending.delete(msg.id);
      if (msg.error) reject(new Error(JSON.stringify(msg.error)));
      else resolve(msg.result);
    }
  });
  const send = (method, params = {}, sessionId) => {
    const id = nextId++;
    const body = { id, method, params };
    if (sessionId) body.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      ws.send(JSON.stringify(body));
    });
  };
  return { ws, send };
}

async function attachPage(cdp, url) {
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
  const s = (method, params) => cdp.send(method, params, sessionId);
  await s('Page.enable');
  await s('Runtime.enable');
  await s('Page.navigate', { url });
  const t0 = Date.now();
  while (Date.now() - t0 < 10000) {
    const ev = await s('Runtime.evaluate', { expression: 'window.ready === true', returnByValue: true });
    if (ev?.result?.value === true) break;
    await sleep(50);
  }
  return { s, targetId };
}

function encodeB64(buf) {
  return Buffer.from(buf).toString('base64');
}

function safeName(socketShort, paneId) {
  const p = String(paneId).replace(/%/g, 'p').replace(/[^A-Za-z0-9._-]/g, '_');
  return `${socketShort}__${p}.png`;
}

async function listPanes(sockPath) {
  const r = await tmux(sockPath, [
    'list-panes', '-a', '-F',
    '#{session_name}\t#{pane_id}\t#{pane_width}x#{pane_height}\t#{pane_current_path}',
  ]);
  if (r.code !== 0) return { ok: false, err: r.err.trim() || `tmux exit ${r.code}` };
  const panes = [];
  for (const line of r.out.toString('utf8').split('\n')) {
    if (!line.trim()) continue;
    const [session, pane, geom, ...rest] = line.split('\t');
    panes.push({ session, pane, geom, cwd: rest.join('\t') });
  }
  return { ok: true, panes };
}

async function readGeom(sockPath, pane) {
  const r = await tmux(sockPath, ['display-message', '-p', '-t', pane, '#{pane_width}x#{pane_height}']);
  if (r.code !== 0) return { ok: false, err: r.err.trim() };
  return { ok: true, geom: r.out.toString('utf8').trim() };
}

async function capture(sockPath, pane) {
  const r = await tmux(sockPath, ['capture-pane', '-e', '-p', '-t', pane]);
  if (r.code !== 0) return { ok: false, err: r.err.trim() };
  return { ok: true, bytes: r.out };
}

async function main() {
  mkdirSync(SHOTS, { recursive: true });
  mkdirSync(join(SHOTS, '.chrome-user'), { recursive: true });

  const socks = readdirSync(SOCKDIR)
    .map((n) => ({ short: n, path: join(SOCKDIR, n) }))
    .filter((s) => {
      try {
        return existsSync(s.path);
      } catch { return false; }
    });

  const inventory = [];
  for (const s of socks) {
    const listed = await listPanes(s.path);
    if (!listed.ok) {
      inventory.push({ socket: s.short, path: s.path, listError: listed.err, panes: [] });
      continue;
    }
    inventory.push({ socket: s.short, path: s.path, panes: listed.panes });
  }

  const httpPort = await pickPort(18771, 18820);
  const cdpPort = await pickPort(18821, 18870);
  const http = await startStaticServer(httpPort);

  const chrome = spawn(CHROME, [
    '--headless=new',
    '--disable-gpu',
    '--hide-scrollbars',
    `--remote-debugging-port=${cdpPort}`,
    `--user-data-dir=${join(SHOTS, '.chrome-user')}`,
    '--no-first-run',
    '--disable-extensions',
    'about:blank',
  ], { stdio: ['ignore', 'pipe', 'pipe'] });

  let chromeErr = '';
  chrome.stderr.on('data', (d) => { chromeErr += d; if (chromeErr.length > 2000) chromeErr = chromeErr.slice(-2000); });

  const rows = [];
  let nPng = 0;
  let nMiss = 0;
  let geomChanged = false;

  try {
    const cdp = await cdpConnect(cdpPort);
    const page = await attachPage(cdp, `http://127.0.0.1:${httpPort}/render.html`);

    for (const sock of inventory) {
      if (sock.listError) {
        rows.push({
          file: '',
          socket: sock.socket,
          pane: '',
          cwd: '',
          geom: '',
          geom_before: '',
          geom_after: '',
          note: `未取到：list-panes 失败（${sock.listError.replace(/\s+/g, ' ').slice(0, 120)}）`,
        });
        nMiss += 1;
        continue;
      }
      for (const p of sock.panes) {
        const file = safeName(sock.socket, p.pane);
        const dest = join(SHOTS, file);
        const before = await readGeom(sock.path, p.pane);
        const cap = await capture(sock.path, p.pane);
        const after = await readGeom(sock.path, p.pane);
        const gb = before.ok ? before.geom : `err:${before.err}`;
        const ga = after.ok ? after.geom : `err:${after.err}`;
        if (before.ok && after.ok && gb !== ga) geomChanged = true;
        if (!cap.ok) {
          rows.push({
            file: '', socket: sock.socket, pane: p.pane, cwd: p.cwd,
            geom: p.geom, geom_before: gb, geom_after: ga,
            note: `未取到：capture-pane 失败`,
          });
          nMiss += 1;
          continue;
        }
        const [cw, rh] = (before.ok ? gb : p.geom).split('x').map((x) => Number(x));
        const cols = Math.max(2, cw || 80);
        const rws = Math.max(2, rh || 24);
        try {
          await page.s('Emulation.setDeviceMetricsOverride', {
            width: Math.min(4000, Math.max(320, cols * CELL_W + 16)),
            height: Math.min(3000, Math.max(240, rws * CELL_H + 16)),
            deviceScaleFactor: 1,
            mobile: false,
          });
          await page.s('Runtime.evaluate', {
            expression: `window.boot(${cols}, ${rws})`,
            returnByValue: true,
          });
          await page.s('Runtime.evaluate', {
            expression: `window.paint(${JSON.stringify(encodeB64(cap.bytes))})`,
            awaitPromise: true,
            returnByValue: true,
          });
          await sleep(40);
          const shot = await page.s('Page.captureScreenshot', { format: 'png', fromSurface: true });
          writeFileSync(dest, Buffer.from(shot.data, 'base64'));
          nPng += 1;
          rows.push({
            file, socket: sock.socket, pane: p.pane, cwd: p.cwd,
            geom: p.geom, geom_before: gb, geom_after: ga, note: '',
          });
        } catch (e) {
          rows.push({
            file: '', socket: sock.socket, pane: p.pane, cwd: p.cwd,
            geom: p.geom, geom_before: gb, geom_after: ga,
            note: `未取到：渲染失败（${String(e.message || e).slice(0, 120)}）`,
          });
          nMiss += 1;
        }
        if (geomChanged) break;
      }
      if (geomChanged) break;
    }

    cdp.ws.close();
  } finally {
    try { process.kill(chrome.pid, 'SIGTERM'); } catch { /* */ }
    await new Promise((r) => http.close(r));
  }

  const nListed = inventory.reduce((a, s) => a + (s.panes ? s.panes.length : 0), 0);
  const nSocks = inventory.length;
  const nSockFail = inventory.filter((s) => s.listError).length;

  const md = [];
  md.push('# 逐会话截图（t.shots）');
  md.push('');
  md.push('路线 **B**（`tmux capture-pane -e -p` 只读，喂进本地 xterm.js，无头 Chrome 截 PNG）。');
  md.push('');
  md.push('选择理由：席位纪律 §1.6 禁止对真实会话 subscribe（退订也会 reshape）。B 全程不连 `:9900`、不发 subscribe/resize/send-keys。capture-pane 只读。xterm `convertEol: true` 只为把 capture 的裸 LF 画成与 tmux 行盒一致的画面，方便看框线/中英文对齐；这不是产品改动，也不是错乱判定。');
  md.push('');
  md.push(`- 扫描 socket 目录 \`${SOCKDIR}\`：${nSocks} 个（list-panes 失败 ${nSockFail}）`);
  md.push(`- 列出的 pane 数 **${nListed}**`);
  md.push(`- 写成 PNG **${nPng}**`);
  md.push(`- 未取到 **${nMiss}**`);
  md.push(`- 截图前后几何是否全部相同：${geomChanged ? '否（已停止后续截取）' : '是'}`);
  md.push('');
  md.push('| 文件名 | socket | pane | 工程目录 | 几何 | 截图前 | 截图后 | 备注 |');
  md.push('|---|---|---|---|---|---|---|---|');
  for (const r of rows) {
    const note = (r.note || '').replace(/\|/g, '/');
    md.push(`| ${r.file || '—'} | ${r.socket} | ${r.pane || '—'} | ${r.cwd || '—'} | ${r.geom || '—'} | ${r.geom_before || '—'} | ${r.geom_after || '—'} | ${note} |`);
  }
  md.push('');
  md.push(nPng === nListed && nMiss === nSockFail && !geomChanged ? 'verdict: pass' : (geomChanged ? 'verdict: unjudgeable' : (nPng > 0 ? 'verdict: fail' : 'verdict: unjudgeable')));
  writeFileSync(join(SHOTS, 'index.md'), md.join('\n'));
  writeFileSync(join(SHOTS, 'meta.json'), JSON.stringify({
    route: 'B', nSocks, nListed, nPng, nMiss, nSockFail, geomChanged, httpPort, cdpPort,
  }, null, 2));
  process.stderr.write(JSON.stringify({ nSocks, nListed, nPng, nMiss, geomChanged }, null, 2) + '\n');
  process.exit(geomChanged ? 2 : 0);
}

main().catch((e) => {
  writeFileSync(join(SHOTS, 'index.md'), [
    '# 逐会话截图（t.shots）',
    '',
    `跑崩：${String(e && e.message)}`,
    '',
    'verdict: unjudgeable',
  ].join('\n'));
  process.exit(4);
});
