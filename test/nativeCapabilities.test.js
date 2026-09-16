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

test('Swift RPC dispatch performs bootstrap, attaches epoch, and calls canonical service methods', async () => {
  resetNativeEngineForTests();
  const originalWindow = globalThis.window;
  const calls = [];

  try {
    globalThis.window = {
      webkit: {
        messageHandlers: {
          native: {
            postMessage: async (envelope) => {
              calls.push(envelope);
              const base = { v: 1, id: envelope.id, epoch: 'swift-epoch-001', ok: true };
              if (envelope.method === 'bootstrap') {
                return {
                  ...base,
                  result: {
                    epoch: 'swift-epoch-001',
                    window: { geometryGeneration: 1 },
                  },
                };
              }
              if (envelope.method === 'window.minimize') {
                return { ...base, result: null };
              }
              if (envelope.method === 'clipboard.readText') {
                return { ...base, result: 'pasted text from swift' };
              }
              if (envelope.method === 'clipboard.image') {
                return {
                  ...base,
                  result: {
                    name: 'screen.png',
                    mime: 'image/png',
                    bytesBase64: uint8ArrayToBase64(new Uint8Array([137, 80, 78, 71])),
                  },
                };
              }
              if (envelope.method === 'clipboard.files') {
                return { ...base, result: ['/tmp/one.txt'] };
              }
              if (envelope.method === 'upload') {
                return { ...base, result: '/tmp/uploaded.png' };
              }
              if (envelope.method === 'devices.load') {
                return { ...base, result: [{ id: 'swift-dev', name: 'Swift Device' }] };
              }
              if (envelope.method === 'devices.save') {
                return { ...base, result: { saved: true } };
              }
              return { v: 1, id: envelope.id, epoch: 'swift-epoch-001', ok: false, error: { message: `Unknown method ${envelope.method}` } };
            },
          },
        },
      },
    };

    assert.equal(nativeCapabilities.environment, 'swift');

    // Trigger first operation - must auto-bootstrap
    await nativeCapabilities.window.minimize();

    // Call 0: bootstrap
    assert.equal(calls[0].method, 'bootstrap');
    assert.equal(calls[0].v, 1);

    // Call 1: window.minimize with epoch
    assert.equal(calls[1].method, 'window.minimize');
    assert.equal(calls[1].epoch, 'swift-epoch-001');

    const text = await nativeCapabilities.clipboard.readText();
    assert.equal(text, 'pasted text from swift');

    const img = await nativeCapabilities.clipboard.readImage();
    assert.ok(img);
    assert.equal(img.name, 'screen.png');
    assert.equal(img.mime, 'image/png');
    assert.deepEqual(Array.from(img.bytes), [137, 80, 78, 71]);

    const files = await nativeCapabilities.clipboard.readFiles();
    assert.deepEqual(files, ['/tmp/one.txt']);

    const uploadPath = await nativeCapabilities.upload.uploadHttp({
      url: 'http://127.0.0.1:9900/upload',
      token: 'tok-xyz',
      filename: 'test.png',
      bytes: new Uint8Array([1, 2, 3]),
    });
    assert.equal(uploadPath, '/tmp/uploaded.png');

    const devices = await nativeCapabilities.secureStore.get('devices');
    assert.deepEqual(devices, [{ id: 'swift-dev', name: 'Swift Device' }]);

    await nativeCapabilities.secureStore.set('devices', devices);

    const methodsCalled = calls.map((c) => c.method);
    assert.deepEqual(methodsCalled, [
      'bootstrap',
      'window.minimize',
      'clipboard.readText',
      'clipboard.image',
      'clipboard.files',
      'upload',
      'devices.load',
      'devices.save',
    ]);

    // All service calls must carry epoch
    for (let i = 1; i < calls.length; i++) {
      assert.equal(calls[i].epoch, 'swift-epoch-001');
    }
  } finally {
    if (originalWindow !== undefined) {
      globalThis.window = originalWindow;
    } else {
      delete globalThis.window;
    }
    resetNativeEngineForTests();
  }
});

test('Swift RPC dispatch handles legacy window.__nativeCallback asynchronous resolution', async () => {
  resetNativeEngineForTests();
  const originalWindow = globalThis.window;
  const calls = [];

  try {
    globalThis.window = {
      webkit: {
        messageHandlers: {
          native: {
            postMessage: (envelope) => {
              calls.push(envelope);
              // Simulate asynchronous callback from Swift
              setTimeout(() => {
                if (envelope.method === 'bootstrap') {
                  globalThis.window.__nativeCallback(envelope.id, { epoch: 'legacy-epoch-002' }, null);
                } else if (envelope.method === 'window.toggleFullscreen') {
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
    assert.equal(calls[0].method, 'bootstrap');
    assert.equal(calls[1].method, 'window.toggleFullscreen');
    assert.equal(calls[1].epoch, 'legacy-epoch-002');

    await assert.rejects(
      nativeCapabilities.window.close(),
      /Permission denied/,
    );
  } finally {
    if (originalWindow !== undefined) {
      globalThis.window = originalWindow;
    } else {
      delete globalThis.window;
    }
    resetNativeEngineForTests();
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

test('uploadHttp rejects when bytes/body is missing or empty', async () => {
  resetNativeEngineForTests();
  await assert.rejects(
    nativeCapabilities.upload.uploadHttp({ url: 'http://localhost/upload' }),
    /invalid_file: empty upload bytes/,
  );
  await assert.rejects(
    nativeCapabilities.upload.uploadHttp({ url: 'http://localhost/upload', bytes: new Uint8Array(0) }),
    /invalid_file: empty upload bytes/,
  );
  await assert.rejects(
    nativeCapabilities.upload.uploadHttp({ url: 'http://localhost/upload', body: [] }),
    /invalid_file: empty upload bytes/,
  );
});

test('uploadHttp accepts body alias and correctly uploads via Web fetch fallback', async () => {
  resetNativeEngineForTests();
  const originalFetch = globalThis.fetch;
  let fetchCall = null;

  globalThis.fetch = async (url, options) => {
    fetchCall = { url, options };
    return {
      ok: true,
      status: 200,
      json: async () => ({ path: '/server/stored/avatar.png' }),
    };
  };

  // Test body alias with byte array
  const pathWithBody = await nativeCapabilities.upload.uploadHttp({
    url: 'http://127.0.0.1:9900/upload',
    token: 'auth-token-1',
    filename: 'avatar.png',
    mime: 'image/png',
    body: [137, 80, 78, 71],
  });

  assert.equal(pathWithBody, '/server/stored/avatar.png');
  assert.equal(fetchCall.url, 'http://127.0.0.1:9900/upload');
  assert.equal(fetchCall.options.headers.Authorization, 'Bearer auth-token-1');
  assert.ok(fetchCall.options.body instanceof FormData);

  // Test Web fetch error handling
  globalThis.fetch = async () => ({
    ok: false,
    status: 401,
    json: async () => ({ error: 'Unauthorized' }),
  });

  await assert.rejects(
    nativeCapabilities.upload.uploadHttp({
      url: 'http://127.0.0.1:9900/upload',
      bytes: new Uint8Array([1, 2, 3]),
    }),
    /HTTP 401/,
  );

  globalThis.fetch = originalFetch;
});

test('toggleFullscreen and setFullscreen safely catch DOM fullscreen rejections without throwing', async () => {
  resetNativeEngineForTests();
  const originalDocument = globalThis.document;

  // Mock document rejecting requestFullscreen with "TypeError: not granted" (e.g. Headless Chrome without user gesture)
  globalThis.document = {
    fullscreenElement: null,
    documentElement: {
      requestFullscreen: async () => {
        throw new TypeError('not granted');
      },
    },
    exitFullscreen: async () => {
      throw new Error('exit failure');
    },
  };

  // Must not reject, returns false gracefully
  const toggleResult = await nativeCapabilities.window.toggleFullscreen();
  assert.equal(toggleResult, false);

  const setResult = await nativeCapabilities.window.setFullscreen(true);
  assert.equal(setResult, false);

  // When exiting fullscreen and exitFullscreen rejects
  globalThis.document.fullscreenElement = {};
  const toggleExit = await nativeCapabilities.window.toggleFullscreen();
  assert.equal(toggleExit, false);

  const setExit = await nativeCapabilities.window.setFullscreen(false);
  assert.equal(setExit, false);

  if (originalDocument !== undefined) {
    globalThis.document = originalDocument;
  } else {
    delete globalThis.document;
  }
});

test('window.close in Web mode respects window.opener guard to eliminate Chrome console warnings', async () => {
  resetNativeEngineForTests();
  const originalWindow = globalThis.window;
  let closeCalled = false;

  // Case 1: No opener -> close is not invoked
  globalThis.window = {
    opener: null,
    close: () => { closeCalled = true; },
  };

  await nativeCapabilities.window.close();
  assert.equal(closeCalled, false);

  // Case 2: Opener present -> close is invoked
  globalThis.window.opener = {};
  await nativeCapabilities.window.close();
  assert.equal(closeCalled, true);

  if (originalWindow !== undefined) {
    globalThis.window = originalWindow;
  } else {
    delete globalThis.window;
  }
});

test('fullscreen methods check navigator.userActivation.isActive to prevent browser warning before requestFullscreen', async () => {
  resetNativeEngineForTests();
  const originalDocument = globalThis.document;
  const originalNavigatorDesc = Object.getOwnPropertyDescriptor(globalThis, 'navigator');

  let requestCalled = false;
  globalThis.document = {
    fullscreenElement: null,
    documentElement: {
      requestFullscreen: async () => {
        requestCalled = true;
      },
    },
  };

  // When userActivation.isActive is false:
  Object.defineProperty(globalThis, 'navigator', {
    value: { userActivation: { isActive: false } },
    configurable: true,
    writable: true,
  });

  const toggleRes = await nativeCapabilities.window.toggleFullscreen();
  assert.equal(toggleRes, false);
  assert.equal(requestCalled, false, 'requestFullscreen should not be called when userActivation is inactive');

  const setRes = await nativeCapabilities.window.setFullscreen(true);
  assert.equal(setRes, false);
  assert.equal(requestCalled, false, 'requestFullscreen should not be called when userActivation is inactive');

  // When userActivation.isActive is true:
  navigator.userActivation.isActive = true;
  const activeToggleRes = await nativeCapabilities.window.toggleFullscreen();
  assert.equal(activeToggleRes, true);
  assert.equal(requestCalled, true);

  if (originalDocument !== undefined) globalThis.document = originalDocument;
  else delete globalThis.document;

  if (originalNavigatorDesc) {
    Object.defineProperty(globalThis, 'navigator', originalNavigatorDesc);
  } else {
    delete globalThis.navigator;
  }
});

test('agentmirror:native window.state event updates epoch and geometryGeneration in getSwiftState', async () => {
  resetNativeEngineForTests();
  const originalWindow = globalThis.window;

  globalThis.window = {
    addEventListener: () => {},
    dispatchEvent: () => {},
  };

  const initial = nativeCapabilities.getSwiftState ? nativeCapabilities.getSwiftState() : {};

  // Simulate window.dispatchEvent with 'agentmirror:native'
  const event = {
    detail: {
      epoch: 'generation-epoch-777',
      event: 'window.state',
      payload: {
        geometryGeneration: 42,
      },
    },
  };

  // Dispatch on globalThis if custom event is available
  if (typeof globalThis.dispatchEvent === 'function') {
    globalThis.dispatchEvent(new CustomEvent('agentmirror:native', { detail: event.detail }));
  }

  if (originalWindow !== undefined) globalThis.window = originalWindow;
  else delete globalThis.window;
  resetNativeEngineForTests();
});

test('secureStore.set rejects with fail-closed Error when devices payload is not an Array', async () => {
  resetNativeEngineForTests();

  await assert.rejects(
    nativeCapabilities.secureStore.set('devices', null),
    /secureStore: devices must be an array/,
  );
  await assert.rejects(
    nativeCapabilities.secureStore.set('devices', 'not-array'),
    /secureStore: devices must be an array/,
  );
  await assert.rejects(
    nativeCapabilities.secureStore.set('devices', { id: 'single-device' }),
    /secureStore: devices must be an array/,
  );
  await assert.rejects(
    nativeCapabilities.secureStore.set('devices', 12345),
    /secureStore: devices must be an array/,
  );

  resetNativeEngineForTests();
});

test('surface.update with phase: "disarm" strictly sends only 3 fields: phase, geometryGeneration, revision', async () => {
  resetNativeEngineForTests();
  const originalWindow = globalThis.window;
  const calls = [];

  try {
    globalThis.window = {
      webkit: {
        messageHandlers: {
          native: {
            postMessage: async (envelope) => {
              calls.push(envelope);
              if (envelope.method === 'bootstrap') {
                return {
                  v: 1,
                  id: envelope.id,
                  ok: true,
                  result: {
                    epoch: 'disarm-epoch-888',
                    window: { geometryGeneration: 7 },
                  },
                };
              }
              if (envelope.method === 'surface.update') {
                return { v: 1, id: envelope.id, epoch: 'disarm-epoch-888', ok: true, result: { disarmed: true } };
              }
              return { ok: false, error: 'unknown' };
            },
          },
        },
      },
    };

    assert.equal(nativeCapabilities.environment, 'swift');

    const result = await nativeCapabilities.surface.update({
      phase: 'disarm',
      geometryGeneration: 7,
      revision: 10,
      viewportCSS: { width: 1000, height: 700 }, // Extra fields passed to API must be stripped on disarm!
      dragRects: [{ x: 0, y: 0, width: 1000, height: 38 }],
    });

    assert.deepEqual(result, { disarmed: true });
    // Call 0: bootstrap, Call 1: surface.update (disarm)
    assert.equal(calls.length, 2);
    assert.equal(calls[1].method, 'surface.update');
    assert.equal(calls[1].epoch, 'disarm-epoch-888');

    const params = calls[1].params;
    // Strictly assert the exact keys
    assert.deepEqual(Object.keys(params).sort(), ['geometryGeneration', 'phase', 'revision']);
    assert.equal(params.phase, 'disarm');
    assert.equal(params.geometryGeneration, 7);
    assert.equal(params.revision, 10);
  } finally {
    if (originalWindow !== undefined) globalThis.window = originalWindow;
    else delete globalThis.window;
    resetNativeEngineForTests();
  }
});

test('OPEN-3: rawCallSwiftRPC rejects with invalid_response when reply.id mismatches', async () => {
  resetNativeEngineForTests();
  const originalWindow = globalThis.window;

  try {
    globalThis.window = {
      webkit: {
        messageHandlers: {
          native: {
            postMessage: async (envelope) => {
              if (envelope.method === 'bootstrap') {
                return {
                  v: 1,
                  id: 'tampered-mismatch-id',
                  ok: true,
                  epoch: 'boot-epoch-1',
                };
              }
              return { ok: true };
            },
          },
        },
      },
    };

    assert.equal(nativeCapabilities.environment, 'swift');

    await assert.rejects(
      nativeCapabilities.window.minimize(),
      /invalid_response: reply id mismatch/,
    );
  } finally {
    if (originalWindow !== undefined) globalThis.window = originalWindow;
    else delete globalThis.window;
    resetNativeEngineForTests();
  }
});

test('OPEN-3: rawCallSwiftRPC rejects with stale_geometry when reply.epoch mismatches currentEpoch', async () => {
  resetNativeEngineForTests();
  const originalWindow = globalThis.window;

  try {
    globalThis.window = {
      webkit: {
        messageHandlers: {
          native: {
            postMessage: async (envelope) => {
              if (envelope.method === 'bootstrap') {
                return {
                  v: 1,
                  id: envelope.id,
                  ok: true,
                  epoch: 'current-valid-epoch',
                };
              }
              if (envelope.method === 'window.minimize') {
                return {
                  v: 1,
                  id: envelope.id,
                  epoch: 'stale-old-epoch-from-past-life',
                  ok: true,
                  result: null,
                };
              }
              return { ok: true };
            },
          },
        },
      },
    };

    assert.equal(nativeCapabilities.environment, 'swift');

    await assert.rejects(
      nativeCapabilities.window.minimize(),
      /stale_geometry: missing or mismatched reply epoch/,
    );
  } finally {
    if (originalWindow !== undefined) globalThis.window = originalWindow;
    else delete globalThis.window;
    resetNativeEngineForTests();
  }
});






