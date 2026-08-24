/*
 * Control-frame codec tests: encode/decode round trips plus golden-file
 * assertions against the shared contract fixtures in
 * server/internal/protocol/testdata/ (leader-arbitrated contract, §10.1).
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { encodeControl, decodeControl, ProtocolError, VERSION, AGENT_STATES, ERROR_CODES } from '../src/vendor/agentmirror/protocol.js';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const FIXTURES = join(ROOT, 'test', 'testdata');

function fixture(name) {
  return JSON.parse(readFileSync(join(FIXTURES, name), 'utf8'));
}

test('encode: auth matches golden fixture (field order frozen)', () => {
  const text = encodeControl('auth', { token: 'tok-abc-123' });
  const parsed = JSON.parse(text);
  assert.equal(parsed.v, VERSION);
  assert.equal(parsed.type, 'auth');
  assert.deepEqual(parsed.payload, { token: 'tok-abc-123' });
});

test('encode: auth rejects empty token', () => {
  assert.throws(() => encodeControl('auth', { token: '' }), (e) => e instanceof ProtocolError && e.code === 'invalid_field');
});

test('encode: input text variant matches golden field order', () => {
  const parsed = JSON.parse(encodeControl('input', { req_id: 9, ref: 's1', text: '/model opus' }));
  assert.deepEqual(parsed, { v: 1, type: 'input', payload: { req_id: 9, ref: 's1', text: '/model opus' } });
});

test('encode: input keys variant matches golden field order', () => {
  const parsed = JSON.parse(encodeControl('input', { req_id: 10, ref: 's1', keys: ['esc', 'ctrl_c', 'tab'] }));
  assert.deepEqual(parsed, { v: 1, type: 'input', payload: { req_id: 10, ref: 's1', keys: ['esc', 'ctrl_c', 'tab'] } });
});

test('encode: input attachment variant keeps path out of text', () => {
  const parsed = JSON.parse(encodeControl('input', {
    req_id: 11, ref: 's1', attachment_path: '/host/uploads/image.png',
  }));
  assert.deepEqual(parsed.payload, { req_id: 11, ref: 's1', attachment_path: '/host/uploads/image.png' });
  assert.equal(parsed.payload.text, undefined);
});

test('encode: input with both text and keys is rejected (mutually exclusive)', () => {
  assert.throws(
    () => encodeControl('input', { req_id: 1, ref: 's1', text: 'x', keys: ['esc'] }),
    (e) => e instanceof ProtocolError && /both text and keys/.test(e.message),
  );
});

test('encode: input with unknown key is rejected (closed set)', () => {
  assert.throws(
    () => encodeControl('input', { req_id: 1, ref: 's1', keys: ['home'] }),
    (e) => e instanceof ProtocolError && /unknown input key/.test(e.message),
  );
});

test('encode: bare-enter input (empty text) omits the text field', () => {
  const parsed = JSON.parse(encodeControl('input', { req_id: 3, ref: 's1', text: '' }));
  assert.deepEqual(parsed.payload, { req_id: 3, ref: 's1' });
});

test('decode: every golden control-frame fixture round-trips through validate', () => {
  const files = [
    'auth.json', 'auth_ack_ok.json', 'auth_ack_reject.json',
    'list.json', 'listing.json', 'list_delta.json',
    'subscribe.json', 'unsubscribe.json', 'input.json', 'input_keys.json',
    'input_ack_ok.json', 'input_ack_fail.json', 'scrollback.json',
    'resize.json', 'error.json',
  ];
  for (const f of files) {
    const golden = fixture(f);
    const text = JSON.stringify(golden);
    const decoded = decodeControl(text);
    assert.equal(decoded.type, golden.type, `${f}: type`);
    assert.deepEqual(decoded.payload, golden.payload, `${f}: payload`);
  }
});

test('decode: missing version is an error', () => {
  assert.throws(() => decodeControl('{"type":"list","payload":{"req_id":1}}'),
    (e) => e instanceof ProtocolError && e.code === 'missing_version');
});

test('decode: wrong version is unsupported_version', () => {
  assert.throws(() => decodeControl('{"v":99,"type":"list","payload":{"req_id":1}}'),
    (e) => e instanceof ProtocolError && e.code === 'unsupported_version');
});

test('decode: unknown type is unsupported_type', () => {
  assert.throws(() => decodeControl('{"v":1,"type":"ping","payload":{}}'),
    (e) => e instanceof ProtocolError && e.code === 'unsupported_type');
});

test('decode: unknown fields inside payload are ignored (forward compat)', () => {
  const d = decodeControl('{"v":1,"type":"listing","payload":{"req_id":7,"seq":42,"workspaces":[],"future_field":true}}');
  assert.equal(d.payload.future_field, undefined);
  assert.equal(d.type, 'listing');
});

test('decode: listing missing required seq is invalid_field', () => {
  assert.throws(() => decodeControl('{"v":1,"type":"listing","payload":{"req_id":7}}'),
    (e) => e instanceof ProtocolError && e.code === 'invalid_field');
});

test('decode: input_ack ok:false without reason is invalid (one-field-one-meaning)', () => {
  assert.throws(() => decodeControl('{"v":1,"type":"input_ack","payload":{"req_id":9,"ok":false}}'),
    (e) => e instanceof ProtocolError && e.code === 'invalid_field');
});

test('enumerations are the documented closed sets', () => {
  assert.deepEqual(AGENT_STATES, ['working', 'idle', 'blocked', 'done', 'unknown']);
  assert.deepEqual(ERROR_CODES, ['unauthorized', 'bad_frame', 'unsupported_version', 'unsupported_type', 'session_not_found', 'internal']);
});
