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

test('mock daemon: input on one uid does not leak scroll_wheel onto the other', async () => {
  const { startMockDaemon, REFS } = await import('../scripts/mock-daemon.mjs');
  const { DeviceManager } = await import('../src/core/devices.js');
  const daemon = startMockDaemon({ port: 0, deltaMs: 10_000, level2Ms: 40 });
  await daemon.ready;
  const storage = {
    _m: new Map(),
    getItem(k) { return this._m.has(k) ? this._m.get(k) : null; },
    setItem(k, v) { this._m.set(k, String(v)); },
    removeItem(k) { this._m.delete(k); },
  };
  const dm = new DeviceManager({
    storage,
    backoff: { baseMs: 20, maxMs: 40, factor: 1, jitter: 0 },
    modelDebounceMs: 20,
  });
  const id = dm.addDevice({ name: 'Local', url: daemon.url, token: 'mock-token' });
  dm.connectAll();
  const t0 = Date.now();
  while (dm.workspaces.length < 1) {
    if (Date.now() - t0 > 4000) throw new Error('listing timeout');
    await sleep(10);
  }
  const uidA = `${id}::${REFS.a1}`;
  const uidB = `${id}::${REFS.a2}`;
  assert.equal(dm.subscribe(uidA, 24, 80), true);
  assert.equal(dm.subscribe(uidB, 24, 80), true);
  await sleep(50);
  daemon.hub.received.length = 0;
  const sent = dm.input(uidA, 'hello-col-a');
  assert.ok(sent);
  assert.equal(dm.scrollWheel(uidB, -3), true);
  await sleep(80);
  const inputs = daemon.received.filter((f) => f.type === 'input');
  const wheels = daemon.received.filter((f) => f.type === 'scroll_wheel');
  assert.equal(inputs.length, 1);
  assert.equal(inputs[0].payload.ref, REFS.a1);
  assert.equal(inputs[0].payload.text, 'hello-col-a');
  assert.equal(wheels.length, 1);
  assert.equal(wheels[0].payload.ref, REFS.a2);
  assert.equal(wheels[0].payload.delta, -3);
  dm.disconnectAll();
  await daemon.close();
});
