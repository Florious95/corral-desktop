import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { TerminalView } from '../src/term/TerminalView.js';
import { setNativeEngineForTests, resetNativeEngineForTests } from '../src/core/nativeCapabilities.js';
import { disposeWebglAddon, silenceRenderLayerAtlas } from '../src/term/webglRenderer.js';
import { DeviceManager } from '../src/core/devices.js';

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

test('Issue #316: disposeWebglAddon triggers WEBGL_lose_context, zeroes canvases and clears layer atlas', () => {
  let loseCalled = false;
  const mockGl = {
    getExtension(name) {
      if (name === 'WEBGL_lose_context') {
        return { loseContext() { loseCalled = true; } };
      }
      return null;
    }
  };
  const mockCanvas = { width: 1400, height: 900 };
  const mockLayerCanvas = { width: 1400, height: 900 };
  let addonDisposed = false;
  const mockAddon = {
    _renderer: {
      _gl: mockGl,
      _canvas: mockCanvas,
      _renderLayers: [{ _canvas: mockLayerCanvas, _charAtlas: { some: 'atlas' } }],
      _charAtlas: {
        _tmpCanvas: { width: 512, height: 512 },
        pages: [{ canvas: { width: 1024, height: 1024 } }],
        _onAddTextureAtlasCanvas: { _disposed: true },
      },
    },
    dispose() { addonDisposed = true; },
  };

  disposeWebglAddon(mockAddon);
  assert.equal(loseCalled, true, 'WEBGL_lose_context.loseContext must be called to release IOSurface/Metal graphics');
  assert.equal(addonDisposed, true, 'addon.dispose must be called');
  assert.equal(mockCanvas.width, 0, 'Main canvas width must be zeroed to 0');
  assert.equal(mockCanvas.height, 0, 'Main canvas height must be zeroed to 0');
  assert.equal(mockLayerCanvas.width, 0, 'Render layer canvas width must be zeroed to 0');
  assert.equal(mockLayerCanvas.height, 0, 'Render layer canvas height must be zeroed to 0');
  assert.equal(mockAddon._renderer._renderLayers[0]._charAtlas, undefined, 'Render layer _charAtlas must be cleared');
  assert.equal(mockAddon._renderer._charAtlas._tmpCanvas.width, 0, 'Disposed atlas tmpCanvas width must be zeroed');
  assert.equal(mockAddon._renderer._charAtlas.pages[0].canvas.width, 0, 'Disposed atlas page canvas width must be zeroed');
});

test('Issue #316: silenceRenderLayerAtlas blocks conflicting 2048 texture atlas acquisition in LinkRenderLayer', () => {
  let refreshCalled = false;
  const layer = {
    _refreshCharAtlas() { refreshCalled = true; },
    _charAtlas: { id: 'conflicting-2048-atlas' },
  };
  const addon = {
    _renderer: {
      _renderLayers: [layer],
    },
  };

  silenceRenderLayerAtlas(addon);
  layer._refreshCharAtlas();
  assert.equal(refreshCalled, false, '_refreshCharAtlas on render layer must be no-op');
  assert.equal(layer._charAtlas, undefined, 'layer._charAtlas must be cleared to allow sharing WebglRenderer atlas');
});

test('Issue #316: TerminalView._syncCursorAnchor exits immediately when isVisible is false', () => {
  let lineRead = false;
  const container = new FakeElement('div');
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminalForWebgl,
    hideCursor: true,
    isVisible: false,
  });
  view.term.buffer = {
    active: {
      getLine() { lineRead = true; return null; }
    }
  };

  view._syncCursorAnchor();
  assert.equal(lineRead, false, 'Hidden terminal must skip scanning buffer lines for cursor anchor');
  view.dispose();
});

test('Issue #316: DeviceManager purges vanished sessionDetails on listing and device removal', () => {
  const dm = new DeviceManager({ autoLocal: false, storage: null });
  dm._devices = [{ id: 'dev-1', name: 'Dev 1', url: 'ws://127.0.0.1:9900/ws', token: 'tok', checked: true }];

  // 1. Initial listing with two sessions
  dm._recordListingSessions('dev-1', {
    workspaces: [{
      cwd: '/home/user',
      sessions: [{ ref: '%1', name: 's1' }, { ref: '%2', name: 's2' }],
    }],
  });
  assert.equal(dm._sessionDetails.has('dev-1::%1'), true);
  assert.equal(dm._sessionDetails.has('dev-1::%2'), true);

  // 2. Next listing where %2 vanished
  dm._recordListingSessions('dev-1', {
    workspaces: [{
      cwd: '/home/user',
      sessions: [{ ref: '%1', name: 's1' }],
    }],
  });
  assert.equal(dm._sessionDetails.has('dev-1::%1'), true);
  assert.equal(dm._sessionDetails.has('dev-1::%2'), false, 'Vanished session %2 must be purged from _sessionDetails');

  // 3. Remove device dev-1 purges all its sessionDetails
  dm.removeDevice('dev-1');
  assert.equal(dm._sessionDetails.has('dev-1::%1'), false, 'Removing device must purge all its sessionDetails');
});

test('Issue #316: TerminalPane implements background disconnect and foreground recovery contract', async () => {
  const { readFile } = await import('node:fs/promises');
  const paneJsx = await readFile(new URL('../src/components/terminal/TerminalPane.jsx', import.meta.url), 'utf8');

  // 1. handleBinary 入口对非激活终端彻底断流
  assert.match(paneJsx, /if\s*\(!viewRef\.current\?\.isVisible\)\s*return;/);

  // 2. sendIfNeeded 拦截隐藏窗格的冗余 subscribe 发送
  assert.match(paneJsx, /if\s*\(view\s*&&\s*!view\.isVisible\)\s*\{[^}]*skipped:\s*'pane_hidden'/);

  // 3. 卸载或关闭窗格时退订清理
  assert.match(paneJsx, /clientRef\.current\?\.unsubscribe\(target\);/);

  // 4. 切回前台使用 visibility_resume 恢复订阅全量快照
  assert.match(paneJsx, /visibility_resume/);
  assert.match(paneJsx, /sendIfNeeded\(\{\s*type:\s*'subscribe'/);
});

test('Issue #316: UI-SPEC §6.2 documents all 4 memory convergence rulings', async () => {
  const { readFile } = await import('node:fs/promises');
  const spec = await readFile(new URL('../docs/UI-SPEC.md', import.meta.url), 'utf8');

  assert.match(spec, /2026-09-25（全域内存收敛：后台窗格退订断流、WebGL 显存彻底释放与图集防冲突，Issue #316）/);
  assert.match(spec, /后台窗格协议退订断流与前台快照原子重连/);
  assert.match(spec, /WEBGL_lose_context.*loseContext/);
  assert.match(spec, /阻断 LinkRenderLayer 2048 图集颠簸冲突/);
  assert.match(spec, /零拷贝游标隐藏与合成层清理/);
});


