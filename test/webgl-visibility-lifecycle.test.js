import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { TerminalView } from '../src/term/TerminalView.js';
import { setNativeEngineForTests, resetNativeEngineForTests } from '../src/core/nativeCapabilities.js';

beforeEach(() => setNativeEngineForTests({ platform: 'macos' }));
afterEach(() => resetNativeEngineForTests());

class FakeElement {
  constructor(tag = 'div') {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.parentElement = null;
    this.style = {};
    this.clientWidth = 800;
    this.clientHeight = 600;
    this.isConnected = true;
  }
  appendChild(child) {
    this.children.push(child);
    child.parentElement = this;
    return child;
  }
  removeChild(child) {
    const idx = this.children.indexOf(child);
    if (idx !== -1) {
      this.children.splice(idx, 1);
      child.parentElement = null;
    }
    return child;
  }
  querySelector(sel) {
    if (sel.includes('canvas')) {
      return this.children.find((c) => c.tagName === 'CANVAS') || null;
    }
    return null;
  }
  querySelectorAll(sel) {
    if (sel.includes('canvas')) {
      return this.children.filter((c) => c.tagName === 'CANVAS');
    }
    return [];
  }
  getBoundingClientRect() {
    return { width: this.clientWidth, height: this.clientHeight, top: 0, left: 0 };
  }
  addEventListener() {}
  removeEventListener() {}
}

class FakeTerminalForWebgl {
  constructor(opts = {}) {
    this.opts = opts;
    this.cols = opts.cols || 80;
    this.rows = opts.rows || 24;
    this.writes = [];
    this.loadedAddons = [];
    this.screenElement = new FakeElement('div');
    this.element = this.screenElement;
    this._disposed = false;
  }
  loadAddon(addon) {
    this.loadedAddons.push(addon);
    if (typeof addon.activate === 'function') {
      addon.activate(this);
    }
  }
  open() {}
  onData() { return { dispose() {} }; }
  onScroll() { return { dispose() {} }; }
  attachCustomKeyEventHandler() { return true; }
  resize(cols, rows) { this.cols = cols; this.rows = rows; }
  reset() {}
  refresh() {}
  clearTextureAtlas() {}
  write(d) { this.writes.push(d); }
  focus() {}
  blur() {}
  dispose() { this._disposed = true; }
}

function createMockWebglImporter() {
  let createdCount = 0;
  let activeAddons = new Set();

  class MockWebglAddon {
    constructor() {
      createdCount += 1;
      this.id = createdCount;
      this._disposed = false;
      this.canvas = null;
      activeAddons.add(this);
    }
    activate(term) {
      this.term = term;
      this.canvas = new FakeElement('canvas');
      this.canvas.clientWidth = 640;
      this.canvas.clientHeight = 384;
      term.screenElement.appendChild(this.canvas);
    }
    onContextLoss(fn) { this._contextLossHandler = fn; }
    clearTextureAtlas() {}
    dispose() {
      if (this._disposed) return;
      this._disposed = true;
      activeAddons.delete(this);
      if (this.canvas && this.canvas.parentElement) {
        this.canvas.parentElement.removeChild(this.canvas);
      }
      this.canvas = null;
    }
  }

  const importer = async () => ({ WebglAddon: MockWebglAddon });
  return { importer, getCreatedCount: () => createdCount, getActiveCount: () => activeAddons.size };
}

test('Issue #314: TerminalView with isVisible: false starts in DOM mode without WebGL canvas', async () => {
  const container = new FakeElement('div');
  const { importer, getCreatedCount, getActiveCount } = createMockWebglImporter();

  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminalForWebgl,
    webglImporter: importer,
    isVisible: false,
  });
  view.open();

  assert.equal(view.isVisible, false, 'view.isVisible must be false');
  assert.equal(view.rendererType, 'dom', 'rendererType must be dom when started in background');
  assert.equal(view.canvasCount, 0, 'canvasCount must be 0 in background');
  assert.equal(getCreatedCount(), 0, 'No WebglAddon should be created when isVisible is false');
  assert.equal(getActiveCount(), 0, 'Active WebGL addons must be 0');

  view.dispose();
});

test('Issue #314: TerminalView.setVisible(false) disposes WebglAddon, removes canvas, and transitions to DOM mode', async () => {
  const container = new FakeElement('div');
  const { importer, getCreatedCount, getActiveCount } = createMockWebglImporter();

  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminalForWebgl,
    webglImporter: importer,
    isVisible: true,
  });
  view.open();

  await view.readyWebgl;
  assert.equal(view.isVisible, true);
  assert.equal(view.rendererType, 'webgl', 'rendererType must be webgl when active');
  assert.equal(view.canvasCount, 1, 'canvasCount must be 1 when active');
  assert.equal(getActiveCount(), 1, 'Active WebGL addon count must be 1');

  // Transition to background
  view.setVisible(false);

  assert.equal(view.isVisible, false, 'view.isVisible must transition to false');
  assert.equal(view.rendererType, 'dom', 'rendererType must fall back to dom');
  assert.equal(view.canvasCount, 0, 'canvasCount must drop to 0 after setVisible(false)');
  assert.equal(getActiveCount(), 0, 'Active WebGL addon count must be 0 after setVisible(false)');

  view.dispose();
});

test('Issue #314: TerminalView.setVisible(true) re-attaches WebGL and transitions back to webgl mode', async () => {
  const container = new FakeElement('div');
  const { importer, getCreatedCount, getActiveCount } = createMockWebglImporter();

  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminalForWebgl,
    webglImporter: importer,
    isVisible: false,
  });
  view.open();

  assert.equal(view.isVisible, false);
  assert.equal(view.rendererType, 'dom');
  assert.equal(view.canvasCount, 0);

  // Transition to visible
  view.setVisible(true);
  await view.attachWebgl();

  assert.equal(view.isVisible, true);
  assert.equal(view.rendererType, 'webgl');
  assert.equal(view.canvasCount, 1);
  assert.equal(getActiveCount(), 1);

  // Transitioning back to false
  view.setVisible(false);
  assert.equal(view.isVisible, false);
  assert.equal(view.rendererType, 'dom');
  assert.equal(view.canvasCount, 0);
  assert.equal(getActiveCount(), 0);

  view.dispose();
});

test('Issue #314: Robustness stress test - rapid 25+ visibility toggles without errors or state corruption', async () => {
  const container = new FakeElement('div');
  const { importer, getActiveCount } = createMockWebglImporter();

  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminalForWebgl,
    webglImporter: importer,
    isVisible: true,
  });
  view.open();
  await view.readyWebgl;

  for (let i = 0; i < 30; i++) {
    const nextVisible = i % 2 === 0;
    view.setVisible(nextVisible);
    assert.equal(view.isVisible, nextVisible);
    if (!nextVisible) {
      assert.equal(view.rendererType, 'dom');
      assert.equal(view.canvasCount, 0);
      assert.equal(getActiveCount(), 0);
    }
  }

  // Final settle to visible
  view.setVisible(true);
  await view.attachWebgl();
  assert.equal(view.isVisible, true);
  assert.equal(view.rendererType, 'webgl');
  assert.equal(view.canvasCount, 1);
  assert.equal(getActiveCount(), 1);

  // Final settle to hidden
  view.setVisible(false);
  assert.equal(view.isVisible, false);
  assert.equal(view.rendererType, 'dom');
  assert.equal(view.canvasCount, 0);
  assert.equal(getActiveCount(), 0);

  view.dispose();
  assert.equal(view._disposed, true);
  assert.equal(view.isVisible, false);
  assert.equal(getActiveCount(), 0);
});

test('UI-SPEC §6.2 documents 2026-09-25 visibility-driven WebGL lifecycle policy (Issue #314)', async () => {
  const { readFile } = await import('node:fs/promises');
  const spec = await readFile(new URL('../docs/UI-SPEC.md', import.meta.url), 'utf8');

  assert.match(spec, /2026-09-25（可见性驱动的 WebGL 动态装卸载与显存削减，Issue #314）/);
  assert.match(spec, /前台激活状态按需加载.*WebglAddon/);
  assert.match(spec, /切入后台非激活状态立即调用.*webglAddon\.dispose/);
  assert.match(spec, /销毁后台.*canvas.*并向操作系统归还 IOSurface 显存/);
});

