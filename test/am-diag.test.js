import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  push, dump, resetDiag, resetHostGeom, recordHostGeom, hostGeomOf,
  beginActivate, byteStats, AM_DIAG_CAPACITY,
} from '../src/term/amDiag.js';

test('amDiag dump has seq/ref/geometry fields and never stores a token key', () => {
  resetDiag();
  resetHostGeom();
  beginActivate('sock\x1f%1');
  recordHostGeom([{ ref: 'sock\x1f%1', rows: 50, cols: 235 }], 7);
  push({
    type: 'subscribe', ref: 'sock\x1f%1', rows: 50, cols: 235, sent: true,
    host_cols: 235, host_rows: 50, req_cols: 114, req_rows: 42,
  });
  const d = dump();
  assert.equal(d.seq >= 2, true);
  const sub = d.events.find((e) => e.type === 'subscribe');
  assert.equal(sub.host_cols, 235);
  assert.equal(hostGeomOf('sock\x1f%1').cols, 235);
  const blob = JSON.stringify(d);
  assert.equal(blob.includes('"token"'), false);
  assert.equal(blob.includes('authkey'), false);
});

test('byteStats counts only, no decoded text', () => {
  const u8 = new Uint8Array([0x1b, 0x5b, 0x48, 0x0a, 0x0d, 65]);
  const s = byteStats(u8);
  assert.deepEqual(s, { bytes: 6, esc: 1, lf: 1, cr: 1, csi: 1 });
});

test('ring capacity is bounded', () => {
  resetDiag();
  for (let i = 0; i < AM_DIAG_CAPACITY + 10; i++) push({ type: 'fit', ref: 'r', i });
  const d = dump();
  assert.equal(d.length, AM_DIAG_CAPACITY);
  assert.equal(d.dropped, 10);
});
