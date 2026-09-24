import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TerminalView } from '../src/term/TerminalView.js';

class MockContainer {
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

test('TerminalView exposes renderer diagnostics, firstPaint callback, and window test hooks', async () => {
  globalThis.window = {
    __AGENTMIRROR_TEST_HOOKS__: {},
    dispatchEvent: () => {},
  };

  const container = new MockContainer();
  let firstPaintCalled = false;
  let firstPaintInfo = null;

  const view = new TerminalView(container, {
    traceRef: 'test-session-1',
    disableWebgl: true, // DOM renderer mode
    onFirstPaint: (info) => {
      firstPaintCalled = true;
      firstPaintInfo = info;
    },
  });

  assert.equal(view.rendererType, 'dom');
  assert.equal(view.canvasCount, 0);
  assert.equal(view.isFirstPaintRendered, false);

  // Write snapshot and wait for xterm parse/paint callback
  view.writeSnapshot(new TextEncoder().encode('\x1b[2J\x1b[H$ hello'));
  await new Promise((r) => setTimeout(r, 20));

  assert.equal(view.isFirstPaintRendered, true);
  assert.equal(firstPaintCalled, true);
  assert.equal(firstPaintInfo.ref, 'test-session-1');
  assert.equal(firstPaintInfo.renderer, 'dom');
  assert.equal(firstPaintInfo.canvasCount, 0);

  // Check window.__AGENTMIRROR_TEST_HOOKS__.getRenderDiagnostics()
  const diag = globalThis.window.__AGENTMIRROR_TEST_HOOKS__.getRenderDiagnostics();
  assert.ok(diag);
  assert.equal(diag.firstPaintRendered, true);
  assert.equal(diag.activePanesCount, 1);
  assert.equal(diag.activeRenderer, 'dom');
  assert.equal(diag.canvasCount, 0);
  assert.equal(diag.panes.length, 1);
  assert.equal(diag.panes[0].ref, 'test-session-1');
  assert.equal(diag.panes[0].renderer, 'dom');

  view.dispose();
  assert.equal(globalThis.window.__AGENTMIRROR_TEST_HOOKS__.getRenderDiagnostics().activePanesCount, 0);
});

test('TerminalView reports webgl renderer when WebGL addon is attached and active', async () => {
  globalThis.window = {
    __AGENTMIRROR_TEST_HOOKS__: {},
    dispatchEvent: () => {},
  };

  const container = new MockContainer();
  // Mock canvas in DOM
  container.querySelector = (sel) => {
    if (sel === '.xterm-screen canvas') return { getBoundingClientRect: () => ({ width: 800, height: 600 }) };
    return null;
  };
  container.querySelectorAll = (sel) => {
    if (sel === '.xterm-screen canvas') return [{}, {}];
    return [];
  };

  const view = new TerminalView(container, {
    traceRef: 'test-session-webgl',
    disableWebgl: false,
  });

  // Mock fake webgl addon attached
  view._webglAddon = { dispose() {} };

  assert.equal(view.rendererType, 'webgl');
  assert.equal(view.canvasCount, 2);

  view.writeSnapshot(new TextEncoder().encode('\x1b[2J\x1b[H$ webgl ready'));
  await new Promise((r) => setTimeout(r, 20));

  const diag = globalThis.window.__AGENTMIRROR_TEST_HOOKS__.getRenderDiagnostics();
  assert.equal(diag.activeRenderer, 'webgl');
  assert.equal(diag.firstPaintRendered, true);
  assert.equal(diag.canvasCount, 2);

  view.dispose();
});
