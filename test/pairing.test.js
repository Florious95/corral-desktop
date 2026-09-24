import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import { DeviceManager } from '../src/core/devices.js';
import {
  buildPairingPayload, parsePairingPayload, reachableWsUrls, serializePairingPayload, wsUrlForHost,
} from '../src/core/pairing.js';
import { createQrMatrix } from '../src/lib/qr.js';

const POP = new URL('../src/components/chrome/DevicesPopover.jsx', import.meta.url);
const DIALOG = new URL('../src/components/chrome/PairingDialog.jsx', import.meta.url);
const APP = new URL('../src/App.jsx', import.meta.url);
const INDEX = new URL('../index.html', import.meta.url);

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

test('local zero-config pairing asks for a token, then persists it for QR handoff', () => {
  const dm = new DeviceManager({ storage: storage(), autoLocal: true });
  assert.equal(dm.createPairingPayload(), null);
  assert.deepEqual(dm.createPairingDraft(), {
    v: 1,
    url: 'ws://127.0.0.1:9900/ws',
    token: '',
    ts_authkey: '',
    candidates: ['ws://127.0.0.1:9900/ws'],
  });
  assert.equal(dm.savePairingToken('pair-token'), true);
  assert.equal(dm.createPairingPayload().token, 'pair-token');
});

test('loopback pairing target is rewritten to reachable hosts and candidates', () => {
  const base = 'ws://127.0.0.1:19990/ws';
  assert.equal(wsUrlForHost(base, '192.168.1.23'), 'ws://192.168.1.23:19990/ws');
  assert.equal(wsUrlForHost(base, '100.64.0.4'), 'ws://100.64.0.4:19990/ws');
  assert.equal(wsUrlForHost(base, 'ws://10.0.0.8:9900/ws'), 'ws://10.0.0.8:9900/ws');
  assert.equal(wsUrlForHost(base, '127.0.0.1'), 'ws://127.0.0.1:19990/ws');
  assert.deepEqual(reachableWsUrls(base, ['127.0.0.1', '192.168.1.23', '192.168.1.23', '100.64.0.4']), [
    'ws://192.168.1.23:19990/ws', 'ws://100.64.0.4:19990/ws',
  ]);
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
  assert.match(dialog, /移动端远程连接需要安全 Token/);
  assert.match(dialog, /type="password"/);
  assert.match(dialog, /onSaveToken/);
  assert.match(dialog, /本机可达地址（局域网 \/ Tailscale）/);
  assert.match(dialog, /reachableWsUrls/);
  assert.match(dialog, /Escape/);
  assert.match(dialog, /onClick=\{onCancel\}/);
  assert.match(app, /createPairingPayload\(\)/);
  assert.match(app, /<PairingDialog/);
});

test('index declares an empty data favicon so the browser makes no 404 request', async () => {
  const index = await readFile(INDEX, 'utf8');
  assert.match(index, /<link rel="icon" href="data:,"\s*\/>/);
});

test('#207 pairing payload builder and parser support host_id identity decoupling', () => {
  const hostPayload = buildPairingPayload({
    host_id: 'XM2Y6OKHNORVVDUXZI7K6TKVYE',
    token: 'pair-token-secret',
    port: 9900,
    name: 'MacBook-Pro.local',
  });
  assert.equal(hostPayload.v, 1);
  assert.equal(hostPayload.host_id, 'XM2Y6OKHNORVVDUXZI7K6TKVYE');
  assert.equal(hostPayload.token, 'pair-token-secret');
  assert.equal(hostPayload.port, 9900);
  assert.equal(hostPayload.name, 'MacBook-Pro.local');
  assert.equal(hostPayload.url, '');
  assert.deepEqual(hostPayload.candidates, []);

  // Serializes and parses back cleanly
  const raw = serializePairingPayload(hostPayload);
  const parsed = parsePairingPayload(raw);
  assert.deepEqual(parsed, hostPayload);
});

test('#207 buildPairingPayload rejects when neither valid ws URL nor host_id is provided', () => {
  assert.throws(
    () => buildPairingPayload({ token: 'pair-token' }),
    /pairing payload requires a valid host_id or ws:\/\/ URL/,
  );
  assert.throws(
    () => buildPairingPayload({ url: 'http://not-ws', token: 'pair-token' }),
    /pairing payload requires a valid host_id or ws:\/\/ URL/,
  );
  assert.throws(
    () => buildPairingPayload({ host_id: 'XM2Y6OKHNORVVDUXZI7K6TKVYE' }),
    /pairing token required/,
  );
});

test('#207 DeviceManager fetches local host identity from /pair/whoami and seeds pairing payload', async () => {
  const fakeWhoami = {
    v: 1,
    host_id: 'XM2Y6OKHNORVVDUXZI7K6TKVYE',
    name: 'MacBook-Pro.local',
    port: 9900,
    addresses: ['192.168.31.116'],
  };
  let requestedUrl = null;
  const mockFetch = async (url) => {
    requestedUrl = url;
    return {
      ok: true,
      json: async () => fakeWhoami,
    };
  };

  const dm = new DeviceManager({
    storage: storage(),
    autoLocal: true,
    fetchImpl: mockFetch,
    seedDevices: [{
      id: 'local',
      name: 'Local',
      url: 'ws://127.0.0.1:9900/ws',
      token: 'local-token-xyz',
    }],
  });

  const identity = await dm.fetchLocalHostIdentity();
  assert.equal(requestedUrl, 'http://127.0.0.1:9900/pair/whoami');
  assert.deepEqual(identity, {
    host_id: 'XM2Y6OKHNORVVDUXZI7K6TKVYE',
    name: 'MacBook-Pro.local',
    port: 9900,
  });

  const payload = dm.createPairingPayload();
  assert.equal(payload.host_id, 'XM2Y6OKHNORVVDUXZI7K6TKVYE');
  assert.equal(payload.name, 'MacBook-Pro.local');
  assert.equal(payload.port, 9900);
  assert.equal(payload.token, 'local-token-xyz');

  const draft = dm.createPairingDraft();
  assert.equal(draft.host_id, 'XM2Y6OKHNORVVDUXZI7K6TKVYE');
  assert.equal(draft.name, 'MacBook-Pro.local');
  assert.equal(draft.port, 9900);
});

test('#207 PairingDialog source code distinguishes host_id mode and removes manual IP for host_id payload', async () => {
  const dialog = await readFile(DIALOG, 'utf8');
  assert.match(dialog, /hasHostId\s*=\s*Boolean\(payload\?\.host_id\)/);
  assert.match(dialog, /showLegacyHostInput\s*=\s*loopback\s*&&\s*!hasHostId/);
  assert.match(dialog, /displayTarget/);
  assert.match(dialog, /主机 ID:/);
});
