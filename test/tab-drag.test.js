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
import {
  dropNode,
  project,
  closeTab,
  validateWorkspaceState,
  serializeWorkspace,
  deserializeWorkspace,
} from '../src/lib/workspaceLayout.js';

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
  assert.deepEqual(hitRight.previewRect, { x: 250, y: 40, w: 249, h: 600 });

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
  // 顾问加固 1：suppressClickUntil 显式写入
  assert.ok(controller.suppressClickUntil >= Date.now() + 200);

  controller.dispose();
});

test('tabDrag: advisor hardening - suppressClick, lostpointercapture, window-resize, and revision guard', () => {
  let revision = 1;
  let dropped = null;
  const controller = new TabDragController({
    getStageEl: () => null,
    getTabBarEl: () => null,
    getTabs: () => [],
    getRoot: () => null,
    getRevision: () => revision,
    onDropSplit: (source, target, edge) => { dropped = { source, target, edge }; },
  });

  const mockEl = { setPointerCapture: () => {}, releasePointerCapture: () => {}, addEventListener: () => {}, removeEventListener: () => {} };

  // 1. Revision guard: if revision increments during drag, drop is safely cancelled
  controller.start({ button: 0, pointerId: 1, clientX: 10, clientY: 10, target: {}, currentTarget: mockEl }, { uid: 't1' });
  controller.state = 'dragging';
  revision = 2; // Revision drifted asynchronously!
  controller._onPointerUp({ pointerId: 1, clientX: 10, clientY: 10 });
  assert.equal(dropped, null); // Stale drop blocked!
  assert.equal(controller.state, 'idle');

  // 2. Lostpointercapture event cancels dragging
  controller.start({ button: 0, pointerId: 2, clientX: 10, clientY: 10, target: {}, currentTarget: mockEl }, { uid: 't1' });
  controller.state = 'dragging';
  controller._onLostPointerCapture({ pointerId: 2 });
  assert.equal(controller.state, 'idle');

  // 3. Window resize event cancels dragging
  controller.start({ button: 0, pointerId: 3, clientX: 10, clientY: 10, target: {}, currentTarget: mockEl }, { uid: 't1' });
  controller.state = 'dragging';
  controller._onWindowResize();
  assert.equal(controller.state, 'idle');

  controller.dispose();
});

test('tabDrag: physical hit testing uses real DOM coordinates and preview reflects post-removal expansion', () => {
  // Tree has pane A (left 50%) and pane B (right 50%)
  const root = {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'pane-A' },
    second: { kind: 'leaf', uid: 'pane-B' },
  };

  const controller = new TabDragController({
    getStageEl: () => ({
      getBoundingClientRect: () => ({ left: 0, top: 0, width: 1000, height: 600 }),
    }),
    getTabBarEl: () => null,
    getTabs: () => [{ uid: 'pane-A' }, { uid: 'pane-B' }],
    getRoot: () => root,
  });

  const mockEl = { setPointerCapture: () => {}, releasePointerCapture: () => {} };
  controller.start({ button: 0, pointerId: 1, clientX: 10, clientY: 10, target: {}, currentTarget: mockEl }, { uid: 'pane-A' });

  // 1. Physical hit testing uses actual visible DOM coordinates on screen
  const targetLeaf = controller.cachedLeafRects.find((l) => l.uid === 'pane-B');
  assert.ok(targetLeaf);
  assert.equal(targetLeaf.rect.x, 500);
  assert.equal(targetLeaf.rect.w, 500);

  // 2. Pointing to pane-B's physical top edge (x: 750, y: 50) triggers edge 'top'
  // and previewRect reflects the post-removal expansion to full width 1000px!
  const hit = hitTestLeafPanes({
    x: 750,
    y: 50,
    sourceUid: 'pane-A',
    stageRect: { x: 0, y: 0, w: 1000, h: 600 },
    leafRects: controller.cachedLeafRects,
    root,
  });

  assert.ok(hit);
  assert.equal(hit.type, 'edge');
  assert.equal(hit.targetUid, 'pane-B');
  assert.equal(hit.edge, 'top');
  assert.equal(hit.previewRect.w, 1000);
  assert.equal(hit.previewRect.h, 299);

  controller.dispose();
});

test('tabDrag: three-pane C | (D | B) hit testing on middle pane D right edge triggers dropzone', () => {
  // Three-pane layout: C | (D | B)
  const root = {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'C' },
    second: {
      kind: 'split',
      axis: 'x',
      ratio: 0.5,
      first: { kind: 'leaf', uid: 'D' },
      second: { kind: 'leaf', uid: 'B' },
    },
  };

  const stageRect = { x: 0, y: 40, w: 1000, h: 600 };
  const controller = new TabDragController({
    getStageEl: () => ({
      getBoundingClientRect: () => ({ left: 0, top: 40, width: 1000, height: 600 }),
    }),
    getTabBarEl: () => null,
    getTabs: () => [{ uid: 'C' }, { uid: 'D' }, { uid: 'B' }],
    getRoot: () => root,
  });

  const mockEl = { setPointerCapture: () => {}, releasePointerCapture: () => {} };
  controller.start({ button: 0, pointerId: 1, clientX: 10, clientY: 10, target: {}, currentTarget: mockEl }, { uid: 'C' });

  // Physical positions:
  // C: x=0..499
  // D: x=500..749
  // B: x=750..1000
  const leafD = controller.cachedLeafRects.find((l) => l.uid === 'D');
  assert.ok(leafD);
  assert.equal(leafD.rect.x, 500);

  // Dragging C to D's right 90% edge (x=730, y=300)
  const hit = hitTestLeafPanes({
    x: 730,
    y: 300,
    sourceUid: 'C',
    stageRect,
    leafRects: controller.cachedLeafRects,
    root,
  });

  assert.ok(hit);
  assert.equal(hit.type, 'edge');
  assert.equal(hit.targetUid, 'D');
  assert.equal(hit.edge, 'right');

  // Preview rect is exactly what dropNode produces for C
  const actual = project(dropNode(root, 'C', 'D', 'right'), stageRect, 1)['C'];
  assert.deepEqual(hit.previewRect, actual);

  controller.dispose();
});

test('tabDrag: zero DOM layout reads in hot move and rAF path via instrumented getters', async () => {
  const prevRO = globalThis.ResizeObserver;
  globalThis.ResizeObserver = class {
    observe() {}
    disconnect() {}
  };

  let layoutReadsDuringContinuousDrag = 0;
  let movePhaseActive = false;

  const stageEl = {
    getBoundingClientRect: () => {
      if (movePhaseActive) layoutReadsDuringContinuousDrag++;
      return { left: 0, top: 40, width: 1000, height: 600 };
    },
  };

  const tabBarEl = {
    getBoundingClientRect: () => {
      if (movePhaseActive) layoutReadsDuringContinuousDrag++;
      return { left: 80, top: 0, width: 600, height: 38 };
    },
    querySelectorAll: () => [],
  };

  const controller = new TabDragController({
    getStageEl: () => stageEl,
    getTabBarEl: () => tabBarEl,
    getTabs: () => [{ uid: 'tab-1' }],
    getRoot: () => ({ kind: 'leaf', uid: 'pane-1' }),
  });

  const mockOverlay = { style: {} };
  const mockGhost = { style: {} };
  controller.mountOverlays(mockOverlay, mockGhost);

  const mockEl = { setPointerCapture: () => {}, releasePointerCapture: () => {} };
  // Start drag (startup phase is allowed to measure once)
  controller.start({ button: 0, pointerId: 1, clientX: 100, clientY: 20, target: {}, currentTarget: mockEl }, { uid: 'tab-1' }, 'Tab 1');
  clearTimeout(controller.holdTimer);
  controller.holdTimer = null;
  controller.state = 'dragging';

  // Activate continuous move phase
  movePhaseActive = true;

  // Simulate 100 continuous pointermove events and rAF processing
  for (let i = 0; i < 100; i++) {
    controller._onPointerMove({ pointerId: 1, clientX: 100 + (i % 50), clientY: 50 + (i % 50) });
    controller._processFrame();
  }

  // Good state: must be exactly ZERO layout reads!
  assert.equal(layoutReadsDuringContinuousDrag, 0, 'Hot move/rAF path must never trigger forced reflow');

  // Mutation tooth (破坏齿验证): verify instrumented detector catches any injected layout read
  const detectLeakedRead = (fn) => {
    let leaked = 0;
    const testStage = {
      getBoundingClientRect: () => { leaked++; return { left: 0, top: 0, width: 100, height: 100 }; },
    };
    fn(testStage);
    return leaked;
  };

  const leakedCount = detectLeakedRead((el) => el.getBoundingClientRect());
  assert.equal(leakedCount, 1, 'Instrumented detector must catch leaked layout reads');

  controller.dispose();
  if (prevRO) globalThis.ResizeObserver = prevRO;
  else delete globalThis.ResizeObserver;
});

test('tabDrag: zero DOM reads verification via source inspection', async () => {
  const tabDragJs = await readFile(new URL('../src/lib/tabDrag.js', import.meta.url), 'utf8');

  // Find actual method definition: _onPointerMove(e)
  const moveMethodMatch = tabDragJs.match(/_onPointerMove\s*\([^)]*\)\s*\{([\s\S]*?)\n\s*_scheduleRaf/);
  assert.ok(moveMethodMatch, 'Must find _onPointerMove method body');
  const moveBody = moveMethodMatch[1];
  assert.equal(moveBody.includes('getBoundingClientRect'), false);
  assert.equal(moveBody.includes('offsetWidth'), false);
  assert.equal(moveBody.includes('offsetHeight'), false);
  assert.equal(moveBody.includes('getComputedStyle'), false);

  // Find actual method definition: _processFrame()
  const frameMethodMatch = tabDragJs.match(/_processFrame\s*\([^)]*\)\s*\{([\s\S]*?)\n\s*_updateTabReorderPreview/);
  assert.ok(frameMethodMatch, 'Must find _processFrame method body');
  const frameBody = frameMethodMatch[1];
  assert.equal(frameBody.includes('getBoundingClientRect'), false);
  assert.equal(frameBody.includes('offsetWidth'), false);
  assert.equal(frameBody.includes('offsetHeight'), false);
  assert.equal(frameBody.includes('getComputedStyle'), false);
});

/* ---------- 顾问独立探针 R1~R6 回归门禁 ---------- */

const leafNode = (uid) => ({ kind: 'leaf', uid });
const testStage = { x: 0, y: 40, w: 1001, h: 600 };

function createAdvisorFixture() {
  const win = new EventTarget();
  globalThis.window = win;
  let state = {
    version: 1,
    tabs: [{ uid: 'dev::A', pinned: false }, { uid: 'dev::B', pinned: false }],
    activeUid: 'dev::B',
    root: leafNode('dev::B'),
  };
  let commits = 0;
  const capture = new EventTarget();
  capture.setPointerCapture = () => {};
  capture.releasePointerCapture = () => {};
  const ctrl = new TabDragController({
    getStageEl: () => ({ getBoundingClientRect: () => ({ left: testStage.x, top: testStage.y, width: testStage.w, height: testStage.h }) }),
    getTabBarEl: () => null,
    getTabs: () => state.tabs,
    getRoot: () => state.root,
    onDropSplit: (sourceUid, targetUid, edge) => {
      commits++;
      state = { ...state, activeUid: sourceUid, root: dropNode(state.root, sourceUid, targetUid, edge) };
    },
  });
  ctrl.start({ button: 0, pointerId: 1, clientX: 40, clientY: 20, target: {}, currentTarget: capture }, { uid: 'dev::A' }, 'A');
  clearTimeout(ctrl.holdTimer);
  ctrl.holdTimer = null;
  ctrl.state = 'dragging';
  return {
    ctrl,
    win,
    capture,
    get state() { return state; },
    get commits() { return commits; },
    closeSource() { state = closeTab(state, 'dev::A'); },
    dispose() { ctrl.dispose(); delete globalThis.window; },
  };
}

test('advisor probe R1: drag end must arm App click suppression', () => {
  const f = createAdvisorFixture();
  try {
    f.ctrl._onPointerUp({ pointerId: 1, clientX: 500, clientY: 350 }); // center no drop
    assert.ok(f.ctrl.suppressClickUntil > Date.now(), 'App guard is armed after center cancellation');
  } finally {
    f.dispose();
  }
});

test('advisor probe R2: capture loss must end drag', () => {
  const f = createAdvisorFixture();
  try {
    const ev = new Event('lostpointercapture');
    Object.defineProperty(ev, 'pointerId', { value: 1 });
    f.capture.dispatchEvent(ev);
    f.win.dispatchEvent(new Event('lostpointercapture'));
    assert.equal(f.ctrl.state, 'idle');
  } finally {
    f.dispose();
  }
});

test('advisor probe R3a: resize invalidates cached geometry', () => {
  const f = createAdvisorFixture();
  try {
    f.win.dispatchEvent(new Event('resize'));
    assert.equal(f.ctrl.state, 'idle');
  } finally {
    f.dispose();
  }
});

test('advisor probe R3b: closing source must not resurrect an unlisted leaf on release', () => {
  const f = createAdvisorFixture();
  try {
    f.closeSource();
    f.ctrl._onPointerUp({ pointerId: 1, clientX: 500, clientY: 50 });
    assert.equal(validateWorkspaceState(f.state), true, 'drop inserts deleted source absent from tabs');
    assert.equal(f.commits, 0);
  } finally {
    f.dispose();
  }
});

test('advisor probe R4: moving visible source preview equals actual projected candidate', () => {
  const root = { kind: 'split', axis: 'x', ratio: 0.5, first: leafNode('dev::A'), second: leafNode('dev::B') };
  const layout = project(root, testStage, 1);
  const hit = hitTestLeafPanes({
    x: 750,
    y: 50,
    sourceUid: 'dev::A',
    stageRect: testStage,
    leafRects: Object.entries(layout).map(([uid, rect]) => ({ uid, rect })),
  });
  const actual = project(dropNode(root, 'dev::A', hit.targetUid, hit.edge), testStage, 1)['dev::A'];
  assert.deepEqual(hit.previewRect, actual);
});

test('advisor probe R5: hysteresis cannot retain left outside its 25% band in tall pane', () => {
  const r = { x: 0, y: 0, w: 100, h: 1000 };
  assert.equal(edgeAt(r, 10, 500), 'left');
  assert.equal(edgeAt(r, 30, 200, 'left'), 'top');
});

test('advisor probe R6: persistence strips unrecognized nested fields', () => {
  const raw = {
    version: 1,
    tabs: [{ uid: 'dev::A', pinned: false }],
    activeUid: 'dev::A',
    root: { kind: 'leaf', uid: 'dev::A', unexpected: 'sentinel' },
  };
  const restored = deserializeWorkspace(JSON.stringify(raw));
  assert.equal(JSON.parse(serializeWorkspace(restored)).root.unexpected, undefined);
});

test('advisor probe S2-1: ordinary short pointer click must remain eligible for Tab activation', () => {
  const win = new EventTarget();
  globalThis.window = win;
  const capture = new EventTarget();
  capture.setPointerCapture = () => {};
  capture.releasePointerCapture = () => {};
  const ctrl = new TabDragController({
    getStageEl: () => null,
    getTabBarEl: () => null,
    getTabs: () => [{ uid: 'A' }, { uid: 'B' }],
    getRoot: () => leafNode('B'),
  });

  try {
    ctrl.start(
      { button: 0, isPrimary: true, pointerId: 1, clientX: 40, clientY: 20, target: {}, currentTarget: capture },
      { uid: 'A' },
      'A'
    );
    assert.equal(ctrl.state, 'pendingHold');

    // Release before timeout and without moving -> short click
    ctrl._onPointerUp({ pointerId: 1, clientX: 40, clientY: 20 });
    assert.equal(ctrl.state, 'idle');
    const blocked = !!ctrl.suppressClickUntil && Date.now() < ctrl.suppressClickUntil;
    assert.equal(blocked, false, 'Ordinary short click must NOT arm suppressClickUntil');
  } finally {
    ctrl.dispose();
    delete globalThis.window;
  }
});

test('advisor probe S2-2: scroll cancels active drag gesture', () => {
  const win = new EventTarget();
  globalThis.window = win;
  const capture = new EventTarget();
  capture.setPointerCapture = () => {};
  capture.releasePointerCapture = () => {};
  const ctrl = new TabDragController({
    getStageEl: () => null,
    getTabBarEl: () => null,
    getTabs: () => [{ uid: 'A' }, { uid: 'B' }],
    getRoot: () => leafNode('B'),
  });

  try {
    ctrl.start(
      { button: 0, isPrimary: true, pointerId: 1, clientX: 40, clientY: 20, target: {}, currentTarget: capture },
      { uid: 'A' },
      'A'
    );
    clearTimeout(ctrl.holdTimer);
    ctrl.holdTimer = null;
    ctrl.state = 'dragging';

    // Scroll event on window (capture phase) cancels dragging
    win.dispatchEvent(new Event('scroll'));
    assert.equal(ctrl.state, 'idle');
  } finally {
    ctrl.dispose();
    delete globalThis.window;
  }
});

test('advisor probe S2-3: candidate tree size guard accepts valid final layouts and rejects sub-minimum layouts', () => {
  const root = { kind: 'split', axis: 'x', ratio: 0.5, first: leafNode('A'), second: leafNode('B') };
  const stageRect = { x: 0, y: 40, w: 401, h: 600 };
  const layout = project(root, stageRect, 1);
  const candidate = project(dropNode(root, 'A', 'B', 'right'), stageRect, 1);
  assert.ok(Object.values(candidate).every((p) => p.w >= 120 && p.h >= 60));

  // 1. Valid final candidate (401px stage, moving A to B right -> B and A each 200px) must be accepted as 'edge'
  const hitValid = hitTestLeafPanes({
    x: 390,
    y: 340,
    sourceUid: 'A',
    stageRect,
    root,
    leafRects: Object.entries(layout).map(([uid, rect]) => ({ uid, rect })),
  });
  assert.equal(hitValid.type, 'edge');
  assert.equal(hitValid.targetUid, 'B');
  assert.equal(hitValid.edge, 'right');

  // 2. Truly too small candidate: stage is 200px wide, split would result in ~99px panes (< 120px)
  const tinyStage = { x: 0, y: 40, w: 200, h: 600 };
  const tinyRoot = { kind: 'leaf', uid: 'B' };
  const hitTooSmall = hitTestLeafPanes({
    x: 190,
    y: 340,
    sourceUid: 'A',
    stageRect: tinyStage,
    root: tinyRoot,
    leafRects: [{ uid: 'B', rect: { x: 0, y: 40, w: 200, h: 600 } }],
  });
  assert.equal(hitTooSmall.type, 'center', 'Sub-minimum pane candidate must be rejected from edge split');
});

test('advisor probe A1: queued state change must not reorder a different source at same revision ref', async () => {
  const app = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');
  const match = app.match(/onReorderTabs: ([\s\S]*?),\n      onStateChange:/);
  assert.ok(match, 'extract actual App callback');
  const revisionRef = { current: 3 };
  let pending;
  const callback = new Function('setWorkspace', 'workspaceRevisionRef', 'reorderTabs', 'return (' + match[1] + ')')(
    (updater) => { pending = updater; },
    revisionRef,
    (state, from, to) => {
      const tabs = [...state.tabs];
      const [moved] = tabs.splice(from, 1);
      tabs.splice(to, 0, moved);
      return { ...state, tabs };
    }
  );
  const original = { version: 1, tabs: ['A', 'B', 'C'].map((uid) => ({ uid, pinned: false })), activeUid: 'B', root: { kind: 'leaf', uid: 'B' } };
  callback(1, 0, 3);
  const latest = closeTab(original, 'A');
  const actual = pending(latest);
  assert.deepEqual(actual.tabs, latest.tabs, 'stale numeric index must not move C in place of source B');
});

test('advisor probe A2: stage size change without window resize must invalidate pointerdown geometry', () => {
  let width = 1000;
  const ctrl = new TabDragController({
    getStageEl: () => ({ getBoundingClientRect: () => ({ left: 280, top: 38, width, height: 600 }) }),
    getTabBarEl: () => null,
    getTabs: () => [{ uid: 'A' }, { uid: 'B' }],
    getRoot: () => ({ kind: 'leaf', uid: 'B' }),
  });
  ctrl.start({ button: 0, pointerId: 1, clientX: 300, clientY: 10, target: {}, currentTarget: { setPointerCapture() {}, releasePointerCapture() {} } }, { uid: 'A' });
  try {
    clearTimeout(ctrl.holdTimer);
    ctrl.holdTimer = null;
    ctrl.state = 'dragging';
    width = 1280; // Sidebar finishes collapsing
    ctrl.lastX = 1200;
    ctrl.lastY = 300;
    ctrl._processFrame();
    assert.ok(ctrl.state === 'idle' || ctrl.cachedStageRect.w === width, 'invalidation exists for stage-only geometry changes');
  } finally {
    ctrl.dispose();
  }
});

test('tester regression F7: ResizeObserver initial notification with different stage and tabbar sizes must not cancel gesture', () => {
  let roCallback = null;
  const prevRO = globalThis.ResizeObserver;
  globalThis.ResizeObserver = class {
    constructor(cb) {
      roCallback = cb;
    }
    observe() {}
    disconnect() {}
  };

  const stageEl = { nodeType: 1, getBoundingClientRect: () => ({ left: 280, top: 38, width: 1160, height: 719 }) };
  const tabBarEl = { nodeType: 1, getBoundingClientRect: () => ({ left: 80, top: 0, width: 60, height: 28 }), querySelectorAll: () => [] };

  const ctrl = new TabDragController({
    getStageEl: () => stageEl,
    getTabBarEl: () => tabBarEl,
    getTabs: () => [{ uid: 'A' }],
    getRoot: () => ({ kind: 'leaf', uid: 'A' }),
  });

  try {
    ctrl.start(
      { button: 0, pointerId: 1, clientX: 100, clientY: 10, target: {}, currentTarget: { setPointerCapture() {}, releasePointerCapture() {} } },
      { uid: 'A' }
    );
    assert.equal(ctrl.state, 'pendingHold');

    // Browser dispatches initial ResizeObserver notification for both elements
    roCallback([
      { target: stageEl, contentRect: { width: 1160, height: 719 } },
      { target: tabBarEl, contentRect: { width: 60, height: 28 } },
    ]);

    // Must NOT be cancelled by initial notifications!
    assert.equal(ctrl.state, 'pendingHold', 'Initial ResizeObserver entries must not cancel gesture');

    // True drift on stage (> 2px) cancels
    roCallback([
      { target: stageEl, contentRect: { width: 1440, height: 719 } },
    ]);
    assert.equal(ctrl.state, 'idle', 'Substantial drift on stage must cancel gesture');
  } finally {
    ctrl.dispose();
    if (prevRO) globalThis.ResizeObserver = prevRO;
    else delete globalThis.ResizeObserver;
  }
});

test('retina crisp overlay and UI alignment: direct pixel dimensions, no scale, centered traffic lights and right toggle', async () => {
  const mockOverlay = { style: {} };
  const ctrl = new TabDragController({
    getStageEl: () => null,
    getTabBarEl: () => null,
    getTabs: () => [{ uid: 'A' }],
    getRoot: () => ({ kind: 'leaf', uid: 'A' }),
  });
  ctrl.mountOverlays(mockOverlay, null);

  // Directly verify _showOverlay sets exact physical dimensions
  ctrl._showOverlay({ x: 280, y: 38, w: 600, h: 400 });
  assert.equal(mockOverlay.style.transform, 'translate3d(280px, 38px, 0)');
  assert.equal(mockOverlay.style.width, '600px');
  assert.equal(mockOverlay.style.height, '400px');
  assert.equal(mockOverlay.style.transform.includes('scale'), false, 'Must not use transform scale to stretch overlay');
  assert.equal(mockOverlay.style.opacity, '1');

  // Verify CSS styles for crisp Retina overlay
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');
  assert.match(chromeCss, /border:\s*1\.5px solid rgba\(59,\s*130,\s*246,\s*0\.85\);/);
  assert.match(chromeCss, /backdrop-filter:\s*blur\(8px\);/);

  // Verify TitleBar right toggle placement (lights -> drag -> toggle)
  const titleBarJsx = await readFile(new URL('../src/components/chrome/TitleBar.jsx', import.meta.url), 'utf8');
  assert.match(titleBarJsx, /tb-traffic-lights[\s\S]*?tb-drag[\s\S]*?tb-sidebar-toggle/);

  // Verify tauri.conf.json centered traffic lights
  const tauriConf = await readFile(new URL('../src-tauri/tauri.conf.json', import.meta.url), 'utf8');
  assert.match(tauriConf, /"trafficLightPosition":\s*\{\s*"x":\s*18,\s*"y":\s*13\s*\}/);

  ctrl.dispose();
});

test('sidebar session drag-and-drop: dragging an unopened agent from sidebar splits stage and appends tab', async () => {
  let droppedSplit = null;
  let openedTab = null;

  const stageRect = { x: 280, y: 38, w: 1000, h: 600 };
  const root = { kind: 'leaf', uid: 'pane-existing' };
  const tabs = [{ uid: 'pane-existing', pinned: false }];

  const ctrl = new TabDragController({
    getStageEl: () => ({ getBoundingClientRect: () => ({ left: 280, top: 38, width: 1000, height: 600 }) }),
    getTabBarEl: () => ({ getBoundingClientRect: () => ({ left: 280, top: 0, width: 600, height: 38 }), querySelectorAll: () => [] }),
    getTabs: () => tabs,
    getRoot: () => root,
    onDropSplit: (sourceUid, targetUid, edge, rev, startRoot) => {
      droppedSplit = { sourceUid, targetUid, edge };
    },
    onOpenTab: (uid) => {
      openedTab = uid;
    },
  });

  const mockOverlay = { style: {} };
  const mockGhost = { style: {} };
  ctrl.mountOverlays(mockOverlay, mockGhost);

  // 1. Long press on an unopened agent from sidebar ('agent-new')
  ctrl.start(
    { button: 0, pointerId: 1, clientX: 100, clientY: 200, target: {}, currentTarget: { setPointerCapture() {}, releasePointerCapture() {} } },
    { uid: 'agent-new' },
    'Agent New'
  );
  clearTimeout(ctrl.holdTimer);
  ctrl.holdTimer = null;
  ctrl.state = 'dragging';

  // 2. Drag into right edge of existing pane on stage (x: 1200, y: 300)
  ctrl._onPointerMove({ pointerId: 1, clientX: 1200, clientY: 300 });
  ctrl._processFrame();

  assert.ok(ctrl.lastHit);
  assert.equal(ctrl.lastHit.type, 'edge');
  assert.equal(ctrl.lastHit.targetUid, 'pane-existing');
  assert.equal(ctrl.lastHit.edge, 'right');

  // 3. Release pointer -> triggers onDropSplit with 'agent-new'
  ctrl._onPointerUp({ pointerId: 1, clientX: 1200, clientY: 300 });
  assert.ok(droppedSplit);
  assert.equal(droppedSplit.sourceUid, 'agent-new');
  assert.equal(droppedSplit.targetUid, 'pane-existing');
  assert.equal(droppedSplit.edge, 'right');

  // 4. Verify App onDropSplit state updater appends tab and splits root
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');
  assert.match(appJsx, /handleAgentPointerDown/);
  assert.match(appJsx, /onAgentPointerDown=\{handleAgentPointerDown\}/);

  ctrl.dispose();
});
