import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  rowFromDump, mergeSettle, lastGarble, lastListingPane, parseGeom, DEVICES_KEY,
} from '../scripts/garble-sweep.mjs';

test('rowFromDump maps dump + garbled label without pane text', () => {
  const dump = {
    events: [
      { type: 'activate', ref: 'dev::sock\u001f%1', t: 1, seq: 1 },
      { type: 'subscribe', ref: 'sock\u001f%1', rows: 24, cols: 80, sent: true, t: 2, seq: 2 },
      { type: 'snapshot', ref: 'sock\u001f%1', bytes: 99, t: 5, seq: 3 },
      { type: 'listing', listing_seq: 1, panes: [{ ref: 'sock\u001f%1', rows: 50, cols: 235 }] },
      {
        type: 'garble_label', ref: 'sock\u001f%1', garbled: true,
        reasons: ['overwide_line'], geom: '24x80', t: 8, seq: 5,
      },
    ],
    settle: {
      'dev::sock\u001f%1': { t0: 1 },
      'sock\u001f%1': { t_sub_sent: 2, t_snap_first: 5, t_stable: 8, t_last_resize: 6 },
    },
  };
  const row = rowFromDump({
    round: 1, uid: 'dev::sock\u001f%1', protoRef: 'sock\u001f%1', dump, timedOut: false, now: 123,
  });
  assert.equal(row.round, 1);
  assert.equal(row.garbled, true);
  assert.deepEqual(row.reasons, ['overwide_line']);
  assert.equal(row.local_cols, 80);
  assert.equal(row.listing_cols, 235);
  assert.equal(row.settle_ms, 7);
  assert.equal(row.sub_to_snap, 3);
  assert.equal(row.ts, 123);
  const s = JSON.stringify(row);
  assert.equal(s.includes('token'), false);
  assert.ok(!/ESC\[/.test(s));
});

test('mergeSettle joins uid t0 with protocol-ref snapshot times', () => {
  const dump = {
    settle: {
      uid: { t0: 10 },
      pref: { t_sub_sent: 12, t_snap_first: 20, t_last_resize: 21, t_stable: 40 },
    },
  };
  const s = mergeSettle(dump, 'uid', 'pref');
  assert.equal(s.settle_ms, 30);
  assert.equal(s.click_to_sub, 2);
  assert.equal(s.sub_to_snap, 8);
});

test('helpers: geom, last listing/garble', () => {
  assert.deepEqual(parseGeom('24x80'), { rows: 24, cols: 80 });
  const events = [
    { type: 'listing', panes: [{ ref: 'a', rows: 1, cols: 2 }] },
    { type: 'garble_label', ref: 'a', garbled: false, reasons: [] },
    { type: 'garble_label', ref: 'a', garbled: true, reasons: ['cup_clamped'] },
  ];
  assert.equal(lastListingPane(events, 'a').cols, 2);
  assert.equal(lastGarble(events, 'a').garbled, true);
  assert.equal(DEVICES_KEY.startsWith('agentmirror.desktop.v1.'), true);
});
