import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  visibleWidth, inferCapturedCols, createResizeAnnouncer, REASSERT_MS,
} from '../src/term/resizeAnnounce.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test('visibleWidth strips CSI', () => {
  assert.equal(visibleWidth('\x1b[31mabc\x1b[0m'), 3);
});

test('inferCapturedCols: majority full-width lines = pane cols', () => {
  const line = 'x'.repeat(40);
  const text = Array.from({ length: 8 }, () => line).join('\n');
  assert.equal(inferCapturedCols(text), 40);
});

test('inferCapturedCols: sparse prompt is not a pane width', () => {
  assert.equal(inferCapturedCols('>\n\n\n'), null);
  const mixed = ['hello', 'x'.repeat(80), 'y', 'z'].join('\n');
  assert.equal(inferCapturedCols(mixed), null);
});

test('fromFit sends once per change; reassert sends again after debounce', async () => {
  const log = [];
  const a = createResizeAnnouncer({ reassertMs: 30, send: (r, c) => log.push([r, c]) });
  a.fromFit(24, 100);
  a.reassert();
  a.reassert();
  await sleep(10);
  assert.deepEqual(log, [[24, 100]]);
  await sleep(40);
  assert.deepEqual(log, [[24, 100], [24, 100]]);
  assert.equal(REASSERT_MS, 250);
  a.dispose();
});

test('reassert is a no-op before the first fit', async () => {
  const log = [];
  const a = createResizeAnnouncer({ reassertMs: 5, send: (r, c) => log.push([r, c]) });
  a.reassert();
  await sleep(20);
  assert.deepEqual(log, []);
  a.dispose();
});
