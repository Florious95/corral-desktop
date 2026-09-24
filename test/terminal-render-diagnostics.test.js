import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TerminalView } from '../src/term/TerminalView.js';

class MockElement {
  constructor() {
    this.clientWidth = 800;
    this.clientHeight = 600;
    this.isConnected = true;
    this.style = {};
  }
  addEventListener() {}
  removeEventListener() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  getBoundingClientRect() { return { width: 800, height: 600, top: 0, left: 0 }; }
}

test('Anti-False-Green: TerminalView never reports firstPaintRendered when open() was not called', async () => {
  const previousWindow = globalThis.window;
  globalThis.window = { __AGENTMIRROR_TEST_HOOKS__: {}, dispatchEvent() {} };

  const container = new MockElement();
  let firstPaintCalled = false;

  const view = new TerminalView(container, {
    traceRef: 'unopened-view',
    disableWebgl: true,
    onFirstPaint: () => { firstPaintCalled = true; },
  });

  // Verify initial unopened state
  assert.equal(Boolean(view.term.element), false, 'term.element must be undefined before open()');
  assert.equal(view.isFirstPaintRendered, false);

  // Write snapshot without calling open()
  view.writeSnapshot(new TextEncoder().encode('\x1b[2J\x1b[H$ unrendered data'));
  await new Promise((r) => setTimeout(r, 40));

  // Must NOT trigger onFirstPaint and must NOT be considered rendered
  assert.equal(firstPaintCalled, false, 'onFirstPaint callback must NOT fire when term is not opened in DOM');
  assert.equal(view.isFirstPaintRendered, false, 'isFirstPaintRendered getter must stay false');

  const hooks = globalThis.window.__AGENTMIRROR_TEST_HOOKS__;
  const diag = hooks.getRenderDiagnostics ? hooks.getRenderDiagnostics() : { firstPaintRendered: false, activePanesCount: 0 };
  assert.equal(diag.firstPaintRendered, false);
  assert.equal(diag.activePanesCount, 0, 'activePanesCount must be 0 because term.element is not connected');

  // Verify clean dispose does not retain view in activeViews
  view.dispose();
  assert.equal(Boolean(hooks.activeViews?.has(view)), false, 'activeViews must not retain disposed view');

  if (previousWindow === undefined) delete globalThis.window; else globalThis.window = previousWindow;
});

test('TerminalView reports firstPaintRendered only after open() mounts to DOM and snapshot parses', async () => {
  const previousWindow = globalThis.window;
  globalThis.window = { __AGENTMIRROR_TEST_HOOKS__: {}, dispatchEvent() {} };

  const container = new MockElement();
  const screenEl = new MockElement();
  screenEl.parentElement = container;

  let firstPaintCalled = false;
  let firstPaintInfo = null;

  const view = new TerminalView(container, {
    traceRef: 'opened-view',
    disableWebgl: true,
    onFirstPaint: (info) => {
      firstPaintCalled = true;
      firstPaintInfo = info;
    },
  });

  // Mock element getter on term instance
  Object.defineProperty(view.term, 'element', {
    value: screenEl,
    configurable: true,
  });

  // Write snapshot
  view.writeSnapshot(new TextEncoder().encode('\x1b[2J\x1b[H$ rendered content'));
  await new Promise((r) => setTimeout(r, 40));

  assert.equal(firstPaintCalled, true);
  assert.equal(view.isFirstPaintRendered, true);
  assert.equal(firstPaintInfo.ref, 'opened-view');
  assert.equal(firstPaintInfo.renderer, 'dom');

  const hooks = globalThis.window.__AGENTMIRROR_TEST_HOOKS__;
  const diag = hooks.getRenderDiagnostics();
  assert.equal(diag.firstPaintRendered, true);
  assert.equal(diag.activePanesCount, 1);

  // Disconnecting element removes it from active diagnostics
  screenEl.isConnected = false;
  view._notifyRenderDiagnostics();
  const diagDisconnected = hooks.getRenderDiagnostics();
  assert.equal(diagDisconnected.activePanesCount, 0);

  view.dispose();
  assert.equal(Boolean(hooks.activeViews?.has(view)), false);

  if (previousWindow === undefined) delete globalThis.window; else globalThis.window = previousWindow;
});
