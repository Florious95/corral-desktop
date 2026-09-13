import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Client } from '../src/core/client.js';
import { Client as CoreClient } from '../deps/corral-core/web/js/client.js';
import * as core from '../deps/corral-core/web/js/protocol.js';
import { encodeControl, decodeControl } from '../src/core/protocol.js';
import { dumpGeomTrace, resetGeomTrace } from '../src/term/geomTrace.js';

const wire = (type, payload, v = 1) => JSON.stringify({ v, type, payload });

test('core owns lifecycle, listing, text input and pending machinery', () => {
  assert.equal(Object.getPrototypeOf(Client.prototype), CoreClient.prototype);
  for (const name of ['connect', 'attemptConnect', 'handleOpen', 'handleClose', 'handleFrame',
    'scheduleReconnect', 'buildFromListing', 'applyDelta', 'input', 'registerPending',
    'resolveInput', 'clearPending', 'scrollback']) {
    assert.equal(Client.prototype[name], CoreClient.prototype[name], name);
  }
  assert.equal(core.FRAME_TYPES.includes('level2_frame'), false);
  assert.equal(core.INPUT_KEYS.includes('backspace'), false);
});

test('extension codecs preserve documented fields and reject invalid envelopes/payloads', () => {
  const frames = [
    ['level2_subscribe', { workspace: '/a' }], ['level2_unsubscribe', {}],
    ['level2_frame', { workspace: '/a', seq: 1, sessions: [] }],
    ['level2_heartbeat', { workspace: '/a', seq: 2 }],
    ['pane_mode_changed', { ref: 'a', in_copy_mode: false }],
    ['scroll_wheel', { ref: 'a', delta: -3 }],
    ['attach_preview', { ref: 'a', path: '/host/image.png' }],
    ['input', { req_id: 3, ref: 'a', keys: ['backspace', 'esc'] }],
    ['input', { req_id: 4, ref: 'a', text: 'caption', attachment_path: '/host/image.png' }],
  ];
  for (const [type, payload] of frames) {
    assert.deepEqual(decodeControl(encodeControl(type, payload)), { type, payload });
    assert.deepEqual(decodeControl(wire(type, { ...payload, future: true })), { type, payload });
    assert.throws(() => decodeControl(wire(type, payload, 2)), { code: 'unsupported_version' });
  }
  for (const [type, payload] of [
    ['level2_frame', { workspace: '/a', seq: 0 }],
    ['level2_frame', { workspace: '/a', seq: 1, sessions: {} }],
    ['level2_subscribe', { workspace: '' }],
    ['level2_heartbeat', { workspace: '/a', seq: 1.2 }],
    ['scroll_wheel', { ref: 'a', delta: 0 }],
    ['scroll_wheel', { ref: 'a', delta: 0.5 }],
    ['attach_preview', { ref: 'a', path: 'relative.png' }],
    ['pane_mode_changed', { ref: '', in_copy_mode: false }],
    ['pane_mode_changed', { ref: 'a', in_copy_mode: 'false' }],
    ['input', { req_id: 1, ref: 'a', keys: 'backspace' }],
    ['input', { req_id: 1, ref: 'a', keys: { includes: true } }],
    ['input', { req_id: 1, ref: 'a', text: 3, attachment_path: '/image' }],
    ['input', { req_id: 0, ref: 'a', keys: ['backspace'] }],
    ['input', { req_id: 1, ref: '', keys: ['backspace'] }],
    ['input', { req_id: 1, ref: 'a', keys: ['backspace', 'unknown'] }],
    ['input', { req_id: 1, ref: 'a', keys: ['backspace'], text: 'text' }],
    ['input', { req_id: 1, ref: 'a', keys: ['esc'], attachment_path: '/image' }],
    ['input', { req_id: 1, ref: 'a', bytes: new Uint8Array() }],
    ['input', { req_id: 1, ref: 'a', bytes: 'not-base64' }],
    ['input', { req_id: 1, ref: 'a', bytes: new Uint8Array([0x41]), text: 'text' }],
  ]) {
    assert.throws(() => encodeControl(type, payload), { code: 'invalid_field' });
    assert.throws(() => decodeControl(wire(type, payload)), { code: 'invalid_field' });
  }
  assert.throws(() => decodeControl(wire('level2_unsubscribe', [])), { code: 'bad_frame' });
  assert.throws(() => decodeControl(wire('future', {})), { code: 'unsupported_type' });
});

test('bytes input stays base64 on the wire and is mutually exclusive', () => {
  const bytes = new Uint8Array([0x1b, 0x5b, 0x31, 0x35, 0x7e]);
  const text = encodeControl('input', { req_id: 5, ref: 'a', bytes });
  assert.deepEqual(JSON.parse(text).payload, { req_id: 5, ref: 'a', bytes: 'G1sxNX4=' });
  assert.deepEqual(decodeControl(text), { type: 'input', payload: { req_id: 5, ref: 'a', bytes: 'G1sxNX4=' } });
  assert.throws(() => encodeControl('input', { req_id: 5, ref: 'a', bytes, keys: ['esc'] }), { code: 'invalid_field' });
});

test('basic frames remain byte-identical to core codec', () => {
  for (const [type, payload] of [
    ['auth', { token: 'test-only' }], ['list', { req_id: 1 }],
    ['input', { req_id: 2, ref: 'a', text: 'hello' }],
    ['input', { req_id: 3, ref: 'a' }], ['input', { req_id: 4, ref: 'a', keys: ['esc'] }],
    ['subscribe', { ref: 'a', rows: 24, cols: 80 }],
    ['listing', { req_id: 1, seq: 1, workspaces: [] }],
  ]) {
    assert.equal(encodeControl(type, payload), core.encodeControl(type, payload));
    assert.deepEqual(decodeControl(wire(type, payload)), core.decodeControl(wire(type, payload)));
  }
});

test('level2 replays only latest workspace alongside core subscriptions and trace', () => {
  resetGeomTrace();
  const sent = [];
  const frames = [];
  const client = new Client({ url: 'ws://isolated.invalid', token: 'test-only', onFrame: (t, p) => frames.push([t, p]) });
  client.subscribe('a', 24, 80);
  client.subscribe('b', 30, 100);
  client.subscribeOverlay('fixture-socket');
  client.subscribeLevel2('/a');
  client.subscribeLevel2('/b');
  assert.equal(client.subscribeLevel2(''), false);
  client.ws = { readyState: 1, send: text => sent.push(decodeControl(text)) };
  client.handleMessage(wire('auth_ack', { ok: true }));
  assert.deepEqual(sent.map(f => f.type), ['list', 'subscribe', 'subscribe', 'overlay_subscribe', 'level2_subscribe']);
  assert.deepEqual(sent.at(-1).payload, { workspace: '/b' });
  assert.equal(dumpGeomTrace().filter(e => e.reason === 'reconnect').length, 2);
  client.handleMessage(wire('level2_frame', { workspace: '/b', seq: 1, sessions: [] }));
  assert.equal(frames.at(-1)[0], 'level2_frame');
  client.resize('a', 25, 81);
  assert.deepEqual(client.activeSubscriptions.get('a'), { rows: 24, cols: 80 }, 'retain original resize replay semantics');
  client.unsubscribe('a');
  client.unsubscribeLevel2();
  sent.length = 0;
  client.replaySubscriptions();
  assert.deepEqual(sent.map(f => f.type), ['subscribe', 'overlay_subscribe']);
  assert.equal(sent[0].payload.ref, 'b');
});

test('extended inputs use core pending ACK, timeout and disconnect handling', async () => {
  const results = [];
  const errors = [];
  const sent = [];
  const client = new Client({ url: 'ws://isolated.invalid', token: 'test-only', inputTimeoutMs: 10,
    onInputResult: (...args) => results.push(args), onLocalError: (...args) => errors.push(args) });
  client.ws = { readyState: 1, send: text => sent.push(decodeControl(text)) };
  const key = client.keys('a', 'backspace');
  client.handleMessage(wire('input_ack', { req_id: key, ok: false, reason: 'not_subscribed' }));
  assert.deepEqual(results.at(-1), [key, false, 'not_subscribed']);
  const attachment = client.inputAttachment('a', '/host/image.png');
  await new Promise(r => setTimeout(r, 30));
  assert.deepEqual(results.at(-1), [attachment, false, 'timeout']);
  const pending = client.keys('a', 'backspace');
  client.handleClose({ code: 1006 });
  assert.deepEqual(results.at(-1), [pending, false, 'connection lost']);
  assert.equal(client.pendingInputs.size, 0);
  const count = sent.length;
  assert.equal(client.inputAttachment('a', undefined), null);
  assert.equal(client.attachPreview('a', undefined), false);
  assert.equal(sent.length, count);
  assert.equal(errors.length, 2);
});
