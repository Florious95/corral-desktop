/*
 * Binary-frame codec tests: decode the contract .bin fixtures byte-exactly
 * (they are part of the protocol, §10.1), then round-trip encode/decode.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { decodeBinary, encodeBinary, BINARY_KIND } from '../src/vendor/agentmirror/binary.js';
import { ProtocolError } from '../src/vendor/agentmirror/protocol.js';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const FIXTURES = join(ROOT, 'test', 'testdata');

function fixture(name) {
  return new Uint8Array(readFileSync(join(FIXTURES, name)));
}

test('decode: snapshot.bin fixture', () => {
  const f = decodeBinary(fixture('snapshot.bin'));
  assert.equal(f.kind, BINARY_KIND.SNAPSHOT);
  assert.equal(f.ref, 's1');
  assert.equal(f.reqId, 0);
  assert.equal(f.fromLine, 0);
  assert.equal(f.lineCount, 0);
  // payload: ESC[31mred screen ESC[0m\n
  const expected = new Uint8Array([0x1b, 0x5b, 0x33, 0x31, 0x6d, 0x72, 0x65, 0x64, 0x20, 0x73, 0x63, 0x72, 0x65, 0x65, 0x6e, 0x1b, 0x5b, 0x30, 0x6d, 0x0a]);
  assert.deepEqual(f.data, expected);
});

test('decode: delta.bin fixture', () => {
  const f = decodeBinary(fixture('delta.bin'));
  assert.equal(f.kind, BINARY_KIND.DELTA);
  assert.equal(f.ref, 's1');
  assert.equal(new TextDecoder().decode(f.data), 'append');
});

test('decode: scrollback.bin fixture carries converged range header', () => {
  const f = decodeBinary(fixture('scrollback.bin'));
  assert.equal(f.kind, BINARY_KIND.SCROLLBACK);
  assert.equal(f.ref, 's1');
  assert.equal(f.reqId, 5);
  assert.equal(f.fromLine, -100);
  assert.equal(f.lineCount, 50);
  assert.equal(new TextDecoder().decode(f.data), 'history page one');
});

test('encode: snapshot round-trips byte-identically to the fixture', () => {
  const original = fixture('snapshot.bin');
  const f = decodeBinary(original);
  const re = encodeBinary(f);
  assert.deepEqual(re, original);
});

test('encode: scrollback round-trips byte-identically to the fixture', () => {
  const original = fixture('scrollback.bin');
  const f = decodeBinary(original);
  const re = encodeBinary(f);
  assert.deepEqual(re, original);
});

test('decode: bad magic is rejected', () => {
  const bad = new Uint8Array([0x58, 0x58, 0x01, 0x01, 0x02, 0x73, 0x31]);
  assert.throws(() => decodeBinary(bad), (e) => e instanceof ProtocolError && e.code === 'bad_magic');
});

test('decode: truncated frame is rejected', () => {
  assert.throws(() => decodeBinary(new Uint8Array([0x52, 0x41, 0x01])),
    (e) => e instanceof ProtocolError && e.code === 'truncated');
});

test('decode: unknown kind is rejected', () => {
  const bad = new Uint8Array([0x52, 0x41, 0x01, 0x09, 0x02, 0x73, 0x31]);
  assert.throws(() => decodeBinary(bad), (e) => e instanceof ProtocolError && e.code === 'unknown_kind');
});

test('decode: empty ref is rejected', () => {
  const bad = new Uint8Array([0x52, 0x41, 0x01, 0x01, 0x00, 0x00]);
  assert.throws(() => decodeBinary(bad), (e) => e instanceof ProtocolError && e.code === 'invalid_ref');
});

test('encode: empty ref is rejected on encode side too', () => {
  assert.throws(() => encodeBinary({ kind: BINARY_KIND.DELTA, ref: '', data: new Uint8Array(0) }),
    (e) => e instanceof ProtocolError && e.code === 'invalid_ref');
});

test('encode: non-ASCII ref is encoded as UTF-8 and decodes back', () => {
  const frame = { kind: BINARY_KIND.DELTA, ref: '会话-1', data: new Uint8Array([0x61]) };
  const bytes = encodeBinary(frame);
  const back = decodeBinary(bytes);
  assert.equal(back.ref, '会话-1');
});
