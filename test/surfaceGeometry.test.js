import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  collectSurfaceGeometry,
  createSurfaceGeometryWatcher,
  SURFACE_DEBOUNCE_MS,
} from '../src/lib/surfaceGeometry.js';
import {
  nativeCapabilities,
  resetNativeEngineForTests,
} from '../src/core/nativeCapabilities.js';

test('collectSurfaceGeometry returns safe viewport when container is empty or null', () => {
  const geom = collectSurfaceGeometry(null);
  assert.deepEqual(geom.dragRects, []);
  assert.deepEqual(geom.exclusionRects, []);
  assert.equal(typeof geom.viewportCSS.width, 'number');
  assert.equal(typeof geom.viewportCSS.height, 'number');
});

test('collectSurfaceGeometry properly separates dragRects and exclusionRects', () => {
  const originalWindow = globalThis.window;
  globalThis.window = {
    innerWidth: 1200,
    innerHeight: 800,
  };

  function mockElement(rect, closestMatch = false) {
    return {
      getBoundingClientRect: () => rect,
      closest: () => closestMatch,
    };
  }

  const mockHeader = mockElement({ left: 0, top: 0, width: 1200, height: 38 });
  const mockButton = mockElement({ left: 100, top: 6, width: 26, height: 26 }, true);
  const mockOutsideButton = mockElement({ left: 100, top: 100, width: 26, height: 26 }, false);

  const mockContainer = {
    querySelectorAll: (selector) => {
      if (selector.includes('.tb-session-header')) {
        return [mockHeader];
      }
      if (selector.includes('.tb-sidebar-toggle')) {
        return [mockButton, mockOutsideButton];
      }
      return [];
    },
  };

  const geom = collectSurfaceGeometry(mockContainer);
  assert.equal(geom.viewportCSS.width, 1200);
  assert.equal(geom.viewportCSS.height, 800);

  // dragRects must include the header
  assert.equal(geom.dragRects.length, 1);
  assert.deepEqual(geom.dragRects[0], { x: 0, y: 0, width: 1200, height: 38 });

  // exclusionRects must only include the button inside the header
  assert.equal(geom.exclusionRects.length, 1);
  assert.deepEqual(geom.exclusionRects[0], { x: 100, y: 6, width: 26, height: 26 });

  // chromeRect must contain all dragRects
  assert.equal(geom.phase, 'arm');
  assert.ok(geom.chromeRect);
  assert.equal(geom.chromeRect.width, 1200);
  assert.ok(geom.chromeRect.height >= 38);

  if (originalWindow !== undefined) globalThis.window = originalWindow;
  else delete globalThis.window;
});

test('createSurfaceGeometryWatcher debounces updates by SURFACE_DEBOUNCE_MS', async () => {
  const mockContainer = {
    querySelectorAll: () => [],
  };
  const updates = [];
  const watcher = createSurfaceGeometryWatcher({
    container: mockContainer,
    debounceMs: 50,
    onUpdate: (geom) => updates.push(geom),
  });

  // Schedule multiple times rapidly
  watcher.schedule();
  watcher.schedule();
  watcher.schedule();

  // Initially before debounce timeout, no reports fired yet
  assert.equal(updates.length, 0);

  // Await debounce interval
  await new Promise((resolve) => setTimeout(resolve, 80));

  assert.equal(updates.length, 1);
  watcher.dispose();
});

test('nativeCapabilities.surface.update dispatches RPC in Swift environment with complete 8-field payload', async () => {
  resetNativeEngineForTests();
  const originalWindow = globalThis.window;
  const calls = [];

  globalThis.window = {
    webkit: {
      messageHandlers: {
        native: {
          postMessage: async (envelope) => {
            calls.push(envelope);
            if (envelope.method === 'bootstrap') {
              return {
                ok: true,
                result: {
                  epoch: 'test-epoch-999',
                  window: { geometryGeneration: 3 },
                },
              };
            }
            if (envelope.method === 'surface.update') {
              return { ok: true, result: { applied: true } };
            }
            return { ok: false, error: 'unknown' };
          },
        },
      },
    },
  };

  assert.equal(nativeCapabilities.environment, 'swift');

  const updateResult = await nativeCapabilities.surface.update({
    viewportCSS: { width: 1400, height: 900 },
    dragRects: [{ x: 0, y: 0, width: 1400, height: 38 }],
    exclusionRects: [{ x: 18, y: 10, width: 80, height: 20 }],
  });

  assert.deepEqual(updateResult, { applied: true });
  // Call 0: bootstrap, Call 1: surface.update
  assert.equal(calls.length, 2);
  assert.equal(calls[0].method, 'bootstrap');
  assert.equal(calls[1].method, 'surface.update');
  assert.equal(calls[1].epoch, 'test-epoch-999');

  const p = calls[1].params;
  assert.equal(p.phase, 'arm');
  assert.equal(p.geometryGeneration, 3);
  assert.ok(typeof p.revision === 'number' && p.revision > 0);
  assert.deepEqual(p.viewportCSS, { width: 1400, height: 900 });
  assert.equal(typeof p.devicePixelRatio, 'number');
  assert.equal(p.dragRects.length, 1);
  assert.equal(p.exclusionRects.length, 1);
  assert.deepEqual(p.chromeRect, { x: 0, y: 0, width: 1400, height: 38 });

  if (originalWindow !== undefined) globalThis.window = originalWindow;
  else delete globalThis.window;
  resetNativeEngineForTests();
});

test('createSurfaceGeometryWatcher only deduplicates after successful ACK and retries on failure', async () => {
  let attempts = 0;
  let succeeds = false;

  const mockContainer = {
    querySelectorAll: () => [],
  };

  const watcher = createSurfaceGeometryWatcher({
    container: mockContainer,
    debounceMs: 10,
    onUpdate: async () => {
      attempts += 1;
      if (!succeeds) {
        throw new Error('RPC transient failure');
      }
      return { ok: true };
    },
  });

  // Attempt 1: Fails
  watcher.triggerImmediately();
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(attempts, 1);

  // Attempt 2: Same geometry scheduled again. Because previous failed, it MUST retry!
  succeeds = true;
  watcher.triggerImmediately();
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(attempts, 2);

  // Attempt 3: Same geometry scheduled again after success. It MUST be deduplicated!
  watcher.triggerImmediately();
  await new Promise((r) => setTimeout(r, 20));
  assert.equal(attempts, 2);

  watcher.dispose();
});

test('nativeCapabilities.surface.update returns safe ok in Mock environment without side-effects', async () => {
  resetNativeEngineForTests();
  const result = await nativeCapabilities.surface.update({
    viewportCSS: { width: 800, height: 600 },
    dragRects: [],
    exclusionRects: [],
  });
  assert.deepEqual(result, { ok: true });
});

test('OPEN-2 & OPEN-3: watcher sends disarm immediately upon layout change and disposes cleanly', async () => {
  const dispatched = [];
  const mockContainer = {
    querySelectorAll: () => [],
  };

  const watcher = createSurfaceGeometryWatcher({
    container: mockContainer,
    debounceMs: 30,
    onUpdate: (geom) => dispatched.push(geom),
  });

  // Initial schedule has run report (arm)
  await new Promise((r) => setTimeout(r, 60));
  assert.ok(dispatched.length >= 1);
  assert.equal(dispatched[dispatched.length - 1].phase, 'arm');

  // Trigger disarm
  dispatched.length = 0;
  watcher.disarm();
  assert.equal(dispatched.length, 1);
  assert.equal(dispatched[0].phase, 'disarm');

  // Trigger dispose: sends final disarm and cancels all pending tasks
  dispatched.length = 0;
  watcher.dispose();
  assert.equal(dispatched.length, 1);
  assert.equal(dispatched[0].phase, 'disarm');

  // Wait past debounce interval; no more updates should be dispatched after dispose
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(dispatched.length, 1);
});

