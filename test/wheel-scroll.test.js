import { test } from 'node:test';
import assert from 'node:assert/strict';
import { linesFromWheel, WheelAccumulator, WHEEL_FLUSH_MS, LINE_PX } from '../src/term/wheelScroll.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test('linesFromWheel: pixel mode folds by LINE_PX', () => {
  assert.equal(linesFromWheel({ deltaY: 80, deltaMode: 0 }), 80 / LINE_PX);
  assert.equal(linesFromWheel({ deltaY: -40, deltaMode: 0 }), -1);
});

test('linesFromWheel: line and page modes', () => {
  assert.equal(linesFromWheel({ deltaY: 3, deltaMode: 1 }), 3);
  assert.equal(linesFromWheel({ deltaY: -1, deltaMode: 2 }), -24);
  assert.equal(linesFromWheel({ deltaY: 0, deltaMode: 0 }), 0);
});

test('WheelAccumulator merges ticks and only sends non-zero integers', async () => {
  const sent = [];
  const acc = new WheelAccumulator((d) => sent.push(d), 20);
  acc.onWheel({ deltaY: 30, deltaMode: 0 });  // 0.75 line
  acc.onWheel({ deltaY: 30, deltaMode: 0 });  // 1.5
  await sleep(40);
  assert.deepEqual(sent, [1]);
  acc.dispose(); // leftover 0.5 truncates to 0, no extra send
  assert.deepEqual(sent, [1]);
});

test('WheelAccumulator preserves sign (down = positive)', async () => {
  const sent = [];
  const acc = new WheelAccumulator((d) => sent.push(d), 20);
  acc.onWheel({ deltaY: -80, deltaMode: 0 });
  await sleep(40);
  assert.deepEqual(sent, [-2]);
  acc.dispose();
});
