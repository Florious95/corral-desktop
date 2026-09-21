#!/usr/bin/env node
/**
 * Read-only WebView2/CDP receipt for the Windows 5090 cold-start gate.
 *
 * This script never sends DOM/input events and never reads credentials. It
 * observes Network websocket frames and a small set of existing UI selectors.
 * The PowerShell orchestrator owns process/install isolation and passes the
 * expected disposable-fixture row count.
 */
import { writeFileSync } from 'node:fs';
import process from 'node:process';
import WebSocket from 'ws';

function arg(name, fallback = undefined) {
  const i = process.argv.indexOf(name);
  return i >= 0 ? process.argv[i + 1] : fallback;
}

const port = Number(arg('--debug-port', '19250'));
const output = arg('--output');
const expectedRows = Number(arg('--expected-rows', '0'));
const timeoutMs = Number(arg('--timeout-ms', '30000'));
const settleMs = Number(arg('--settle-ms', '500'));
const processStartUtc = arg('--process-start-utc', new Date().toISOString());
if (!output || !Number.isInteger(port) || port < 1 || port > 65535 || expectedRows < 1) {
  console.error('usage: --output <file> --debug-port <port> --expected-rows <n> [--timeout-ms <ms>]');
  process.exit(2);
}

const processStartMs = Date.parse(processStartUtc);
const frames = [];
const events = [];

function safeFrame(direction, payload) {
  if (typeof payload !== 'string') return;
  try {
    const frame = JSON.parse(payload);
    const raw = frame.payload || {};
    const safe = {};
    for (const key of ['req_id', 'request_id', 'run_id', 'ref', 'rows', 'cols', 'seq', 'ok', 'status']) {
      if (Object.hasOwn(raw, key)) safe[key] = raw[key];
    }
    if (frame.type === 'listing') {
      const workspaces = Array.isArray(raw.workspaces) ? raw.workspaces : [];
      safe.workspace_count = workspaces.length;
      safe.session_count = workspaces.reduce((count, workspace) => (
        count + (Array.isArray(workspace.sessions) ? workspace.sessions.length : 0)
      ), 0);
    }
    if (typeof raw.bytes === 'string') safe.bytes = `<${raw.bytes.length} chars>`;
    frames.push({ direction, type: frame.type || null, payload: safe, atMs: Date.now() - processStartMs });
  } catch {
    // The application may send binary or non-JSON terminal data. Do not log it.
  }
}

class Cdp {
  constructor(url) {
    this.ws = new WebSocket(url);
    this.nextId = 0;
    this.pending = new Map();
    this.events = new Map();
    this.open = new Promise((resolve, reject) => {
      this.ws.once('open', resolve);
      this.ws.once('error', reject);
    });
    this.ws.on('message', (raw) => {
      let message;
      try { message = JSON.parse(String(raw)); } catch { return; }
      if (message.id && this.pending.has(message.id)) {
        const pending = this.pending.get(message.id);
        this.pending.delete(message.id);
        if (message.error) pending.reject(new Error(message.error.message || 'CDP error'));
        else pending.resolve(message.result);
        return;
      }
      const listeners = this.events.get(message.method) || [];
      for (const listener of listeners) listener(message.params || {});
    });
  }
  on(method, listener) {
    const list = this.events.get(method) || [];
    list.push(listener);
    this.events.set(method, list);
  }
  async send(method, params = {}) {
    await this.open;
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }
  close() { this.ws.close(); }
}

async function json(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url} returned ${response.status}`);
  return response.json();
}

async function findPage() {
  const targets = await json(`http://127.0.0.1:${port}/json/list`);
  const page = targets.find((target) => target.type === 'page' && target.webSocketDebuggerUrl);
  if (!page) throw new Error('no WebView2 page target');
  return page;
}

async function evaluate(cdp, expression) {
  const result = await cdp.send('Runtime.evaluate', {
    expression,
    returnByValue: true,
    awaitPromise: true,
  });
  if (result.exceptionDetails) throw new Error('page evaluation failed');
  return result.result?.value;
}

function measureUi(value) {
  return {
    atMs: Date.now() - processStartMs,
    ...value,
  };
}

async function main() {
  let page;
  const debugDeadline = Date.now() + timeoutMs;
  while (!page && Date.now() < debugDeadline) {
    try { page = await findPage(); } catch { await new Promise((resolve) => setTimeout(resolve, 100)); }
  }
  if (!page) throw new Error('WebView2 CDP page did not become available');
  const cdp = new Cdp(page.webSocketDebuggerUrl);
  cdp.on('Network.webSocketFrameReceived', ({ response }) => safeFrame('in', response?.payloadData));
  cdp.on('Network.webSocketFrameSent', ({ response }) => safeFrame('out', response?.payloadData));
  await cdp.send('Network.enable');
  await cdp.send('Runtime.enable');
  await cdp.send('Page.enable');
  events.push({ name: 'cdp-ready', atMs: Date.now() - processStartMs });

  const expression = `(() => {
    const visible = (node) => {
      if (!node) return false;
      const rect = node.getBoundingClientRect();
      const style = getComputedStyle(node);
      return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
    };
    const rows = [...document.querySelectorAll('.agents-row')].filter(visible);
    const spaces = [...document.querySelectorAll('.spaces-row')].filter(visible);
    const blankTabs = [...document.querySelectorAll('.tb-tab[data-blank="true"]')].filter(visible);
    const dot = document.querySelector('.sidebar-devices-dot.is-online');
    return {
      readyState: document.readyState,
      title: document.title,
      rows: rows.length,
      totalRows: Math.max(rows.length, Math.round((document.querySelector('.agents-track')?.scrollHeight || 0) / 54)),
      rowKeys: rows.map((node) => node.getAttribute('data-agent-key')).filter(Boolean),
      spaces: spaces.length,
      sidebarVisible: visible(document.querySelector('.sidebar')),
      deviceOnline: visible(dot),
      blankTabs: blankTabs.length,
      tabCount: document.querySelectorAll('.tb-tab').length,
      bootstrapCards: document.querySelectorAll('.wsl-bootstrap-card').length,
    };
  })()`;

  let firstRows;
  let listingFrame;
  let settled;
  let last;
  let stableSince = 0;
  const uiDeadline = Date.now() + timeoutMs;
  while (Date.now() < uiDeadline) {
    last = await evaluate(cdp, expression);
    const now = Date.now();
    if (!firstRows && last.rows > 0) firstRows = measureUi(last);
    if (!listingFrame && frames.some((frame) => frame.direction === 'in' && frame.type === 'listing')) {
      listingFrame = frames.find((frame) => frame.direction === 'in' && frame.type === 'listing');
    }
    const ready = listingFrame
      && last.sidebarVisible
      && last.deviceOnline
      && last.totalRows >= expectedRows
      && last.blankTabs === 0;
    if (ready) {
      if (!stableSince) stableSince = now;
      if (now - stableSince >= settleMs) {
        settled = measureUi(last);
        break;
      }
    } else {
      stableSince = 0;
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  if (!listingFrame) {
    listingFrame = frames.find((frame) => frame.direction === 'in' && frame.type === 'listing') || null;
  }
  const receipt = {
    schema: 'agentmirror.windows-5090.startup.v1',
    processStartUtc,
    debugPort: port,
    expectedRows,
    timeoutMs,
    settleMs,
    page: { url: page.url || null, title: page.title || null },
    events,
    timings: {
      cdpReadyMs: events.find((event) => event.name === 'cdp-ready')?.atMs ?? null,
      listingFrameMs: listingFrame?.atMs ?? null,
      firstVisibleRowMs: firstRows?.atMs ?? null,
      listingSettledMs: settled?.atMs ?? null,
    },
    ui: { firstRows, settled, last },
    protocol: {
      listingFrames: frames.filter((frame) => frame.direction === 'in' && frame.type === 'listing').length,
      authFrames: frames.filter((frame) => frame.type === 'auth' || frame.type === 'auth_ack').length,
      allFrames: frames,
    },
    verdict: settled ? 'PASS' : 'FAIL',
    reason: settled ? null : 'listing did not settle with an online device, expected rows, and zero blank tabs',
    capturedAtUtc: new Date().toISOString(),
  };
  writeFileSync(output, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 });
  cdp.close();
  if (!settled) process.exitCode = 1;
}

main().catch((error) => {
  const receipt = {
    schema: 'agentmirror.windows-5090.startup.v1',
    verdict: 'NOT-RUN',
    reason: error.message,
    capturedAtUtc: new Date().toISOString(),
  };
  if (output) writeFileSync(output, `${JSON.stringify(receipt, null, 2)}\n`, { mode: 0o600 });
  console.error(error.message);
  process.exitCode = 1;
});
