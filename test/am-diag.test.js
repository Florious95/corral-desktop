import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  AM_DIAG_CAPACITY, push, dump, resetDiag, beginActivate,
} from '../src/term/amDiag.js';

test('__amDiag dump is JSON and ring drops oldest', () => {
  resetDiag();
  beginActivate('s1');
  push({ type: 'subscribe', ref: 's1', rows: 24, cols: 80, sent: true });
  push({ type: 'snapshot', ref: 's1', bytes: 12, kind: 1 });
  const json = JSON.stringify(dump());
  const parsed = JSON.parse(json);
  assert.ok(parsed.events.length >= 3);
  assert.equal(parsed.events[0].type, 'activate');
  assert.equal(typeof parsed.events[0].t, 'number');
  assert.equal(typeof parsed.events[0].seq, 'number');
  assert.ok(globalThis.__amDiag);
  assert.equal(typeof globalThis.__amDiag.dump, 'function');

  resetDiag();
  const extra = 20;
  for (let i = 0; i < AM_DIAG_CAPACITY + extra; i++) {
    push({ type: 'fit', ref: 'r', i });
  }
  const d = dump();
  assert.equal(d.length, AM_DIAG_CAPACITY);
  assert.equal(d.dropped, extra);
  assert.equal(d.events[0].i, extra);
});

test('settle decomposes click → sub → snap → last resize → stable', () => {
  resetDiag();
  beginActivate('pane-a');
  push({ type: 'subscribe', ref: 'pane-a', rows: 24, cols: 80, sent: true });
  push({ type: 'snapshot', ref: 'pane-a', bytes: 100, kind: 1 });
  push({ type: 'term_resize', ref: 'pane-a', from_cols: 80, to_cols: 80, from_rows: 24, to_rows: 24 });
  push({ type: 'garble_label', ref: 'pane-a', garbled: false, reasons: [], geom: '24x80' });
  push({ type: 'garble_label', ref: 'pane-a', garbled: false, reasons: [], geom: '24x80' });
  const s = dump().settle['pane-a'];
  assert.ok(s.t0 != null);
  assert.ok(s.t_sub_sent != null);
  assert.ok(s.t_snap_first != null);
  assert.ok(s.t_last_resize != null);
  assert.ok(s.t_stable != null);
  assert.ok(s.settle_ms >= 0);
  assert.ok(s.segments.click_to_sub != null);
  assert.ok(s.segments.sub_to_snap != null);
});
