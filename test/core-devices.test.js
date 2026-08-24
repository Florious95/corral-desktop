/*
 * DeviceManager against the mock daemon over a real WebSocket (node 22 global
 * WebSocket, no fake transport): auth → listing → aggregation → level2 →
 * binary routing → delta/seq recovery → drop & replay → auth rejection.
 *
 * Everything the client must survive is produced by scripts/mock-daemon.mjs,
 * which reproduces the live daemon's quirks (no status in listing, clamped
 * scrollback, silent resize no-op).
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { DeviceManager } from '../src/core/devices.js';
import * as store from '../src/core/store.js';
import { startMockDaemon, REFS, ADDED_SESSION } from '../scripts/mock-daemon.mjs';

function fakeStorage() {
  const m = new Map();
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => { m.set(k, String(v)); },
    removeItem: (k) => { m.delete(k); },
    _map: m,
  };
}

async function waitFor(fn, what, timeoutMs = 4000) {
  const t0 = Date.now();
  for (;;) {
    const v = fn();
    if (v) return v;
    if (Date.now() - t0 > timeoutMs) throw new Error(`timeout waiting for ${what}`);
    await new Promise((r) => setTimeout(r, 10));
  }
}

/** One daemon + one connected DeviceManager; extra devices are added per test. */
async function setup(opts = {}) {
  const daemon = startMockDaemon({ port: 0, level2Ms: 40, deltaMs: 10_000, ...opts.daemon });
  await daemon.ready;
  const storage = fakeStorage();
  const events = { binary: [], input: [], errors: [], models: 0, devices: 0 };
  const dm = new DeviceManager({
    storage,
    backoff: { baseMs: 20, maxMs: 40, factor: 1, jitter: 0 },
    modelDebounceMs: 20,
    onBinary: (e) => events.binary.push(e),
    onInputResult: (e) => events.input.push(e),
    onError: (e) => events.errors.push(e),
    onModelChange: () => { events.models++; },
    onDeviceChange: () => { events.devices++; },
    nativeInvoke: opts.nativeInvoke,
    fetchImpl: opts.fetchImpl,
  });
  const id = dm.addDevice({ name: 'A-mac', url: daemon.url, token: opts.token ?? 'mock-token' });
  dm.connectAll();
  return {
    daemon, dm, id, storage, events,
    async teardown() { dm.disconnectAll(); await daemon.close(); },
  };
}

test('auth → listing → aggregated model carries uid/spaceKey/device name', async () => {
  const t = await setup();
  try {
    const ws = await waitFor(() => (t.dm.workspaces.length === 2 ? t.dm.workspaces : null), 'listing');
    assert.deepEqual(ws.map((w) => w.label), ['a', 'b']);
    assert.deepEqual(ws.map((w) => w.cwd), ['/proj/a', '/proj/b']);
    assert.equal(ws[0].spaceKey, `${t.id}::/proj/a`);
    assert.equal(ws[0].sessionCount, 2);
    assert.equal(ws[0].deviceName, 'A-mac');

    const s = ws[0].sessions[0];
    assert.equal(s.uid, `${t.id}::${REFS.a1}`);
    assert.equal(s.ref, REFS.a1);
    assert.equal(s.provider, 'claude-code');        // inferred from name; listing has no provider
    assert.equal(s.status, 'unknown');              // never subscribed to level2 → not faked as idle
    assert.equal(s.title, '');
    assert.equal(ws[0].aggregateState, 'unknown');
    assert.equal(t.dm.agent(s.uid).ref, REFS.a1);
    assert.equal(t.dm.space(ws[1].spaceKey).cwd, '/proj/b');

    // Device projection: state visible, token never.
    const [dev] = t.dm.devices;
    assert.deepEqual(Object.keys(dev).sort(), ['checked', 'id', 'lastError', 'name', 'state', 'url']);
    assert.equal(dev.state, 'ready');
    assert.ok(t.events.models > 0 && t.events.devices > 0);
    // Tokens live in storage only, never in the published model.
    assert.ok(!JSON.stringify(t.dm.workspaces).includes('mock-token'));
  } finally { await t.teardown(); }
});

test('two devices union, colliding basenames disambiguate, uncheck filters without disconnecting', async () => {
  const t = await setup();
  const other = startMockDaemon({
    port: 0,
    workspaces: [{ cwd: '/other/a', session_count: 1, sessions: [
      { ref: REFS.b1, name: 'grok', cwd: '/other/a', title: '', rows: 24, cols: 80 }] }],
  });
  await other.ready;
  try {
    const id2 = t.dm.addDevice({ name: 'B-mac', url: other.url, token: 'mock-token' });
    t.dm.connectAll();
    const ws = await waitFor(() => (t.dm.workspaces.length === 3 ? t.dm.workspaces : null), 'both listings');

    // Sorted by device name then cwd; same basename on different devices grows a segment.
    assert.deepEqual(ws.map((w) => `${w.deviceName}:${w.label}`), ['A-mac:proj/a', 'A-mac:b', 'B-mac:other/a']);

    t.dm.setChecked(id2, false);
    assert.deepEqual(t.dm.workspaces.map((w) => w.label), ['a', 'b']); // collision gone → back to basename
    assert.equal(t.dm.isReady(id2), true, 'unchecking is a display filter, not a disconnect');
    assert.deepEqual(store.loadCheckedDevices(t.storage), [t.id]);

    t.dm.setChecked(id2, true);
    assert.equal(t.dm.workspaces.length, 3);
  } finally { await other.close(); await t.teardown(); }
});

test('list_delta applies; a seq gap triggers exactly one automatic re-list', async () => {
  const t = await setup();
  try {
    await waitFor(() => t.dm.workspaces.length === 2, 'listing');
    t.daemon.sendDelta({ added: [ADDED_SESSION], changedWorkspaces: [{ cwd: '/proj/b', session_count: 2 }] });
    const b = await waitFor(() => t.dm.workspaces.find((w) => w.cwd === '/proj/b' && w.sessions.length === 2), 'delta applied');
    assert.equal(b.sessionCount, 2);
    assert.ok(b.sessions.some((s) => s.uid === `${t.id}::${REFS.b2}` && s.provider === 'cursor'));

    const listsBefore = t.daemon.count('list');
    t.daemon.sendDelta({ gap: true, added: [] });
    await waitFor(() => t.daemon.count('list') > listsBefore, 're-list after seq gap');
    await new Promise((r) => setTimeout(r, 100));
    assert.equal(t.daemon.count('list'), listsBefore + 1, 'exactly one re-list — no double list');
    assert.equal(t.dm.workspaces.length, 2);
  } finally { await t.teardown(); }
});

test('level2 fills title/status/provider and drives the client-side aggregate', async () => {
  const t = await setup();
  try {
    await waitFor(() => t.dm.workspaces.length === 2, 'listing');
    const spaceKey = `${t.id}::/proj/a`;
    assert.equal(t.dm.subscribeLevel2(spaceKey), true);
    const a = await waitFor(() => {
      const w = t.dm.space(spaceKey);
      return w && w.aggregateState === 'working' ? w : null;
    }, 'level2 frame');
    assert.equal(a.sessions[0].title, '✳ Thinking…');
    assert.equal(a.sessions[0].status, 'working');
    assert.equal(a.sessions[0].provider, 'claude-code'); // claude_code normalised to the UI key
    assert.equal(a.sessions[1].status, 'idle');
    // Unsubscribed spaces stay unknown — never faked as idle.
    assert.equal(t.dm.space(`${t.id}::/proj/b`).aggregateState, 'unknown');

    // Re-subscribing the same cwd must not trigger another full scan.
    const subs = t.daemon.count('level2_subscribe');
    assert.equal(t.dm.subscribeLevel2(spaceKey), true);
    assert.equal(t.daemon.count('level2_subscribe'), subs);

    t.dm.unsubscribeLevel2(t.id);
    assert.equal(t.dm.space(spaceKey).aggregateState, 'unknown');
  } finally { await t.teardown(); }
});

test('subscribe routes binary frames with deviceId; input acks; resize no-op stays silent', async () => {
  const t = await setup();
  try {
    await waitFor(() => t.dm.workspaces.length === 2, 'listing');
    const uid = `${t.id}::${REFS.a1}`;
    assert.equal(t.dm.subscribe(uid, 40, 100), true);
    const snap = await waitFor(() => t.events.binary.find((e) => e.frame.kind === 1), 'snapshot');
    assert.equal(snap.deviceId, t.id);
    assert.equal(snap.uid, uid);
    assert.equal(snap.frame.ref, REFS.a1);
    assert.ok(snap.frame.data.length > 0);

    const sent = t.dm.input(uid, 'hello');
    assert.equal(sent.deviceId, t.id);
    const ack = await waitFor(() => t.events.input.find((e) => e.reqId === sent.reqId), 'input_ack');
    assert.equal(ack.ok, true);
    assert.equal(t.dm.keys(uid, 'backspace').deviceId, t.id); // 8-value key set incl. backspace

    // scrollback replies with the server's clamped range, not the requested one.
    const req = t.dm.scrollback(uid, -300, 100);
    const sb = await waitFor(() => t.events.binary.find((e) => e.frame.kind === 3), 'scrollback');
    assert.equal(sb.frame.reqId, req.reqId);
    assert.equal(sb.frame.fromLine, -100);
    assert.equal(sb.frame.lineCount, 50);

    const snaps = () => t.events.binary.filter((e) => e.frame.kind === 1).length;
    const before = snaps();
    t.dm.resize(uid, 40, 100);                 // same geometry → daemon answers nothing
    await new Promise((r) => setTimeout(r, 120));
    assert.equal(snaps(), before);
    t.dm.resize(uid, 30, 80);                  // real reflow → fresh snapshot
    await waitFor(() => snaps() > before, 'snapshot after real resize');

    t.dm.unsubscribe(uid);
    assert.equal(t.dm.input(`${t.id}::nope`, 'x') !== null, true); // unknown ref still routes to the device
  } finally { await t.teardown(); }
});

test('uploadAndAttach: one native upload then one attachment_path frame', async () => {
  const calls = [];
  const t = await setup({ nativeInvoke: async (name, args) => {
    calls.push([name, args]);
    return '/host/uploads/test.png';
  } });
  try {
    await waitFor(() => t.dm.workspaces.length === 2, 'listing');
    const uid = `${t.id}::${REFS.a1}`;
    t.dm.subscribe(uid, 40, 100);
    await waitFor(() => t.events.binary.some((e) => e.frame.kind === 1), 'snapshot');
    const sent = await t.dm.uploadAndAttach(uid, { name: 'test.png', mime: 'image/png', bytes: new Uint8Array([1, 2, 3]) });
    await waitFor(() => t.events.input.find((e) => e.reqId === sent.reqId), 'attachment input_ack');
    assert.equal(calls.length, 1);
    assert.equal(calls[0][0], 'upload_http');
    const frame = t.daemon.received.find((f) => f.type === 'input' && f.payload.req_id === sent.reqId);
    assert.equal(frame.payload.attachment_path, '/host/uploads/test.png');
    assert.equal(frame.payload.text, undefined);
    assert.equal(JSON.stringify(frame.payload).includes('/host/uploads/test.png'), true);
  } finally { await t.teardown(); }
});

test('socket drop → re-auth, subscription and level2 replay', async () => {
  const t = await setup();
  try {
    await waitFor(() => t.dm.workspaces.length === 2, 'listing');
    const uid = `${t.id}::${REFS.a1}`;
    t.dm.subscribe(uid, 40, 100);
    t.dm.subscribeLevel2(`${t.id}::/proj/a`);
    await waitFor(() => t.daemon.count('level2_subscribe') === 1, 'first level2_subscribe');

    const before = { auth: t.daemon.count('auth'), sub: t.daemon.count('subscribe'), lvl: t.daemon.count('level2_subscribe') };
    t.daemon.dropAll();
    await waitFor(() => t.daemon.count('auth') > before.auth, 're-auth');
    await waitFor(() => t.daemon.count('subscribe') > before.sub, 'subscription replay');
    await waitFor(() => t.daemon.count('level2_subscribe') > before.lvl, 'level2 replay');

    const replay = t.daemon.received.filter((f) => f.type === 'subscribe').at(-1);
    assert.deepEqual(replay.payload, { ref: REFS.a1, rows: 40, cols: 100 }, 'replay keeps the original geometry');
    await waitFor(() => t.dm.isReady(t.id), 'ready again');
    await waitFor(() => t.dm.workspaces.length === 2, 'listing after reconnect');
  } finally { await t.teardown(); }
});

test('bad token stops permanently with a token-free error message', async () => {
  const t = await setup({ token: 'wrong-token' });
  try {
    const dev = await waitFor(() => {
      const d = t.dm.devices[0];
      return d.state === 'stopped' && d.lastError ? d : null;
    }, 'permanent stop');
    assert.match(dev.lastError, /token/);
    assert.ok(!dev.lastError.includes('wrong-token'));
    await new Promise((r) => setTimeout(r, 150));
    assert.equal(t.daemon.count('auth'), 1, 'no reconnect loop on a rejected token');
    assert.equal(t.dm.isReady(t.id), false);
  } finally { await t.teardown(); }
});

test('storage: devices persist, corrupt data falls back, removeDevice forgets favourites and panes', async () => {
  const t = await setup();
  try {
    await waitFor(() => t.dm.workspaces.length === 2, 'listing');
    assert.deepEqual(store.loadDevices(t.storage).map((d) => d.name), ['A-mac']);
    assert.equal(store.loadDevices(t.storage)[0].token, 'mock-token');

    store.saveFavorites([store.favKey(t.id, '/proj/a', 'claude'), 'other-device::/x::y'], t.storage);
    store.saveUi({ ...store.DEFAULT_UI, panes: [`${t.id}::${REFS.a1}`], activePane: `${t.id}::${REFS.a1}` }, t.storage);

    t.dm.removeDevice(t.id);
    assert.deepEqual(store.loadFavorites(t.storage), ['other-device::/x::y']);
    assert.deepEqual(store.loadUi(t.storage).panes, []);
    assert.equal(store.loadUi(t.storage).activePane, null);
    assert.deepEqual(store.loadDevices(t.storage), []);
    assert.deepEqual(t.dm.workspaces, []);

    // Corrupt / partial data must not throw and must not be half-restored.
    const bad = fakeStorage();
    bad.setItem(store.KEYS.devices, '{not json');
    bad.setItem(store.KEYS.ui, 'null');
    assert.deepEqual(store.loadDevices(bad), []);
    assert.deepEqual(store.loadUi(bad), store.DEFAULT_UI);
    bad.setItem(store.KEYS.devices, JSON.stringify([{ id: 'x', name: 'n', url: 'ws://h/ws' }]));
    assert.deepEqual(store.loadDevices(bad), [], 'a device without a token is dropped whole');
  } finally { await t.teardown(); }
});
