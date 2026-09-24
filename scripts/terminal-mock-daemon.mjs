#!/usr/bin/env node
/*
 * Isolated Terminal Benchmark Mock Daemon
 *
 * Dedicated zero-credential mock daemon for GPU energy & renderer ablation profiling.
 * Serves 4 predefined mock sessions over an isolated loopback WebSocket port (default: 9919).
 * Emits a realistic initial terminal snapshot and a bounded 3-line output burst,
 * then completely halts output timers to settle into a strictly quiescent, static state.
 *
 * Usage:
 *   node scripts/terminal-mock-daemon.mjs [--port 9919] [--burst 3]
 */

import { WebSocketServer } from 'ws';
import { createServer } from 'node:http';

export const DEFAULT_MOCK_PORT = 9919;
export const MOCK_DEVICE_ID = 'mock-daemon-9919';

export const MOCK_SESSIONS = Object.freeze([
  {
    ref: '/mock-daemon/pane-1\x1f%1',
    name: 'agent-1',
    cwd: '/mock/workspace',
    title: 'Benchmark Pane 1',
    rows: 40,
    cols: 100,
    provider: 'codex',
  },
  {
    ref: '/mock-daemon/pane-2\x1f%2',
    name: 'agent-2',
    cwd: '/mock/workspace',
    title: 'Benchmark Pane 2',
    rows: 40,
    cols: 100,
    provider: 'claude_code',
  },
  {
    ref: '/mock-daemon/pane-3\x1f%3',
    name: 'agent-3',
    cwd: '/mock/workspace',
    title: 'Benchmark Pane 3',
    rows: 40,
    cols: 100,
    provider: 'cursor',
  },
  {
    ref: '/mock-daemon/pane-4\x1f%4',
    name: 'agent-4',
    cwd: '/mock/workspace',
    title: 'Benchmark Pane 4',
    rows: 40,
    cols: 100,
    provider: 'pi',
  },
]);

export const MOCK_WORKSPACES = Object.freeze([
  {
    cwd: '/mock/workspace',
    session_count: 4,
    sessions: MOCK_SESSIONS.map((s) => ({
      ref: s.ref,
      name: s.name,
      cwd: s.cwd,
      title: '',
      rows: s.rows,
      cols: s.cols,
    })),
  },
]);

export const MOCK_LEVEL2 = Object.freeze({
  '/mock/workspace': MOCK_SESSIONS.map((s) => ({
    ref: s.ref,
    name: s.name,
    cwd: s.cwd,
    title: s.title,
    status: 'idle',
    provider: s.provider,
    rows: s.rows,
    cols: s.cols,
  })),
});

/** Binary protocol encoder (kind: 1=snapshot, 2=delta, 3=scrollback). */
export function encodeBinary(kind, ref, payload, meta) {
  const r = Buffer.from(ref, 'utf8');
  if (r.length === 0 || r.length > 255) throw new Error('bad ref');
  const parts = [Buffer.from([0x52, 0x41, 0x01, kind, r.length]), r];
  if (kind === 3) {
    const m = Buffer.alloc(12);
    m.writeUInt32BE(meta.reqId, 0);
    m.writeInt32BE(meta.fromLine, 4);
    m.writeUInt32BE(meta.lineCount, 8);
    parts.push(m);
  }
  parts.push(Buffer.from(payload));
  return Buffer.concat(parts);
}

/** Construct rich, realistic terminal snapshot with ANSI styling. */
export function buildSnapshotBuffer(ref, rows = 24, cols = 80) {
  const sess = MOCK_SESSIONS.find((s) => s.ref === ref) || { name: 'agent', provider: 'terminal' };
  const lines = [
    '\x1b[2J\x1b[H', // clear screen + home
    `\x1b[1;34m=== Corral Terminal Benchmark Session: ${sess.name} ===\x1b[0m\r\n`,
    `\x1b[32m●\x1b[0m \x1b[1mStatus:\x1b[0m Connected (isolated mock daemon; zero-credential loopback)\r\n`,
    `\x1b[90m----------------------------------------------------------------------\x1b[0m\r\n`,
    `\x1b[33m$\x1b[0m uname -smr\r\n`,
    `Darwin 24.3.0 arm64 (Apple Silicon AGX Performance Mode)\r\n`,
    `\x1b[33m$\x1b[0m git status --short\r\n`,
    `\x1b[32mM\x1b[0m src/term/TerminalView.js\r\n`,
    `\x1b[32mM\x1b[0m src/term/webglRenderer.js\r\n`,
    `\x1b[33m$\x1b[0m \x1b[1;32mbenchmark@corral\x1b[0m:\x1b[1;34m~/workspace\x1b[0m$ `,
  ];
  return Buffer.from(lines.join(''), 'utf8');
}

export function buildDeltaBuffer(text) {
  return Buffer.from(`${text}\r\n`, 'utf8');
}

class MockConnection {
  constructor(ws, hub) {
    this.ws = ws;
    this.hub = hub;
    this.authed = true; // Loopback mock daemon accepts all connections automatically
    this.seq = 0;
    this.subs = new Map(); // ref -> { rows, cols, burstTimer }
    ws.on('message', (data, isBinary) => {
      if (!isBinary) this.handleText(String(data));
    });
    ws.on('close', () => this.dispose());
  }

  send(type, payload) {
    if (this.ws.readyState === 1) {
      this.ws.send(JSON.stringify({ v: 1, type, payload }));
    }
  }

  sendBinary(buf) {
    if (this.ws.readyState === 1) {
      this.ws.send(buf);
    }
  }

  handleText(raw) {
    let frame;
    try { frame = JSON.parse(raw); } catch { return; }
    if (!frame || frame.v !== 1) return;

    const { type, payload = {} } = frame;
    this.hub.logEvent('frame_in', { type, payload });

    switch (type) {
      case 'auth': {
        // Always acknowledge auth successfully
        this.send('auth_ack', { ok: true });
        break;
      }
      case 'list': {
        this.send('listing', {
          req_id: payload.req_id,
          seq: ++this.seq,
          workspaces: MOCK_WORKSPACES,
        });
        break;
      }
      case 'level2_subscribe': {
        const cwd = payload.workspace || '/mock/workspace';
        this.send('level2_frame', {
          workspace: cwd,
          seq: ++this.seq,
          sessions: MOCK_LEVEL2[cwd] || MOCK_LEVEL2['/mock/workspace'],
        });
        break;
      }
      case 'subscribe': {
        const { ref, rows = 40, cols = 100 } = payload;
        this.startSubscription(ref, rows, cols);
        break;
      }
      case 'unsubscribe': {
        this.stopSubscription(payload.ref);
        break;
      }
      case 'resize': {
        const sub = this.subs.get(payload.ref);
        if (sub) {
          sub.rows = payload.rows;
          sub.cols = payload.cols;
          this.sendBinary(encodeBinary(1, payload.ref, buildSnapshotBuffer(payload.ref, payload.rows, payload.cols)));
          this.hub.noteSnapshot(payload.ref, { rows: payload.rows, cols: payload.cols, reason: 'resize' });
        }
        break;
      }
      case 'input': {
        this.send('input_ack', { req_id: payload.req_id, ok: true });
        break;
      }
      default:
        break;
    }
  }

  startSubscription(ref, rows, cols) {
    this.stopSubscription(ref);

    // 1. 始终正常应答当前几何的快照（遵循标准协议语义，绝不吞帧导致 SameWidthController 挂死在 awaitingSnapshot）
    this.sendBinary(encodeBinary(1, ref, buildSnapshotBuffer(ref, rows, cols)));
    this.hub.noteSnapshot(ref, { rows, cols });

    // 2. 如果该会话已经经历过启动测试脉冲进入静止态（settled），则不再重复产生测试输出内容，保持静止
    if (this.hub.settledSessions.has(ref)) {
      this.hub.logEvent('post_settle_subscribe_quiet_snapshot_replied', { ref, rows, cols });
      this.subs.set(ref, { rows, cols, burstTimer: null });
      return;
    }

    // 3. 初次订阅时：发送有限有界（如 3 行）启动输出，随后彻底停止定时器并标记该会话已静止（settled）
    const burstTotal = this.hub.burstLines;
    let burstIndex = 0;

    const burstTimer = setInterval(() => {
      burstIndex += 1;
      if (burstIndex === 1) {
        this.sendBinary(encodeBinary(2, ref, buildDeltaBuffer('\x1b[36m[fixture]\x1b[0m initializing benchmark target...')));
      } else if (burstIndex === 2) {
        this.sendBinary(encodeBinary(2, ref, buildDeltaBuffer('\x1b[32m[fixture]\x1b[0m terminal grid active; rows rendered.')));
      } else {
        this.sendBinary(encodeBinary(2, ref, buildDeltaBuffer('\x1b[33m[fixture]\x1b[0m output halted; stationary quiet state established.')));
        this.sendBinary(encodeBinary(2, ref, Buffer.from('\x1b[1;32mbenchmark@corral\x1b[0m:\x1b[1;34m~/workspace\x1b[0m$ ', 'utf8')));

        // STOP ALL TIMERS! Enforce strictly static, quiescent state
        clearInterval(burstTimer);
        this.subs.set(ref, { rows, cols, burstTimer: null });
        this.hub.noteSettled(ref);
      }
    }, this.hub.burstIntervalMs);

    burstTimer.unref?.();
    this.subs.set(ref, { rows, cols, burstTimer });
  }

  stopSubscription(ref) {
    const sub = this.subs.get(ref);
    if (!sub) return;
    if (sub.burstTimer) clearInterval(sub.burstTimer);
    this.subs.delete(ref);
  }

  dispose() {
    for (const ref of [...this.subs.keys()]) {
      this.stopSubscription(ref);
    }
    this.hub.conns.delete(this);
  }
}

/**
 * Start the standalone isolated mock daemon.
 */
export function startTerminalMockDaemon(opts = {}) {
  const port = Number(opts.port || process.env.PORT || DEFAULT_MOCK_PORT);
  const host = opts.host || '127.0.0.1';
  const burstLines = opts.burstLines !== undefined ? Number(opts.burstLines) : 3;
  const burstIntervalMs = Number(opts.burstIntervalMs || 60);

  const hub = {
    port,
    host,
    burstLines,
    burstIntervalMs,
    conns: new Set(),
    events: [],
    snapshotsDelivered: new Map(), // ref -> timestamp (latest)
    totalSnapshotsDelivered: 0,   // total snapshot binary frames sent
    settledSessions: new Map(),   // ref -> timestamp
    logEvent(name, data = {}) {
      hub.events.push({ time: new Date().toISOString(), name, ...data });
    },
    noteSnapshot(ref, meta) {
      hub.totalSnapshotsDelivered += 1;
      hub.snapshotsDelivered.set(ref, Date.now());
      hub.logEvent('snapshot_delivered', { ref, ...meta });
    },
    noteSettled(ref) {
      hub.settledSessions.set(ref, Date.now());
      hub.logEvent('session_settled', { ref });
    },
  };

  const httpServer = createServer((req, res) => {
    const url = new URL(req.url, `http://${host}:${port}`);
    if (url.pathname === '/health' || url.pathname === '/status') {
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({
        ok: true,
        port,
        connections: hub.conns.size,
        snapshotsCount: hub.totalSnapshotsDelivered,
        uniqueSessionsWithSnapshot: hub.snapshotsDelivered.size,
        uniqueRefsWithSnapshot: Array.from(hub.snapshotsDelivered.keys()),
        settledCount: hub.settledSessions.size,
        allSettled: hub.snapshotsDelivered.size > 0 && hub.snapshotsDelivered.size === hub.settledSessions.size,
        events: hub.events,
      }, null, 2));
      return;
    }
    if (url.pathname === '/pair/whoami') {
      res.setHeader('content-type', 'application/json');
      res.end(JSON.stringify({
        host_id: MOCK_DEVICE_ID,
        name: 'Mock Host 9919',
        port,
      }));
      return;
    }
    res.statusCode = 404;
    res.end('Not Found');
  });

  const wss = new WebSocketServer({ server: httpServer });
  wss.on('connection', (ws) => {
    const conn = new MockConnection(ws, hub);
    hub.conns.add(conn);
    hub.logEvent('client_connected');
  });

  httpServer.listen(port, host);

  return {
    port,
    host,
    url: `ws://${host}:${port}/ws`,
    httpServer,
    wss,
    hub,
    ready: new Promise((resolve, reject) => {
      httpServer.on('listening', resolve);
      httpServer.on('error', reject);
    }),
    async close() {
      for (const c of [...hub.conns]) c.dispose();
      await new Promise((resolve) => wss.close(resolve));
      await new Promise((resolve) => httpServer.close(resolve));
    },
  };
}

import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

// Direct CLI invocation
if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  const portArgIdx = process.argv.indexOf('--port');
  const port = portArgIdx !== -1 ? Number(process.argv[portArgIdx + 1]) : DEFAULT_MOCK_PORT;
  const daemon = startTerminalMockDaemon({ port });
  await daemon.ready;
  console.log(`[mock-daemon] Isolated terminal mock daemon listening on ws://127.0.0.1:${port}/ws`);
  console.log(`[mock-daemon] Health endpoint: http://127.0.0.1:${port}/health`);
}
