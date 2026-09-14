import { test } from 'node:test';
import assert from 'node:assert/strict';

import { DeviceManager } from '../src/core/devices.js';
import {
  DEFAULT_UI,
  KEYS,
  createLatestWinsQueue,
  flushSecureSaves,
  loadDevicesSecure,
  saveCheckedDevices,
  saveDevices,
  setSecureStoreForTests,
} from '../src/core/store.js';

function fakeStorage() {
  const values = new Map();
  const writes = [];
  return {
    getItem(key) { return values.has(key) ? values.get(key) : null; },
    setItem(key, value) { writes.push(key); values.set(key, String(value)); },
    removeItem(key) { values.delete(key); },
    writes,
  };
}

function device(n) {
  return { id: `d${n}`, name: `Device ${n}`, url: `ws://device-${n}/ws`, token: `token-${n}` };
}

function secureBackend(initial = null) {
  const trace = [];
  let value = initial;
  let release;
  let firstSave = true;
  let active = 0;
  let maxActive = 0;
  const gate = new Promise((resolve) => { release = resolve; });
  const store = {
    async get(key) {
      assert.equal(key, 'devices');
      return value;
    },
    async set(key, next) {
      assert.equal(key, 'devices');
      active += 1;
      maxActive = Math.max(maxActive, active);
      trace.push(['set', next]);
      value = JSON.parse(JSON.stringify(next));
    },
    async save() {
      trace.push(['save']);
      if (firstSave) {
        firstSave = false;
        await gate;
      }
    },
    async lock() {
      trace.push(['lock']);
      active -= 1;
    },
  };
  return { store, trace, release, get value() { return value; }, get maxActive() { return maxActive; } };
}

test('secure save primes from hydrated content and skips equal serialized payloads', async () => {
  const initial = [device(0)];
  const backend = secureBackend(initial);
  globalThis.window = { __TAURI_INTERNALS__: {} };
  setSecureStoreForTests({ load: async () => backend.store, lock: () => backend.store.lock() });
  try {
    assert.deepEqual(await loadDevicesSecure(), initial);
    saveDevices(initial);
    await flushSecureSaves();
    assert.deepEqual(backend.trace, []);

    const changed = [{ ...initial[0], name: 'Changed' }];
    saveDevices(changed);
    backend.release();
    await flushSecureSaves();
    assert.deepEqual(backend.value, changed);
    assert.deepEqual(backend.trace.map(([kind]) => kind), ['set', 'save', 'lock']);

    const writes = backend.trace.length;
    saveDevices([{ ...changed[0] }]);
    await flushSecureSaves();
    assert.equal(backend.trace.length, writes);
  } finally {
    setSecureStoreForTests(null);
    delete globalThis.window;
  }
});

test('secure saves are latest-wins and never overlap set/save/lock transactions', async () => {
  const backend = secureBackend();
  globalThis.window = { __TAURI_INTERNALS__: {} };
  setSecureStoreForTests({ load: async () => backend.store, lock: () => backend.store.lock() });
  try {
    const first = [device(0)];
    saveDevices(first);
    while (!backend.trace.some(([kind]) => kind === 'save')) await new Promise((r) => setTimeout(r, 0));
    for (let n = 1; n <= 10; n += 1) saveDevices([device(n)]);
    backend.release();
    await flushSecureSaves();

    assert.deepEqual(backend.value, [device(10)]);
    assert.equal(backend.trace.filter(([kind]) => kind === 'save').length, 2);
    assert.equal(backend.maxActive, 1);
    for (let i = 0; i < backend.trace.length; i += 3) {
      assert.deepEqual(backend.trace.slice(i, i + 3).map(([kind]) => kind), ['set', 'save', 'lock']);
    }
  } finally {
    setSecureStoreForTests(null);
    delete globalThis.window;
  }
});

test('browser storage writes are idempotent after normalization', () => {
  const storage = fakeStorage();
  const devices = [device(0)];
  assert.equal(saveDevices(devices, storage), true);
  assert.equal(saveDevices([{ ...devices[0], runtimeOnly: true }], storage), true);
  assert.equal(storage.writes.filter((key) => key === KEYS.devices).length, 1);

  assert.equal(saveCheckedDevices(['d0'], storage), true);
  assert.equal(saveCheckedDevices(['d0'], storage), true);
  assert.equal(storage.writes.filter((key) => key === KEYS.checkedDevices).length, 1);
});

test('DeviceManager skips unchanged updates and removes checked state in one write', () => {
  const storage = fakeStorage();
  const dm = new DeviceManager({ storage, seedDevices: [device(0)] });
  const id = 'd0';
  assert.equal(dm.updateDevice(id, {}), true);
  assert.equal(dm.updateDevice(id, { name: 'Device 0' }), true);
  assert.equal(storage.writes.length, 0);

  storage.setItem(KEYS.checkedDevices, JSON.stringify([id]));
  storage.setItem(KEYS.favorites, JSON.stringify([`${id}::/cwd::session`]));
  storage.setItem(KEYS.ui, JSON.stringify({ ...DEFAULT_UI, panes: [`${id}::ref`], activePane: `${id}::ref` }));
  storage.writes.length = 0;
  assert.equal(dm.removeDevice(id), true);
  assert.equal(storage.writes.filter((key) => key === KEYS.devices).length, 1);
  assert.equal(storage.writes.filter((key) => key === KEYS.checkedDevices).length, 1);

  const freshStorage = fakeStorage();
  const freshDm = new DeviceManager({ storage: freshStorage, seedDevices: [device(0), device(1)] });
  assert.equal(freshDm.removeDevice('d0'), true);
  assert.deepEqual(JSON.parse(freshStorage.getItem(KEYS.checkedDevices)), ['d1']);
});

test('generic latest-wins queue retries after a failed write on a later request', async () => {
  const values = [];
  let fail = true;
  const queue = createLatestWinsQueue(async (value) => {
    if (fail) {
      fail = false;
      throw new Error('temporary failure');
    }
    values.push(value);
  });
  queue.enqueue({ n: 1 });
  await queue.idle();
  assert.deepEqual(values, []);
  queue.enqueue({ n: 1 });
  await queue.idle();
  assert.deepEqual(values, [{ n: 1 }]);
});
