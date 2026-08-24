#!/usr/bin/env node
/*
 * Mock agentmirrord (CLIENT-CONTRACT §5) — no tmux, no Go binary.
 *
 * Used by `node --test test/core-devices.test.js` and for local smoke runs:
 *   node scripts/mock-daemon.mjs           # PORT=9911 TOKEN=mock-token DELTA_MS=800
 *
 * It deliberately reproduces the live daemon's quirks the client must survive:
 * listing sessions carry NO status/provider (§0.1), scrollback replies are
 * clamped to a range different from the request, and a resize that does not
 * change the geometry answers with nothing at all.
 */
import { WebSocketServer } from 'ws';
import { createServer } from 'node:http';
import { mkdir, writeFile } from 'node:fs/promises';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

/** Real-shaped refs (tmux socket + \x1f + pane id) so uid splitting is exercised. */
export const REFS = Object.freeze({
  a1: '/tmp/tmux-501/default\x1f%1',
  a2: '/tmp/tmux-501/default\x1f%2',
  b1: '/tmp/tmux-501/work\x1f%7',
  b2: '/tmp/tmux-501/work\x1f%8',
});

/** listing fixture: ⛔ no status, no provider, title always "" — matches §0.1. */
export const WORKSPACES = Object.freeze([
  { cwd: '/proj/a', session_count: 2, sessions: [
    { ref: REFS.a1, name: 'claude', cwd: '/proj/a', title: '', rows: 40, cols: 100 },
    { ref: REFS.a2, name: 'codex', cwd: '/proj/a', title: '', rows: 24, cols: 80 },
  ] },
  { cwd: '/proj/b', session_count: 1, sessions: [
    { ref: REFS.b1, name: 'claude', cwd: '/proj/b', title: '', rows: 30, cols: 90 },
  ] },
]);

/** level2 fixture: the same sessions plus the three live fields. */
export const LEVEL2 = Object.freeze({
  '/proj/a': [
    { ref: REFS.a1, name: 'claude', cwd: '/proj/a', title: '✳ Thinking…', status: 'working', provider: 'claude_code', rows: 40, cols: 100 },
    { ref: REFS.a2, name: 'codex', cwd: '/proj/a', title: 'npm test', status: 'idle', provider: 'codex', rows: 24, cols: 80 },
  ],
  '/proj/b': [
    { ref: REFS.b1, name: 'claude', cwd: '/proj/b', title: '', status: 'idle', provider: 'claude_code', rows: 30, cols: 90 },
  ],
});

export const ADDED_SESSION = Object.freeze(
  { ref: REFS.b2, name: 'cursor', cwd: '/proj/b', title: '', rows: 24, cols: 80 },
);

const KNOWN_TYPES = new Set([
  'auth', 'list', 'subscribe', 'unsubscribe', 'input', 'scrollback', 'resize',
  'level2_subscribe', 'level2_unsubscribe', 'overlay_subscribe', 'overlay_unsubscribe',
  'pane_mode_changed', 'scroll_wheel', 'attach_preview',
]);

/** kind 1=snapshot 2=delta 3=scrollback; header 'R','A',v1,kind,reflen (§5.3). */
export function encodeBinary(kind, ref, payload, meta) {
  const r = Buffer.from(ref, 'utf8');
  if (r.length === 0 || r.length > 255) throw new Error('bad ref');
  const parts = [Buffer.from([0x52, 0x41, 0x01, kind, r.length]), r];
  if (kind === 3) {
    const m = Buffer.alloc(12);
    m.writeUInt32BE(meta.reqId, 0);
    m.writeInt32BE(meta.fromLine, 4);   // signed: negative = above the viewport
    m.writeUInt32BE(meta.lineCount, 8);
    parts.push(m);
  }
  parts.push(Buffer.from(payload));
  return Buffer.concat(parts);
}

function snapshotBytes(ref, rows, cols) {
  const body = `\x1b[2J\x1b[H$ mock ${ref.replace('\x1f', ' ')}\r\n${rows}x${cols} 快照\r\n$ `;
  return Buffer.from(`${body}\x1b[3;3H`, 'utf8'); // trailing CUP anchor, 1-based
}

function deltaBytes(text) {
  return Buffer.from(`\r\x1b[K${text}\r\n`, 'utf8');
}

class Conn {
  constructor(ws, hub) {
    this.ws = ws;
    this.hub = hub;
    this.authed = false;
    this.seq = 0;
    this.subs = new Map();  // ref -> { rows, cols, timer }
    this.level2 = null;     // { cwd, seq, timer, ticks }
    ws.on('message', (data, isBinary) => { if (!isBinary) this.handleText(String(data)); });
    ws.on('close', () => this.dispose());
  }

  send(type, payload) {
    if (this.ws.readyState === 1) this.ws.send(JSON.stringify({ v: 1, type, payload }));
  }

  sendBinary(buf) {
    if (this.ws.readyState === 1) this.ws.send(buf);
  }

  error(code, reason) { this.send('error', { code, reason }); }

  handleText(raw) {
    let frame;
    try { frame = JSON.parse(raw); } catch { return this.error('bad_frame', 'malformed json'); }
    if (frame === null || typeof frame !== 'object') return this.error('bad_frame', 'envelope must be an object');
    if (frame.v !== 1) {
      this.error('unsupported_version', `unsupported protocol version: ${frame.v}`);
      return this.ws.close();
    }
    const type = frame.type;
    const p = frame.payload || {};
    this.hub.received.push({ type, payload: p });
    if (!KNOWN_TYPES.has(type)) return this.error('unsupported_type', `unknown frame type: ${type}`);
    if (type !== 'auth' && !this.authed) return this.error('unauthorized', 'not authenticated');

    switch (type) {
      case 'auth': {
        if (p.token !== this.hub.token) {
          this.send('auth_ack', { ok: false, reason: 'invalid token' });
          return this.ws.close();
        }
        this.authed = true;
        return this.send('auth_ack', { ok: true });
      }
      case 'list':
        return this.send('listing', { req_id: p.req_id, seq: ++this.seq, workspaces: this.hub.workspaces });
      case 'subscribe': {
        if (!this.hub.refs.has(p.ref)) return this.error('session_not_found', `no such session: ${p.ref}`);
        this.startMirror(p.ref, p.rows, p.cols);
        return;
      }
      case 'unsubscribe':
        return this.stopMirror(p.ref);
      case 'input': {
        if (!this.subs.has(p.ref)) return this.send('input_ack', { req_id: p.req_id, ok: false, reason: 'not_subscribed' });
        this.send('input_ack', { req_id: p.req_id, ok: true });
        return this.sendBinary(encodeBinary(2, p.ref, deltaBytes(p.text ? p.text : '⏎')));
      }
      case 'scrollback': {
        // Deliberately clamped: the client must trust the reply's range, not its request.
        const lines = Array.from({ length: 50 }, (_, i) => `history ${i + 1}`).join('\r\n');
        return this.sendBinary(encodeBinary(3, p.ref, Buffer.from(lines, 'utf8'),
          { reqId: p.req_id, fromLine: -100, lineCount: 50 }));
      }
      case 'resize': {
        const sub = this.subs.get(p.ref);
        if (!sub) return;                                        // not subscribed: silent no-op
        if (sub.rows === p.rows && sub.cols === p.cols) return;   // no reflow: nothing comes back
        sub.rows = p.rows; sub.cols = p.cols;
        return this.sendBinary(encodeBinary(1, p.ref, snapshotBytes(p.ref, p.rows, p.cols)));
      }
      case 'level2_subscribe':
        return this.startLevel2(p.workspace);
      case 'level2_unsubscribe':
        return this.stopLevel2();
      case 'attach_preview': {
        if (!this.subs.has(p.ref)) return this.error('session_not_found', 'not subscribed');
        // Preview work is observable through the mirror delta, not input_ack.
        return this.sendBinary(encodeBinary(2, p.ref, deltaBytes('[image preview attached]')));
      }
      default:
        return; // overlay_* / pane_mode_changed / scroll_wheel: accepted, no reply
    }
  }

  startMirror(ref, rows, cols) {
    this.stopMirror(ref);
    this.sendBinary(encodeBinary(1, ref, snapshotBytes(ref, rows, cols)));
    const timer = setInterval(() => {
      this.sendBinary(encodeBinary(2, ref, deltaBytes(`tick ${Date.now()}`)));
    }, this.hub.deltaMs);
    timer.unref?.();
    this.subs.set(ref, { rows, cols, timer });
  }

  stopMirror(ref) {
    const sub = this.subs.get(ref);
    if (!sub) return;
    clearInterval(sub.timer);
    this.subs.delete(ref);
  }

  startLevel2(cwd) {
    this.stopLevel2();
    // The server tracks ONE workspace per connection; a second subscribe replaces it.
    this.level2 = { cwd, seq: 0, ticks: 0, timer: null };
    this.sendLevel2Frame();
    this.level2.timer = setInterval(() => {
      this.level2.ticks++;
      if (this.level2.ticks % 4 === 0) {
        this.send('level2_heartbeat', { workspace: this.level2.cwd, seq: ++this.level2.seq });
      }
    }, this.hub.level2Ms);
    this.level2.timer.unref?.();
  }

  sendLevel2Frame() {
    if (!this.level2) return;
    this.send('level2_frame', {
      workspace: this.level2.cwd,
      seq: ++this.level2.seq,
      sessions: this.hub.level2[this.level2.cwd] || [],
    });
  }

  stopLevel2() {
    if (this.level2?.timer) clearInterval(this.level2.timer);
    this.level2 = null;
  }

  sendDelta({ added = [], removedRefs = [], changedSessions = [], changedWorkspaces = [], gap = false } = {}) {
    if (!this.authed) return;
    const seq = gap ? this.seq + 5 : ++this.seq;  // gap: client must re-list and drop this frame
    this.send('list_delta', {
      seq,
      added_sessions: added,
      removed_refs: removedRefs,
      changed_sessions: changedSessions,
      changed_workspaces: changedWorkspaces,
    });
  }

  dispose() {
    for (const ref of [...this.subs.keys()]) this.stopMirror(ref);
    this.stopLevel2();
    this.hub.conns.delete(this);
  }
}

/**
 * Start a mock daemon.
 * @param {Object} [opts] port(0 = ephemeral) / token / deltaMs / level2Ms / workspaces / level2
 * @returns handle with { port, ready, received, conns, count, dropAll, sendDelta, pushLevel2, close }
 */
export function startMockDaemon(opts = {}) {
  const hub = {
    token: opts.token ?? process.env.TOKEN ?? 'mock-token',
    deltaMs: Number(opts.deltaMs ?? process.env.DELTA_MS ?? 800),
    level2Ms: Number(opts.level2Ms ?? 2000),
    workspaces: opts.workspaces ?? WORKSPACES,
    level2: opts.level2 ?? LEVEL2,
    received: [],
    conns: new Set(),
  };
  hub.refs = new Set(hub.workspaces.flatMap((w) => w.sessions.map((s) => s.ref)));

  const port = opts.port ?? Number(process.env.PORT ?? 9911);
  const host = opts.host ?? '127.0.0.1';
  const uploadDir = process.env.UPLOAD_DIR ? resolve(process.env.UPLOAD_DIR) : null;
  const http = createServer((req, res) => {
    if (!uploadDir || req.method !== 'POST' || req.url !== '/upload') {
      res.statusCode = 404;
      return res.end();
    }
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', async () => {
      const path = join(uploadDir, `upload-${Date.now()}.bin`);
      try {
        await mkdir(uploadDir, { recursive: true });
        await writeFile(path, Buffer.concat(chunks));
        res.setHeader('content-type', 'application/json');
        res.end(JSON.stringify({ path }));
      } catch {
        res.statusCode = 500;
        res.end();
      }
    });
  });
  const wss = new WebSocketServer({ server: http });
  wss.on('connection', (ws) => hub.conns.add(new Conn(ws, hub)));
  http.listen(port, host);

  return {
    hub,
    wss,
    get port() { return http.address()?.port; },
    get url() { return `ws://127.0.0.1:${wss.address()?.port}/ws`; },
    get received() { return hub.received; },
    ready: new Promise((res, rej) => { wss.on('listening', res); wss.on('error', rej); }),
    /** How many frames of one type arrived across all connections. */
    count(type) { return hub.received.filter((f) => f.type === type).length; },
    /** Kill every socket without a close handshake — exercises reconnect + replay. */
    dropAll() { for (const c of [...hub.conns]) c.ws.terminate(); },
    sendDelta(spec) { for (const c of hub.conns) c.sendDelta(spec); },
    /** Force a fresh level2_frame (mock data is static, so nothing pushes on its own). */
    pushLevel2() { for (const c of hub.conns) c.sendLevel2Frame(); },
    close() {
      for (const c of [...hub.conns]) { c.dispose(); c.ws.terminate(); }
      return new Promise((res) => wss.close(() => {
        if (http.listening) http.close(res);
        else res();
      }));
    },
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const d = startMockDaemon();
  d.ready.then(() => {
    console.log(`mock-daemon listening on ${d.url} (token from $TOKEN, delta ${d.hub.deltaMs}ms)`);
  });
}
