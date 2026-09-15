import { test } from 'node:test';
import assert from 'node:assert/strict';

import { Client } from '../src/core/client.js';
import { Client as CoreClient } from '../deps/corral-core/web/js/client.js';
import { DeviceManager } from '../src/core/devices.js';
import { decodeControl } from '../src/core/protocol.js';
import { DEFAULT_LOCAL_URL, isLocalUrl } from '../src/core/local.js';
import * as store from '../src/core/store.js';

class FakeWS {
  static OPEN = 1;
  constructor(url) {
    this.url = url;
    this.readyState = 0;
    this.sent = [];
    this.onopen = this.onmessage = this.onclose = this.onerror = null;
  }
  send(data) { this.sent.push(data); }
  close() {
    this.readyState = 3;
    this.onclose?.({ code: 1000, reason: 'close' });
  }
  open() {
    this.readyState = FakeWS.OPEN;
    this.onopen?.({});
  }
}

function storage() {
  const values = new Map();
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => values.set(key, String(value)),
    removeItem: (key) => values.delete(key),
  };
}

test('loopback Client skips auth only when no token is configured', () => {
  const sockets = [];
  const client = new Client({
    url: DEFAULT_LOCAL_URL,
    token: '',
    wsFactory: (url) => {
      const ws = new FakeWS(url);
      sockets.push(ws);
      return ws;
    },
  });
  assert.equal(client.token, '');
  client.subscribe('local-session', 24, 80);
  client.connect();
  sockets[0].open();

  assert.equal(client.state, 'ready');
  assert.deepEqual(sockets[0].sent.map((frame) => decodeControl(frame).type), ['list', 'subscribe']);
  assert.equal(sockets[0].sent.some((frame) => decodeControl(frame).type === 'auth'), false);
});

test('loopback Client uses configured token for auth before listing', () => {
  const sockets = [];
  const client = new Client({
    url: DEFAULT_LOCAL_URL,
    token: 'local-token',
    wsFactory: (url) => {
      const ws = new FakeWS(url);
      sockets.push(ws);
      return ws;
    },
  });
  client.connect();
  sockets[0].open();

  assert.equal(client.state, 'authenticating');
  assert.deepEqual(decodeControl(sockets[0].sent[0]), {
    type: 'auth', payload: { token: 'local-token' },
  });
  sockets[0].onmessage({ data: JSON.stringify({ v: 1, type: 'auth_ack', payload: { ok: true } }) });
  const list = decodeControl(sockets[0].sent[1]);
  assert.equal(list.type, 'list');
  assert.equal(Number.isInteger(list.payload.req_id), true);
  sockets[0].onmessage({ data: JSON.stringify({
    v: 1, type: 'listing', payload: {
      req_id: list.payload.req_id,
      seq: 1,
      workspaces: [{
        cwd: '/tmp/project', session_count: 1, aggregate_state: 'unknown',
        sessions: [{ ref: 's1', name: 'agent', cwd: '/tmp/project', rows: 24, cols: 80 }],
      }],
    },
  }) });

  assert.equal(client.state, 'ready');
  assert.equal(client.workspaces[0].sessions[0].name, 'agent');
});

test('DeviceManager authenticates a configured loopback and publishes its listing', () => {
  const sockets = [];
  const dm = new DeviceManager({
    storage: storage(),
    autoLocal: false,
    seedDevices: [{ id: 'local', name: 'Local', url: DEFAULT_LOCAL_URL, token: 'local-token' }],
    wsFactory: (url) => {
      const ws = new FakeWS(url);
      sockets.push(ws);
      return ws;
    },
  });
  dm.connectAll();
  sockets[0].open();
  assert.deepEqual(decodeControl(sockets[0].sent[0]), {
    type: 'auth', payload: { token: 'local-token' },
  });
  sockets[0].onmessage({ data: JSON.stringify({ v: 1, type: 'auth_ack', payload: { ok: true } }) });
  const list = decodeControl(sockets[0].sent[1]);
  assert.equal(list.type, 'list');
  sockets[0].onmessage({ data: JSON.stringify({
    v: 1, type: 'listing', payload: {
      req_id: list.payload.req_id,
      seq: 3,
      workspaces: [{
        cwd: '/Users/alauda', session_count: 2, aggregate_state: 'unknown',
        sessions: [
          { ref: 's1', name: 'agent-a', cwd: '/Users/alauda', rows: 24, cols: 80 },
          { ref: 's2', name: 'agent-b', cwd: '/Users/alauda', rows: 24, cols: 80 },
        ],
      }],
    },
  }) });

  assert.equal(dm.devices[0].state, 'ready');
  assert.equal(dm.workspaces[0].sessionCount, 2);
  assert.deepEqual(dm.workspaces[0].sessions.map((s) => s.name), ['agent-a', 'agent-b']);
});

test('local trust is instance-only and remote Client still requires a token', () => {
  assert.equal(Client.prototype.handleOpen, CoreClient.prototype.handleOpen);
  assert.throws(
    () => new Client({ url: 'ws://192.0.2.1:9900/ws', token: '' }),
    { message: 'Client: token required' },
  );
  assert.equal(isLocalUrl('ws://localhost:9900/ws'), true);
  assert.equal(isLocalUrl('ws://[::1]:9900/ws'), true);
  assert.equal(isLocalUrl('ws://192.0.2.1:9900/ws'), false);
});

test('production DeviceManager adds Local alongside configured remote devices', () => {
  const remote = { id: 'remote', name: 'Remote', url: 'ws://192.0.2.1:9900/ws', token: 'remote-token' };
  const dm = new DeviceManager({ storage: storage(), seedDevices: [remote], autoLocal: true });
  assert.deepEqual(dm.devices.map((device) => device.name), ['Remote', 'Local']);
  assert.ok(dm.devices.every((device) => !Object.hasOwn(device, 'token')));
});

test('storage accepts empty token only for loopback devices', () => {
  const s = storage();
  s.setItem(store.KEYS.devices, JSON.stringify([
    { id: 'local', name: 'Local', url: DEFAULT_LOCAL_URL, token: '' },
    { id: 'remote', name: 'Remote', url: 'ws://192.0.2.1:9900/ws', token: '' },
  ]));
  assert.deepEqual(store.loadDevices(s), [{
    id: 'local', name: 'Local', url: DEFAULT_LOCAL_URL, token: '',
  }]);
});

test('remote device with no token is rejected before opening a socket', () => {
  const sockets = [];
  const dm = new DeviceManager({
    storage: storage(),
    autoLocal: false,
    wsFactory: (url) => {
      const ws = new FakeWS(url);
      sockets.push(ws);
      return ws;
    },
  });
  const id = dm.addDevice({ name: 'Remote', url: 'ws://192.0.2.1:9900/ws', token: '' });
  dm.connectAll();

  const device = dm.devices.find((entry) => entry.id === id);
  assert.equal(device.state, 'stopped');
  assert.equal(device.lastError, 'token required');
  assert.equal(sockets.length, 0);
});
