import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import { DeviceManager } from '../src/core/devices.js';
import {
  buildPairingPayload, parsePairingPayload, serializePairingPayload,
} from '../src/core/pairing.js';
import { createQrMatrix } from '../src/lib/qr.js';

const POP = new URL('../src/components/chrome/DevicesPopover.jsx', import.meta.url);
const DIALOG = new URL('../src/components/chrome/PairingDialog.jsx', import.meta.url);
const APP = new URL('../src/App.jsx', import.meta.url);

function storage() {
  const values = new Map();
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: (key) => values.delete(key),
  };
}

test('pairing encoder emits the v1 wire shape and primary candidate first', () => {
  const payload = buildPairingPayload({
    url: 'ws://192.0.2.10:9900/ws',
    token: 'pair-token',
    ts_authkey: '',
    candidates: ['not-ws', 'ws://10.0.0.2:9900/ws', 'ws://192.0.2.10:9900/ws'],
  });
  assert.deepEqual(payload, {
    v: 1,
    url: 'ws://192.0.2.10:9900/ws',
    token: 'pair-token',
    ts_authkey: '',
    candidates: ['ws://192.0.2.10:9900/ws', 'ws://10.0.0.2:9900/ws'],
  });
  assert.deepEqual(JSON.parse(serializePairingPayload(payload)), payload);
});

test('pairing parser is strict about v1 primary fields and tolerant of bad candidates', () => {
  const parsed = parsePairingPayload(JSON.stringify({
    v: 1,
    url: 'wss://host.example/ws',
    token: 'pair-token',
    candidates: ['ws://lan.example/ws', '', 'https://wrong.example/ws', 7],
    ignored: 'forward-compatible',
  }));
  assert.deepEqual(parsed, {
    v: 1,
    url: 'wss://host.example/ws',
    token: 'pair-token',
    ts_authkey: '',
    candidates: ['wss://host.example/ws', 'ws://lan.example/ws'],
  });
  assert.equal(parsePairingPayload(JSON.stringify({ v: 2, url: 'ws://host/ws', token: 'pair-token' })), null);
  assert.equal(parsePairingPayload(JSON.stringify({ v: 1, url: 'ws://host/ws' })), null);
  assert.equal(parsePairingPayload(JSON.stringify({ v: 1, url: 'https://host/ws', token: 'pair-token' })), null);
});

test('DeviceManager exposes pairing material only through explicit QR handoff', () => {
  const dm = new DeviceManager({
    storage: storage(),
    autoLocal: true,
    seedDevices: [{
      id: 'remote', name: 'Remote', url: 'ws://192.0.2.10:9900/ws', token: 'pair-token',
    }],
  });
  assert.deepEqual(dm.createPairingPayload(), {
    v: 1,
    url: 'ws://192.0.2.10:9900/ws',
    token: 'pair-token',
    ts_authkey: '',
    candidates: ['ws://192.0.2.10:9900/ws'],
  });
  assert.ok(dm.devices.every((device) => !Object.hasOwn(device, 'token')));
});

test('QR renderer returns a non-empty square matrix for the serialized payload', () => {
  const value = serializePairingPayload({ url: 'ws://host/ws', token: 'pair-token' });
  const matrix = createQrMatrix(value);
  assert.ok(matrix.size >= 21);
  assert.equal(matrix.modules.length, matrix.size);
  assert.ok(matrix.modules.every((row) => row.length === matrix.size));
  assert.ok(matrix.modules.some((row) => row.some(Boolean)));
});

test('pairing entry, modal actions, and close wiring are present in the UI', async () => {
  const [popover, dialog, app] = await Promise.all([
    readFile(POP, 'utf8'), readFile(DIALOG, 'utf8'), readFile(APP, 'utf8'),
  ]);
  assert.match(popover, /配对移动端/);
  assert.match(dialog, /复制配对链接 \/ Token/);
  assert.match(dialog, /Escape/);
  assert.match(dialog, /onClick=\{onCancel\}/);
  assert.match(app, /createPairingPayload\(\)/);
  assert.match(app, /<PairingDialog/);
});
