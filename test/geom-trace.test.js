import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Client } from '../src/vendor/agentmirror/client.js';
import { decodeControl } from '../src/vendor/agentmirror/protocol.js';
import { encodeBinary, BINARY_KIND } from '../src/vendor/agentmirror/binary.js';
import { SameWidthController } from '../src/term/sameWidth.js';
import {
  resetGeomTrace, dumpGeomTrace, bookOf, formatLine, geomTrace,
} from '../src/term/geomTrace.js';

class FakeWS {
  static OPEN = 1;
  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.sent = [];
    this.onopen = this.onmessage = this.onclose = this.onerror = null;
  }
  send(data) { this.sent.push(data); }
  close() {
    this.readyState = 3;
    if (this.onclose) this.onclose({ code: 1000, reason: 'close' });
  }
  _open() { this.readyState = FakeWS.OPEN; if (this.onopen) this.onopen({}); }
  _text(s) { if (this.onmessage) this.onmessage({ data: s }); }
  _binary(u8) { if (this.onmessage) this.onmessage({ data: u8.buffer }); }
}

function makeClient() {
  const sockets = [];
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
  });
  return { client, sockets };
}

function openAndAuth(ws) {
  ws._open();
  ws._text(JSON.stringify({ v: 1, type: 'auth_ack', payload: { ok: true } }));
}

test('geomTrace: formatLine has both operands, never a token field', () => {
  resetGeomTrace();
  const rec = geomTrace('subscribe', {
    ref: 'r1', rows: 47, cols: 157, reason: 'settle', ok: true, skipped: null,
    bookkept_rows: 47, bookkept_cols: 157, token: 'SECRET',
  });
  assert.equal(rec.token, undefined);
  const line = formatLine(rec);
  assert.match(line, /geom subscribe/);
  assert.match(line, /rows=47/);
  assert.match(line, /cols=157/);
  assert.match(line, /reason=settle/);
  assert.doesNotMatch(line, /SECRET/);
});

test('subscribe before READY is skipped not_ready but bookkept per ref', () => {
  resetGeomTrace();
  const { client } = makeClient();
  assert.equal(client.subscribe('a', 40, 120, 'activate'), true);
  assert.equal(client.subscribe('b', 24, 80, 'activate'), true);
  assert.deepEqual(bookOf('a'), { bookkept_rows: 40, bookkept_cols: 120 });
  assert.deepEqual(bookOf('b'), { bookkept_rows: 24, bookkept_cols: 80 });
  const skips = dumpGeomTrace().filter((e) => e.event === 'subscribe');
  assert.equal(skips.length, 2);
  assert.equal(skips[0].skipped, 'not_ready');
  assert.equal(skips[0].ok, false);
  assert.equal(skips[1].ref, 'b');
  assert.equal(skips[1].bookkept_cols, 80);
});

test('subscribe on the wire has no reason field; log has reason', () => {
  resetGeomTrace();
  const { client, sockets } = makeClient();
  client.connect();
  openAndAuth(sockets[0]);
  assert.equal(client.subscribe('s1', 47, 157, 'settle'), true);
  const frames = sockets[0].sent.map((m) => decodeControl(m)).filter((f) => f.type === 'subscribe');
  assert.ok(frames.length >= 1);
  assert.deepEqual(frames.at(-1).payload, { ref: 's1', rows: 47, cols: 157 });
  assert.equal('reason' in frames.at(-1).payload, false);
  const log = dumpGeomTrace().filter((e) => e.event === 'subscribe' && e.ok === true).at(-1);
  assert.equal(log.reason, 'settle');
  assert.equal(log.cols, 157);
  assert.equal(log.bookkept_cols, 157);
});

test('books stay per-ref when switching sessions', () => {
  resetGeomTrace();
  const { client, sockets } = makeClient();
  client.connect();
  openAndAuth(sockets[0]);
  client.subscribe('paneA', 50, 235, 'activate');
  client.subscribe('paneB', 47, 157, 'activate');
  assert.deepEqual(bookOf('paneA'), { bookkept_rows: 50, bookkept_cols: 235 });
  assert.deepEqual(bookOf('paneB'), { bookkept_rows: 47, bookkept_cols: 157 });
  client.subscribe('paneA', 50, 200, 'settle');
  assert.deepEqual(bookOf('paneA'), { bookkept_rows: 50, bookkept_cols: 200 });
  assert.deepEqual(bookOf('paneB'), { bookkept_rows: 47, bookkept_cols: 157 });
});

test('gate_none is distinguishable from a sent subscribe', () => {
  resetGeomTrace();
  const gate = new SameWidthController();
  const first = gate.settle(47, 157);
  assert.equal(first.type, 'subscribe');
  gate.noteSent(first.rows, first.cols);
  const second = gate.settle(47, 157);
  assert.equal(second.type, 'none');
  geomTrace('subscribe', {
    ref: 'x', rows: 47, cols: 157, reason: 'settle', ok: false, skipped: 'gate_none',
    ...bookOf('x'),
  });
  const row = dumpGeomTrace().at(-1);
  assert.equal(row.skipped, 'gate_none');
  assert.equal(row.ok, false);
});

test('snapshot log carries frame_cols from listing; no pane bytes', () => {
  resetGeomTrace();
  const { client, sockets } = makeClient();
  client.connect();
  const ws = sockets[0];
  openAndAuth(ws);
  ws._text(JSON.stringify({
    v: 1,
    type: 'listing',
    payload: {
      req_id: 1,
      seq: 1,
      workspaces: [{
        cwd: '/tmp/x', session_count: 1, aggregate_state: 'idle',
        sessions: [{ ref: 's1', name: 's1', cwd: '/tmp/x', state: 'idle', rows: 50, cols: 235 }],
      }],
    },
  }));
  const bin = encodeBinary({ kind: BINARY_KIND.SNAPSHOT, ref: 's1', data: new Uint8Array([0x1b, 0x5b, 0x48]) });
  ws._binary(bin);
  const snap = dumpGeomTrace().filter((e) => e.event === 'snapshot').at(-1);
  assert.ok(snap, 'snapshot log missing');
  assert.equal(snap.frame_cols, 235);
  assert.equal(snap.bytes_len, 3);
  assert.equal(JSON.stringify(snap).includes('\u001b'), false);
});
