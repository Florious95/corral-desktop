import test from 'node:test';
import assert from 'node:assert/strict';
import { safeRandomUUID } from '../src/lib/uuid.js';
import { DeviceManager } from '../src/core/devices.js';

const UUID_V4_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

test('safeRandomUUID generates compliant RFC4122 v4 UUID with native randomUUID', () => {
  const id = safeRandomUUID();
  assert.equal(typeof id, 'string');
  assert.equal(id.length, 36);
  assert.match(id, UUID_V4_REGEX);
});

test('safeRandomUUID gracefully falls back to getRandomValues when randomUUID is undefined (HTTP non-secure context)', () => {
  const mockCrypto = {
    getRandomValues: (buffer) => globalThis.crypto.getRandomValues(buffer),
  };
  const id = safeRandomUUID(mockCrypto);
  assert.equal(typeof id, 'string');
  assert.equal(id.length, 36);
  assert.match(id, UUID_V4_REGEX);
});

test('safeRandomUUID gracefully falls back to Math.random when crypto is completely absent', () => {
  const id = safeRandomUUID(null);
  assert.equal(typeof id, 'string');
  assert.equal(id.length, 36);
  assert.match(id, UUID_V4_REGEX);
});

test('DeviceManager.addDevice works in HTTP non-secure context without crypto.randomUUID', () => {
  const mockCrypto = {
    getRandomValues: (buffer) => globalThis.crypto.getRandomValues(buffer),
  };

  const dm = new DeviceManager({
    autoLocal: false,
    cryptoImpl: mockCrypto,
    storage: {
      getItem: () => null,
      setItem: () => {},
      removeItem: () => {},
    },
  });

  const devId = dm.addDevice({
    name: 'Remote-5090',
    url: 'ws://192.168.1.50:9900/ws',
    token: 'test-token',
  });

  assert.equal(typeof devId, 'string');
  assert.match(devId, UUID_V4_REGEX);
  assert.equal(dm.devices.some((d) => d.id === devId), true);
});
