import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  AM_DIAG_CAPACITY, SETTLE_QUIET_MS, push, dump, resetDiag, beginActivate,
  recordHostGeom, hostGeomOf, resetHostGeom,
  markSubscribed, recordLiveHostGeom, liveHostGeomOf, stampHostAtSnap,
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

test('settle decomposes click → sub → snap → last resize → stable', async () => {
  resetDiag();
  beginActivate('pane-a');
  push({ type: 'subscribe', ref: 'pane-a', rows: 24, cols: 80, sent: true });
  push({ type: 'snapshot', ref: 'pane-a', bytes: 100, kind: 1 });
  push({ type: 'term_resize', ref: 'pane-a', from_cols: 80, to_cols: 80, from_rows: 24, to_rows: 24 });
  push({ type: 'garble_label', ref: 'pane-a', garbled: false, reasons: [], geom: '24x80' });
  await new Promise((r) => setTimeout(r, SETTLE_QUIET_MS + 20));
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

test('t_stable arms after one garble_label and SETTLE_QUIET_MS without resize/snapshot', async () => {
  resetDiag();
  beginActivate('pane-b');
  push({ type: 'garble_label', ref: 'pane-b', garbled: true, reasons: ['overwide_line'], geom: '39x114' });
  const before = dump().settle['pane-b'];
  assert.equal(before.t_stable, null);
  await new Promise((r) => setTimeout(r, SETTLE_QUIET_MS + 20));
  const after = dump().settle['pane-b'];
  assert.ok(after.t_stable != null);
  assert.equal(after.t_stable - after.t0 >= 0, true);
});

test('term_resize or write_snapshot in the quiet window cancels t_stable', async () => {
  resetDiag();
  beginActivate('pane-c');
  push({ type: 'garble_label', ref: 'pane-c', garbled: false, reasons: [], geom: '24x80' });
  push({ type: 'write_snapshot', ref: 'pane-c', bytes: 10, term_cols: 80 });
  await new Promise((r) => setTimeout(r, SETTLE_QUIET_MS + 20));
  assert.equal(dump().settle['pane-c'].t_stable, null);

  resetDiag();
  beginActivate('pane-d');
  push({ type: 'garble_label', ref: 'pane-d', garbled: false, reasons: [], geom: '24x80' });
  push({ type: 'term_resize', ref: 'pane-d', from_cols: 80, to_cols: 81, from_rows: 24, to_rows: 24 });
  await new Promise((r) => setTimeout(r, SETTLE_QUIET_MS + 20));
  assert.equal(dump().settle['pane-d'].t_stable, null);
});

test('host geom cache survives __amDiag.reset and is not the ring', () => {
  resetHostGeom();
  resetDiag();
  recordHostGeom([{ ref: 'sock\u001f%1', rows: 50, cols: 235 }], 7);
  assert.deepEqual(hostGeomOf('sock\u001f%1'), { rows: 50, cols: 235, listing_seq: 7 });
  resetDiag();
  assert.deepEqual(hostGeomOf('sock\u001f%1'), { rows: 50, cols: 235, listing_seq: 7 });
  assert.equal(dump().length, 0);
});

test('live host geom ignores listing before subscribe and stamps after', () => {
  resetHostGeom();
  resetDiag();
  recordLiveHostGeom([{ ref: 's1', rows: 50, cols: 235 }], 1);
  assert.equal(liveHostGeomOf('s1'), null);
  markSubscribed('s1');
  recordLiveHostGeom([{ ref: 's1', rows: 39, cols: 114 }], 2);
  assert.deepEqual(liveHostGeomOf('s1'), { rows: 39, cols: 114, listing_seq: 2 });
  resetDiag();
  assert.equal(stampHostAtSnap('s1').host_cols_at_snap, 114);
  assert.equal(stampHostAtSnap('s1').host_cols_live, 114);
});
