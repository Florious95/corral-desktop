import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  nativeCapabilities,
  detectNativeEnvironment,
  setNativeEngineForTests,
  resetNativeEngineForTests,
  uint8ArrayToBase64,
  base64ToUint8Array,
} from '../src/core/nativeCapabilities.js';

test('uint8ArrayToBase64 and base64ToUint8Array round-trip correctly', () => {
  assert.equal(uint8ArrayToBase64(new Uint8Array(0)), '');
  assert.deepEqual(base64ToUint8Array(''), new Uint8Array(0));

  const sample = new Uint8Array([0, 1, 2, 255, 254, 128, 64, 32]);
  const b64 = uint8ArrayToBase64(sample);
  assert.ok(typeof b64 === 'string' && b64.length > 0);
  const recovered = base64ToUint8Array(b64);
  assert.deepEqual(recovered, sample);
});

test('detectNativeEnvironment identifies swift, tauri, and mock', () => {
  const originalWindow = globalThis.window;

  delete globalThis.window;
  assert.equal(detectNativeEnvironment(), 'mock');

  globalThis.window = { __TAURI_INTERNALS__: {} };
  assert.equal(detectNativeEnvironment(), 'tauri');

  globalThis.window = {
    webkit: {
      messageHandlers: {
        native: { postMessage: () => {} },
      },
    },
  };
  assert.equal(detectNativeEnvironment(), 'swift');

  if (originalWindow !== undefined) {
    globalThis.window = originalWindow;
  } else {
    delete globalThis.window;
  }
});

test('secureStore strictly enforces devices schema whitelist and rejects other keys', async () => {
  resetNativeEngineForTests();

  // Test with mock engine
  await assert.rejects(
    nativeCapabilities.secureStore.get('passwords'),
    /secureStore: key must be 'devices'/,
  );
  await assert.rejects(
    nativeCapabilities.secureStore.get('randomKey'),
    /secureStore: key must be 'devices'/,
  );
  await assert.rejects(
    nativeCapabilities.secureStore.set('tokens', { secret: '123' }),
    /secureStore: key must be 'devices'/,
  );

  // 'devices' key works cleanly
  const testDevices = [{ id: 'd1', name: 'MacBook', url: 'ws://127.0.0.1:9900/ws', token: 'tok-1' }];
  const setResult = await nativeCapabilities.secureStore.set('devices', testDevices);
  assert.equal(setResult, true);

  const getResult = await nativeCapabilities.secureStore.get('devices');
  assert.deepEqual(getResult, testDevices);

  resetNativeEngineForTests();
});

test('Swift RPC dispatch handles modern Promise replies (WKScriptMessageHandlerWithReply)', async () => {
  const originalWindow = globalThis.window;
  const calls = [];

  globalThis.window = {
    webkit: {
      messageHandlers: {
        native: {
          postMessage: async (envelope) => {
            calls.push(envelope);
            if (envelope.method === 'window.minimize') {
              return { ok: true, result: null };
            }
            if (envelope.method === 'clipboard.readText') {
              return { ok: true, result: 'pasted text from swift' };
            }
            if (envelope.method === 'clipboard.readImage') {
              return {
                ok: true,
                result: {
                  name: 'screen.png',
                  mime: 'image/png',
                  bytesBase64: uint8ArrayToBase64(new Uint8Array([137, 80, 78, 71])),
                },
              };
            }
            if (envelope.method === 'upload.http') {
              return { ok: true, result: '/tmp/uploaded.png' };
            }
            if (envelope.method === 'secureStore.get') {
              return { ok: true, result: [{ id: 'swift-dev', name: 'Swift Device' }] };
            }
            return { ok: false, error: { message: `Unknown method ${envelope.method}` } };
          },
        },
      },
    },
  };

  assert.equal(nativeCapabilities.environment, 'swift');

  await nativeCapabilities.window.minimize();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, 'window.minimize');
  assert.equal(calls[0].v, 1);

  const text = await nativeCapabilities.clipboard.readText();
  assert.equal(text, 'pasted text from swift');

  const img = await nativeCapabilities.clipboard.readImage();
  assert.ok(img);
  assert.equal(img.name, 'screen.png');
  assert.equal(img.mime, 'image/png');
  assert.deepEqual(Array.from(img.bytes), [137, 80, 78, 71]);

  const uploadPath = await nativeCapabilities.upload.uploadHttp({
    url: 'http://127.0.0.1:9900/upload',
    token: 'tok-xyz',
    filename: 'test.png',
    bytes: new Uint8Array([1, 2, 3]),
  });
  assert.equal(uploadPath, '/tmp/uploaded.png');

  const devices = await nativeCapabilities.secureStore.get('devices');
  assert.deepEqual(devices, [{ id: 'swift-dev', name: 'Swift Device' }]);

  if (originalWindow !== undefined) {
    globalThis.window = originalWindow;
  } else {
    delete globalThis.window;
  }
});

test('Swift RPC dispatch handles legacy window.__nativeCallback asynchronous resolution', async () => {
  const originalWindow = globalThis.window;
  const calls = [];

  globalThis.window = {
    webkit: {
      messageHandlers: {
        native: {
          postMessage: (envelope) => {
            calls.push(envelope);
            // Simulate asynchronous callback from Swift
            setTimeout(() => {
              if (envelope.method === 'window.toggleFullscreen') {
                globalThis.window.__nativeCallback(envelope.id, true, null);
              } else if (envelope.method === 'window.close') {
                globalThis.window.__nativeCallback(envelope.id, null, 'Permission denied');
              }
            }, 10);
            return undefined; // legacy non-reply handler
          },
        },
      },
    },
  };

  assert.equal(nativeCapabilities.environment, 'swift');

  await nativeCapabilities.window.toggleFullscreen();
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, 'window.toggleFullscreen');

  await assert.rejects(
    nativeCapabilities.window.close(),
    /Permission denied/,
  );

  if (originalWindow !== undefined) {
    globalThis.window = originalWindow;
  } else {
    delete globalThis.window;
  }
});

test('setNativeEngineForTests allows comprehensive mocking for testing and fallback', async () => {
  const calls = [];
  setNativeEngineForTests({
    environment: 'test-env',
    window: {
      startDragging: async () => { calls.push('startDragging'); },
      close: async () => { calls.push('close'); },
    },
    clipboard: {
      readFiles: async () => ['/path/one.txt', '/path/two.txt'],
    },
    upload: {
      uploadHttp: async (args) => {
        calls.push(['uploadHttp', args.filename]);
        return `/remote/${args.filename}`;
      },
    },
  });

  assert.equal(nativeCapabilities.environment, 'test-env');

  await nativeCapabilities.window.startDragging();
  await nativeCapabilities.window.close();
  assert.deepEqual(calls, ['startDragging', 'close']);

  const files = await nativeCapabilities.clipboard.readFiles();
  assert.deepEqual(files, ['/path/one.txt', '/path/two.txt']);

  const uploaded = await nativeCapabilities.upload.uploadHttp({ filename: 'diagram.png', bytes: new Uint8Array([1]) });
  assert.equal(uploaded, '/remote/diagram.png');

  resetNativeEngineForTests();
  assert.equal(nativeCapabilities.environment, 'mock');
});
