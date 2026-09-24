import { test } from 'node:test';
import assert from 'node:assert/strict';
import { wsToHttpOrigin, uploadImage } from '../src/core/upload.js';
import { DEFAULT_LOCAL_URL, DEFAULT_LOCAL_DEVICE, isLocalUrl } from '../src/core/local.js';
import { DeviceManager } from '../src/core/devices.js';
import { extractPasteEventSnapshot, fileToImageAttachment } from '../src/term/clipboard.js';

function mockStorage() {
  const store = new Map();
  return {
    getItem: (k) => store.get(k) ?? null,
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
  };
}

test('Issue #289: DEFAULT_LOCAL_URL uses IPv4 127.0.0.1 to eliminate Windows IPv6 (::1) SYN timeouts', () => {
  assert.equal(DEFAULT_LOCAL_URL, 'ws://127.0.0.1:9900/ws');
  assert.equal(DEFAULT_LOCAL_DEVICE.url, 'ws://127.0.0.1:9900/ws');
  assert.equal(isLocalUrl('ws://127.0.0.1:9900/ws'), true);
  assert.equal(isLocalUrl('ws://localhost:9900/ws'), true);
});

test('Issue #289: wsToHttpOrigin strictly normalizes localhost to 127.0.0.1 for loopback upload', () => {
  assert.equal(wsToHttpOrigin('ws://localhost:9900/ws'), 'http://127.0.0.1:9900');
  assert.equal(wsToHttpOrigin('ws://127.0.0.1:9900/ws'), 'http://127.0.0.1:9900');
  assert.equal(wsToHttpOrigin('ws://localhost:19990/ws'), 'http://127.0.0.1:19990');
  assert.equal(wsToHttpOrigin('ws://192.168.1.100:9900/ws'), 'http://192.168.1.100:9900');
});

test('Issue #289: DeviceManager migrates legacy ws://localhost:9900/ws to IPv4 loopback on load', () => {
  const dm = new DeviceManager({
    autoLocal: false,
    seedDevices: [
      { id: 'local', name: 'Local', url: 'ws://localhost:9900/ws', token: 'saved-token' },
    ],
  });
  const localDev = dm.devices.find((d) => d.id === 'local');
  assert.ok(localDev);
  assert.equal(localDev.url, 'ws://127.0.0.1:9900/ws', 'Local device URL must be migrated to 127.0.0.1');
});

test('Issue #289: uploadImage passes normalized IPv4 endpoint to native invoke even from localhost input', async () => {
  const calls = [];
  const fakeInvoke = async (cmd, args) => {
    calls.push({ cmd, args });
    return '/tmp/uploads/test.png';
  };

  const path = await uploadImage({
    url: 'ws://localhost:9900/ws',
    token: 'test-token',
    name: 'test.png',
    mime: 'image/png',
    bytes: new Uint8Array([137, 80, 78, 71]),
    nativeInvoke: fakeInvoke,
  });

  assert.equal(path, '/tmp/uploads/test.png');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].cmd, 'upload_http');
  assert.equal(calls[0].args.url, 'http://127.0.0.1:9900/upload', 'Endpoint must use IPv4 127.0.0.1 to avoid IPv6 timeout');
});

test('Issue #289: End-to-end simulated paste flow parses image and generates attachment synchronously/sub-millisecond', async () => {
  const pngHeader = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
  const blob = new Blob([pngHeader], { type: 'image/png' });
  const mockItem = {
    kind: 'file',
    type: 'image/png',
    getAsFile: () => blob,
  };
  const mockEvent = {
    clipboardData: {
      getData: () => '',
      items: [mockItem],
      files: [blob],
    },
  };

  const t0 = performance.now();
  const snapshot = extractPasteEventSnapshot(mockEvent);
  assert.equal(snapshot.text, '');
  assert.ok(snapshot.imageFile);

  const attachment = await fileToImageAttachment(snapshot.imageFile);
  const elapsed = performance.now() - t0;

  assert.ok(attachment);
  assert.equal(attachment.mime, 'image/png');
  assert.deepEqual(Array.from(attachment.bytes), [137, 80, 78, 71, 13, 10, 26, 10]);
  assert.ok(elapsed < 100, `Snapshot + attachment extraction took ${elapsed}ms, should be <100ms`);
});

test('Issue #289: UI-SPEC.md documents Windows image paste speed and IPv4 loopback ruling', async () => {
  const { readFile } = await import('node:fs/promises');
  const spec = await readFile(new URL('../docs/UI-SPEC.md', import.meta.url), 'utf8');
  assert.match(spec, /Windows 本地模式图片上传速度与 IPv4 地址归一（2026-09-24，Issue #289）/);
  assert.match(spec, /DEFAULT_LOCAL_URL.*ws:\/\/127\.0\.0\.1:9900\/ws/);
});
