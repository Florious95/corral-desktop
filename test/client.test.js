/*
 * Connection-manager tests against a controllable fake WebSocket.
 *
 * The Client takes an injectable wsFactory (the same seam as Kotlin's
 * transportFactory), so these tests drive the full lifecycle: auth → auth_ack
 * → list → listing → subscribe → snapshot/delta → input_ack, plus the
 * stateless-recovery path (a list_delta that does not continue lastSeq forces
 * an automatic re-list, docs/protocol.md §4.2).
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { Client } from '../src/vendor/agentmirror/client.js';
import { decodeControl } from '../src/vendor/agentmirror/protocol.js';
import { encodeBinary, BINARY_KIND } from '../src/vendor/agentmirror/binary.js';

/** Minimal fake WebSocket. Client assigns ws.onopen/onmessage/onclose/onerror
 *  directly; the harness calls the _* helpers to fire events. */
class FakeWS {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;

  constructor(url) {
    this.url = url;
    this.readyState = FakeWS.CONNECTING;
    this.binaryType = '';
    this.sent = [];
    this.onopen = null;
    this.onmessage = null;
    this.onclose = null;
    this.onerror = null;
  }
  send(data) { this.sent.push(data); }
  close() {
    this.readyState = FakeWS.CLOSED;
    if (this.onclose) this.onclose({ code: 1000, reason: 'close' });
  }
  _open() { this.readyState = FakeWS.OPEN; if (this.onopen) this.onopen({}); }
  _text(s) { if (this.onmessage) this.onmessage({ data: s }); }
  _binary(u8) { if (this.onmessage) this.onmessage({ data: u8.buffer }); }
  _close(code, reason) {
    this.readyState = FakeWS.CLOSED;
    if (this.onclose) this.onclose({ code, reason });
  }
}

function makeClient(overrides = {}) {
  const sockets = [];
  const events = { onStateChange: [], onFrame: [], onBinary: [], onLocalError: [], onInputResult: [], onConnectionIssue: [] };
  const client = new Client({
    url: 'ws://127.0.0.1:9900/ws',
    token: 'tok-test',
    inputTimeoutMs: 500,
    backoff: { baseMs: 5, maxMs: 50, factor: 2, jitter: 0 },
    wsFactory: (u) => {
      const ws = new FakeWS(u);
      sockets.push(ws);
      return ws;
    },
    onStateChange: (s) => events.onStateChange.push(s),
    onFrame: (t) => events.onFrame.push(t),
    onBinary: (f) => events.onBinary.push(f),
    onLocalError: (c, m) => events.onLocalError.push(`${c}:${m}`),
    onInputResult: (r, ok, reason) => events.onInputResult.push([r, ok, reason]),
    onConnectionIssue: (reason) => events.onConnectionIssue.push(reason),
    ...overrides,
  });
  return { client, sockets, events };
}

/** Open the socket and complete auth. */
function openAndAuth(client, ws) {
  ws._open();
  ws._text(JSON.stringify({ v: 1, type: 'auth_ack', payload: { ok: true } }));
}

test('lifecycle: connect → auth → ready → auto list', () => {
  const { client, sockets } = makeClient();
  client.connect();
  const ws = sockets[0];
  assert.ok(ws, 'socket created');

  ws._open();
  const authText = ws.sent[0];
  assert.deepEqual(JSON.parse(authText), { v: 1, type: 'auth', payload: { token: 'tok-test' } });
  assert.equal(client.state, 'authenticating');

  ws._text(JSON.stringify({ v: 1, type: 'auth_ack', payload: { ok: true } }));
  assert.equal(client.state, 'ready');
  assert.equal(client.isReady, true);

  // READY triggers an automatic full list (stateless recovery).
  const listFrame = decodeControl(ws.sent[1]);
  assert.equal(listFrame.type, 'list');
  assert.equal(listFrame.payload.req_id >= 1, true);

  // Deliver a listing; the model builds.
  const listing = {
    v: 1, type: 'listing',
    payload: { req_id: listFrame.payload.req_id, seq: 42, workspaces: [
      { cwd: '/proj/a', session_count: 1, aggregate_state: 'working', sessions: [
        { ref: 's1', name: 'claude', cwd: '/proj/a', state: 'working', rows: 40, cols: 100 },
      ] },
    ] },
  };
  ws._text(JSON.stringify(listing));
  assert.equal(client.lastSeq, 42);
  assert.equal(client.workspaces.length, 1);
  assert.equal(client.session('s1').name, 'claude');
});

test('list_delta: continuous seq applies incrementally', () => {
  const { client, sockets } = makeClient();
  client.connect();
  const ws = sockets[0];
  openAndAuth(client, ws);

  ws._text(JSON.stringify({ v: 1, type: 'listing', payload: {
    req_id: 1, seq: 42, workspaces: [
      { cwd: '/proj/a', session_count: 2, aggregate_state: 'blocked', sessions: [
        { ref: 's1', name: 'claude', cwd: '/proj/a', state: 'working', rows: 40, cols: 100 },
        { ref: 's2', name: 'codex', cwd: '/proj/a', state: 'blocked', rows: 24, cols: 80 },
      ] },
    ],
  } }));

  const sent = ws.sent.length;
  ws._text(JSON.stringify({ v: 1, type: 'list_delta', payload: {
    seq: 43,
    added_sessions: [{ ref: 's3', name: 'claude', cwd: '/proj/b', state: 'done', rows: 25, cols: 100 }],
    removed_refs: ['s1'],
    changed_workspaces: [{ cwd: '/proj/a', session_count: 1, aggregate_state: 'done' }],
  } }));
  assert.equal(ws.sent.length, sent, 'continuous delta must NOT trigger a re-list');
  assert.equal(client.session('s3').state, 'done');
  assert.equal(client.session('s1'), undefined);
  assert.equal(client.workspaces.find((w) => w.cwd === '/proj/a').aggregate_state, 'done');
  assert.equal(client.workspaces.find((w) => w.cwd === '/proj/b').sessions.length, 1);
});

test('list_delta: discontinuous seq forces an automatic re-list', () => {
  const { client, sockets } = makeClient();
  client.connect();
  const ws = sockets[0];
  openAndAuth(client, ws);
  ws._text(JSON.stringify({ v: 1, type: 'listing', payload: { req_id: 1, seq: 42, workspaces: [] } }));

  const sent = ws.sent.length;
  ws._text(JSON.stringify({ v: 1, type: 'list_delta', payload: { seq: 99, added_sessions: [] } }));
  assert.equal(ws.sent.length, sent + 1, 'gap in seq must trigger a fresh list');
  assert.equal(decodeControl(ws.sent[sent]).type, 'list');
});

test('subscribe: sends subscribe frame and replays on reconnect', async () => {
  const { client, sockets } = makeClient();
  client.connect();
  const ws = sockets[0];
  openAndAuth(client, ws);

  assert.equal(client.subscribe('s1', 40, 100), true);
  const sub = decodeControl(ws.sent[ws.sent.length - 1]);
  assert.equal(sub.type, 'subscribe');
  assert.deepEqual(sub.payload, { ref: 's1', rows: 40, cols: 100 });

  // Reconnect: drop + reopen; READY replays the active subscription. The
  // reconnect fires on a timer (backoff base 5ms) so wait for the socket.
  ws._close(1006, 'lost');
  assert.equal(client.state, 'reconnecting');
  assert.equal(client.activeRefs.includes('s1'), true);

  let ws2;
  for (let i = 0; i < 50 && !ws2; i++) {
    await new Promise((r) => setTimeout(r, 10));
    ws2 = sockets[1];
  }
  assert.ok(ws2, 'reconnect socket opened');
  openAndAuth(client, ws2);
  const replayed = ws2.sent.filter((m) => decodeControl(m).type === 'subscribe');
  assert.equal(replayed.length, 1);
  assert.deepEqual(decodeControl(replayed[0]).payload, { ref: 's1', rows: 40, cols: 100 });
});

test('binary frames route to onBinary; scrollback header preserved', () => {
  const { client, sockets, events } = makeClient();
  client.connect();
  const ws = sockets[0];
  openAndAuth(client, ws);
  client.subscribe('s1', 40, 100);

  const snap = encodeBinary({ kind: BINARY_KIND.SNAPSHOT, ref: 's1', data: new Uint8Array([0x41]) });
  ws._binary(snap);
  assert.equal(events.onBinary.length, 1);
  assert.equal(events.onBinary[0].kind, BINARY_KIND.SNAPSHOT);
  assert.equal(events.onBinary[0].ref, 's1');
  assert.equal(events.onBinary[0].data[0], 0x41);

  const sb = encodeBinary({ kind: BINARY_KIND.SCROLLBACK, ref: 's1', reqId: 5, fromLine: -100, lineCount: 50, data: new Uint8Array([0x62]) });
  ws._binary(sb);
  const b = events.onBinary[1];
  assert.equal(b.kind, BINARY_KIND.SCROLLBACK);
  assert.equal(b.reqId, 5);
  assert.equal(b.fromLine, -100);
  assert.equal(b.lineCount, 50);
});

test('scrollWheel: sends scroll_wheel with ref and delta, no ack wait', () => {
  const { client, sockets } = makeClient();
  client.connect();
  const ws = sockets[0];
  openAndAuth(client, ws);
  assert.equal(client.scrollWheel('s1', -3), true);
  const frame = decodeControl(ws.sent[ws.sent.length - 1]);
  assert.equal(frame.type, 'scroll_wheel');
  assert.equal(frame.payload.ref, 's1');
  assert.equal(frame.payload.delta, -3);
});

test('input: sends frame, resolves on input_ack', () => {
  const { client, sockets, events } = makeClient();
  client.connect();
  const ws = sockets[0];
  openAndAuth(client, ws);
  client.subscribe('s1', 40, 100);

  const reqId = client.input('s1', '/model opus');
  assert.ok(reqId !== null);
  const frame = decodeControl(ws.sent[ws.sent.length - 1]);
  assert.equal(frame.type, 'input');
  assert.equal(frame.payload.text, '/model opus');

  ws._text(JSON.stringify({ v: 1, type: 'input_ack', payload: { req_id: reqId, ok: true } }));
  assert.deepEqual(events.onInputResult[0], [reqId, true, null]);
});

test('input: timeout is a decidable failure (no silent loss)', async () => {
  const { client, sockets, events } = makeClient();
  client.connect();
  const ws = sockets[0];
  openAndAuth(client, ws);
  client.subscribe('s1', 40, 100);

  const reqId = client.input('s1', 'x');
  assert.ok(reqId !== null);
  await new Promise((r) => setTimeout(r, 700)); // inputTimeoutMs = 500
  const entry = events.onInputResult.find(([r]) => r === reqId);
  assert.ok(entry, 'timeout must resolve the pending input');
  assert.equal(entry[1], false);
  assert.equal(entry[2], 'timeout');
});

test('keys: named-key input sends keys array without text', () => {
  const { client, sockets, events } = makeClient();
  client.connect();
  const ws = sockets[0];
  openAndAuth(client, ws);
  client.subscribe('s1', 40, 100);

  const reqId = client.keys('s1', 'esc');
  assert.ok(reqId !== null);
  const frame = decodeControl(ws.sent[ws.sent.length - 1]);
  assert.equal(frame.type, 'input');
  assert.deepEqual(frame.payload, { req_id: reqId, ref: 's1', keys: ['esc'] });
});

test('keys: repeated special keys remain in flight independently', () => {
  const { client, sockets, events } = makeClient();
  client.connect(); const ws = sockets[0]; openAndAuth(client, ws); client.subscribe('s1', 40, 100);
  const first = client.keys('s1', 'esc');
  const second = client.keys('s1', 'esc');
  assert.notEqual(first, second);
  assert.equal(client.pendingInputs.size, 2);
  ws._text(JSON.stringify({ v: 1, type: 'input_ack', payload: { req_id: second, ok: true } }));
  ws._text(JSON.stringify({ v: 1, type: 'input_ack', payload: { req_id: first, ok: true } }));
  assert.deepEqual(events.onInputResult.map(([id]) => id), [second, first]);
});

test('close reason is exposed for visible connection feedback', () => {
  const { client, sockets, events } = makeClient();
  client.connect(); const ws = sockets[0]; ws._close(1006, 'daemon unavailable');
  assert.deepEqual(events.onConnectionIssue, ['daemon unavailable']);
});

test('auth rejection is permanent (no reconnect loop)', () => {
  const { client, sockets } = makeClient();
  client.connect();
  const ws = sockets[0];
  ws._open();
  ws._text(JSON.stringify({ v: 1, type: 'auth_ack', payload: { ok: false, reason: 'bad token' } }));
  assert.equal(client.state, 'stopped');
  assert.equal(sockets.length, 1, 'must not open a second socket');
});

test('disconnect is permanent and drops the socket', () => {
  const { client, sockets } = makeClient();
  client.connect();
  const ws = sockets[0];
  openAndAuth(client, ws);
  client.subscribe('s1', 40, 100);
  client.disconnect();
  assert.equal(client.state, 'stopped');
  assert.equal(client.isReady, false);
  // Subscriptions stay bookkept (replay intent, mirroring Kotlin); a fresh
  // connect() would replay them — the connection itself is gone.
  assert.equal(client.activeRefs.includes('s1'), true);
});
