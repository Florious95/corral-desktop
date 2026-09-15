import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import {
  edgeAt,
  computePreviewRect,
  hitTestLeafPanes,
  hitTestTabBar,
  TabDragController,
  HOLD_DELAY_MS,
  TOLERANCE_PX,
  HYSTERESIS_PX,
  MIN_PANE_W,
  MIN_PANE_H,
} from '../src/lib/tabDrag.js';

test('tabDrag: edgeAt 25% boundary and corner horizontal preference', () => {
  const rect = { x: 0, y: 0, w: 400, h: 400 };

  // 1. Center 50%x50% (x: 100~300, y: 100~300) -> null (center no-op)
  assert.equal(edgeAt(rect, 200, 200), null);
  assert.equal(edgeAt(rect, 101, 101), null);
  assert.equal(edgeAt(rect, 299, 299), null);

  // 2. Left 25% (x < 100)
  assert.equal(edgeAt(rect, 50, 200), 'left');

  // 3. Right 25% (x > 300)
  assert.equal(edgeAt(rect, 350, 200), 'right');

  // 4. Top 25% (y < 100)
  assert.equal(edgeAt(rect, 200, 50), 'top');

  // 5. Bottom 25% (y > 300)
  assert.equal(edgeAt(rect, 200, 350), 'bottom');

  // 6. Corner exact diagonal equidistant (e.g. x=50, y=50 in a 400x400):
  // distances: [['left', 50/400=0.125], ['right', 0.875], ['top', 0.125], ['bottom', 0.875]]
  // Fixed order gives horizontal ('left') precedence over 'top'
  assert.equal(edgeAt(rect, 50, 50), 'left');

  // 7. Closer to top: x=60, y=30 -> top is 30/400=0.075 < 60/400=0.15 -> 'top'
  assert.equal(edgeAt(rect, 60, 30), 'top');
});

test('tabDrag: edgeAt 3px hysteresis prevents diagonal edge flickering', () => {
  const rect = { x: 0, y: 0, w: 400, h: 400 };

  // Initial at left edge: x=50, y=200
  const initial = edgeAt(rect, 50, 200);
  assert.equal(initial, 'left');

  // Move near diagonal: x=50, y=49 (top distance = 49px, left distance = 50px)
  // Distance to top is 49px, distance to left is 50px.
  // The difference is only 1px (< 3px hysteresis) -> retains 'left'!
  const hysteresisRetained = edgeAt(rect, 50, 49, 'left', 3);
  assert.equal(hysteresisRetained, 'left');

  // Move further into top: x=50, y=45 (top distance = 45px, left distance = 50px, diff = 5px >= 3px)
  // Switch to 'top'!
  const hysteresisSwitched = edgeAt(rect, 50, 45, 'left', 3);
  assert.equal(hysteresisSwitched, 'top');
});

test('tabDrag: computePreviewRect calculates exact half split rectangles', () => {
  const rect = { x: 100, y: 50, w: 800, h: 600 };

  assert.deepEqual(computePreviewRect(rect, 'left'), {
    x: 100,
    y: 50,
    w: 400,
    h: 600,
  });

  assert.deepEqual(computePreviewRect(rect, 'right'), {
    x: 500,
    y: 50,
    w: 400,
    h: 600,
  });

  assert.deepEqual(computePreviewRect(rect, 'top'), {
    x: 100,
    y: 50,
    w: 800,
    h: 300,
  });

  assert.deepEqual(computePreviewRect(rect, 'bottom'), {
    x: 100,
    y: 350,
    w: 800,
    h: 300,
  });
});

test('tabDrag: hitTestLeafPanes edge suction, self rejection, and minimum size protection', () => {
  const stageRect = { x: 0, y: 40, w: 1000, h: 600 };
  const leafRects = [
    { uid: 'pane-1', rect: { x: 0, y: 40, w: 500, h: 600 } },
    { uid: 'pane-2', rect: { x: 500, y: 40, w: 500, h: 600 } },
  ];

  // 1. Outside stage -> null
  assert.equal(hitTestLeafPanes({ x: 500, y: 10, sourceUid: 'tab-x', stageRect, leafRects }), null);

  // 2. Over pane-1 right edge (x: 450, y: 300) -> edge 'right'
  const hitRight = hitTestLeafPanes({ x: 450, y: 300, sourceUid: 'tab-x', stageRect, leafRects });
  assert.equal(hitRight.type, 'edge');
  assert.equal(hitRight.targetUid, 'pane-1');
  assert.equal(hitRight.edge, 'right');
  assert.deepEqual(hitRight.previewRect, { x: 250, y: 40, w: 250, h: 600 });

  // 3. Self-drop rejection: dragging pane-1 into pane-1 -> center (no-op)
  const selfHit = hitTestLeafPanes({ x: 450, y: 300, sourceUid: 'pane-1', stageRect, leafRects });
  assert.equal(selfHit.type, 'center');
  assert.equal(selfHit.targetUid, 'pane-1');

  // 4. Center of pane-1 (x: 250, y: 300) -> center (no-op)
  const centerHit = hitTestLeafPanes({ x: 250, y: 300, sourceUid: 'tab-x', stageRect, leafRects });
  assert.equal(centerHit.type, 'center');

  // 5. Minimum size protection: tiny pane cannot be split further
  const tinyLeaves = [
    { uid: 'tiny-pane', rect: { x: 0, y: 40, w: 150, h: 600 } }, // width/2 = 75 < MIN_PANE_W (120)
  ];
  const tinyHit = hitTestLeafPanes({ x: 140, y: 300, sourceUid: 'tab-x', stageRect, leafRects: tinyLeaves });
  assert.equal(tinyHit.type, 'center'); // rejected from edge split, falls back to center no-op
});

test('tabDrag: hitTestTabBar determines target index for horizontal reordering', () => {
  const tabBarRect = { x: 80, y: 0, w: 600, h: 38 };
  const tabRects = [
    { uid: 'tab-1', index: 0, pinned: false, rect: { x: 80, y: 5, w: 100, h: 28 } },
    { uid: 'tab-2', index: 1, pinned: false, rect: { x: 184, y: 5, w: 100, h: 28 } },
    { uid: 'tab-3', index: 2, pinned: false, rect: { x: 288, y: 5, w: 100, h: 28 } },
  ];

  // Drag tab-1 towards tab-3 (x = 320)
  const hit = hitTestTabBar({ x: 320, y: 15, sourceUid: 'tab-1', tabBarRect, tabRects });
  assert.equal(hit.type, 'tabbar');
  assert.equal(hit.fromIndex, 0);
  assert.equal(hit.toIndex, 2);
});

test('tabDrag: TabDragController state machine and zero forced reflow in hot path', async () => {
  let dropped = null;
  let reordered = null;
  let stateEvents = [];

  const stageRect = { x: 0, y: 40, w: 1000, h: 600 };
  const controller = new TabDragController({
    getStageEl: () => ({
      getBoundingClientRect: () => ({ left: 0, top: 40, width: 1000, height: 600 }),
    }),
    getTabBarEl: () => ({
      getBoundingClientRect: () => ({ left: 80, top: 0, width: 600, height: 38 }),
      querySelectorAll: () => [],
    }),
    getTabs: () => [{ uid: 'tab-1', pinned: false }],
    getRoot: () => ({ kind: 'leaf', uid: 'pane-1' }),
    onDropSplit: (sourceUid, targetUid, edge) => {
      dropped = { sourceUid, targetUid, edge };
    },
    onReorderTabs: (from, to) => {
      reordered = { from, to };
    },
    onStateChange: (state, info) => {
      stateEvents.push({ state, info });
    },
  });

  const mockOverlay = { style: {} };
  const mockGhost = { style: {} };
  controller.mountOverlays(mockOverlay, mockGhost);

  // 1. Initial state is idle
  assert.equal(controller.state, 'idle');

  // 2. Start pointerdown: enters pendingHold
  const mockEvent = {
    button: 0,
    pointerId: 1,
    clientX: 100,
    clientY: 20,
    target: {},
    currentTarget: { setPointerCapture: () => {}, releasePointerCapture: () => {} },
  };

  controller.start(mockEvent, { uid: 'tab-1', pinned: false }, 'Session 1');
  assert.equal(controller.state, 'pendingHold');

  // 3. Move < TOLERANCE_PX (6px) before hold timer: still pendingHold
  controller._onPointerMove({ pointerId: 1, clientX: 102, clientY: 22 });
  assert.equal(controller.state, 'pendingHold');

  // 4. Move > TOLERANCE_PX before 180ms timer: cancels pendingHold
  controller._onPointerMove({ pointerId: 1, clientX: 120, clientY: 20 });
  assert.equal(controller.state, 'idle');

  // 5. Test hold expiration triggers dragging
  controller.start(mockEvent, { uid: 'tab-1', pinned: false }, 'Session 1');
  assert.equal(controller.state, 'pendingHold');

  await new Promise((r) => setTimeout(r, HOLD_DELAY_MS + 20));
  assert.equal(controller.state, 'dragging');
  assert.equal(stateEvents.at(-1)?.state, 'dragging');

  // 6. During dragging, process frame updates ghost and overlay without DOM layout reads
  controller.lastX = 50;
  controller.lastY = 100;
  controller._processFrame();
  assert.match(mockGhost.style.transform, /translate3d/);
  assert.equal(mockGhost.style.opacity, '1');

  // 7. PointerUp triggers drop
  // Mock pointerup over pane-1 top edge: (x: 500, y: 60)
  controller.cachedStageRect = stageRect;
  controller.cachedLeafRects = [{ uid: 'pane-1', rect: { x: 0, y: 40, w: 1000, h: 600 } }];
  controller._onPointerUp({ pointerId: 1, clientX: 500, clientY: 60 });

  assert.equal(controller.state, 'idle');
  assert.deepEqual(dropped, {
    sourceUid: 'tab-1',
    targetUid: 'pane-1',
    edge: 'top',
  });

  controller.dispose();
});

test('tabDrag: zero DOM reads verification via source inspection', async () => {
  const tabDragJs = await readFile(new URL('../src/lib/tabDrag.js', import.meta.url), 'utf8');

  // _onPointerMove must NOT call getBoundingClientRect or layout getters
  const moveFn = tabDragJs.slice(tabDragJs.indexOf('_onPointerMove'), tabDragJs.indexOf('_scheduleRaf'));
  assert.equal(moveFn.includes('getBoundingClientRect'), false);
  assert.equal(moveFn.includes('offsetWidth'), false);
  assert.equal(moveFn.includes('offsetHeight'), false);
  assert.equal(moveFn.includes('getComputedStyle'), false);

  // _processFrame must NOT call getBoundingClientRect
  const frameFn = tabDragJs.slice(tabDragJs.indexOf('_processFrame'), tabDragJs.indexOf('_updateTabReorderPreview'));
  assert.equal(frameFn.includes('getBoundingClientRect'), false);
  assert.equal(frameFn.includes('offsetWidth'), false);
  assert.equal(frameFn.includes('offsetHeight'), false);
  assert.equal(frameFn.includes('getComputedStyle'), false);
});
