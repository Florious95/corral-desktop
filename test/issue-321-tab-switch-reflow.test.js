import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
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
    this.resizes = [];
    this.resets = 0;
    this.refreshes = [];
    this.clearedAtlasCount = 0;
    this._core = {
      _renderService: {
        _isPaused: false,
        _pausedResizeTask: {
          flushed: 0,
          flush() { this.flushed++; },
        },
      },
    };
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
  reset() {
    this.resets++;
  }
  resize(cols, rows) {
    this.cols = cols;
    this.rows = rows;
    this.resizes.push({ cols, rows });
  }
  refresh(start, end) {
    this.refreshes.push({ start, end });
  }
  clearTextureAtlas() {
    this.clearedAtlasCount++;
  }
  write(d) { this.writes.push(d); }
  focus() {}
  blur() {}
  dispose() {
    this._disposed = true;
  }
}

function createMockWebglImporter() {
  class MockWebglAddon {
    constructor() {
      this._renderer = {
        _gl: {
          getExtension: () => ({ loseContext: () => {} }),
        },
        _canvas: new FakeElement('canvas'),
        _renderLayers: [],
        _glyphRenderer: {
          value: {
            _lastSeenPageLayoutVersion: 5,
            invalidated: 0,
            invalidateAtlasTextures() { this.invalidated++; },
          },
        },
        clearedModels: [],
        _clearModel(clearVertices) {
          this.clearedModels.push(clearVertices);
        },
      };
      this._renderer._canvas.clientWidth = 800;
      this._renderer._canvas.clientHeight = 600;
    }
    activate(terminal) {
      terminal.element.appendChild(this._renderer._canvas);
    }
    onContextLoss() {}
    dispose() {
      if (this._renderer._canvas.parentElement) {
        this._renderer._canvas.parentElement.removeChild(this._renderer._canvas);
      }
    }
  }
  return {
    importer: async () => ({ WebglAddon: MockWebglAddon }),
  };
}

test('Issue #321: attachWebgl obeys isFitCurrent and does NOT force fit or trigger term.resize / term.reset', async () => {
  const container = new FakeElement('div');
  const { importer } = createMockWebglImporter();

  let onResizeCount = 0;
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminalForWebgl,
    webglImporter: importer,
    isVisible: true,
    onResize: () => {
      onResizeCount++;
    },
  });
  view.open();
  await view.readyWebgl;

  // 此时初次 fit 完成，记录当前 reset/resize 次数
  const initialResizes = view.term.resizes.length;
  const initialResets = view.term.resets;

  // 模拟切入后台
  view.setVisible(false);
  assert.equal(view.isVisible, false);

  // 模拟切回前台并重新 attachWebgl
  view.setVisible(true);
  await view.attachWebgl();

  // 严格断言：在容器尺寸未发生实际改变时，attachWebgl 绝不得调用 term.reset() 与 term.resize()，零颠簸！
  assert.equal(view.term.resets, initialResets, 'attachWebgl must not call term.reset() on Tab switch');
  assert.equal(view.term.resizes.length, initialResizes, 'attachWebgl must not call term.resize() on Tab switch');
  assert.equal(onResizeCount, 1, 'attachWebgl must not trigger extra onResize callbacks on Tab switch');

  view.dispose();
});

test('Issue #321: switching back to foreground unpauses RenderService, invalidates WebGL model and refreshes all rows (0..rows-1) so static content is never blank', async () => {
  const container = new FakeElement('div');
  const { importer } = createMockWebglImporter();

  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminalForWebgl,
    webglImporter: importer,
    isVisible: true,
  });
  view.open();
  await view.readyWebgl;

  // 写入静态快照内容
  view.writeSnapshot(new Uint8Array([65, 66, 67]));
  assert.equal(view.hasPainted, true);

  // 模拟切入后台：content-visibility: hidden 导致 IntersectionObserver 将 _renderService._isPaused 置为 true
  view.setVisible(false);
  view.term._core._renderService._isPaused = true;
  view.term.refreshes.length = 0;

  // 模拟切回前台
  view.setVisible(true);
  const addon = await view.attachWebgl();

  // 1. _renderService._isPaused 必须被立即解除并冲刷 _pausedResizeTask
  assert.equal(view.term._core._renderService._isPaused, false, 'RenderService._isPaused must be cleared on visibility restore');
  assert.ok(view.term._core._renderService._pausedResizeTask.flushed >= 1, '_pausedResizeTask must be flushed');

  // 2. 新挂载的 WebGL 渲染器必须强制标记模型为脏（_lastSeenPageLayoutVersion = -1 且 _clearModel(true)），且不清空多窗格共享的 CharAtlas
  assert.equal(addon._renderer._glyphRenderer.value._lastSeenPageLayoutVersion, -1);
  assert.ok(addon._renderer._glyphRenderer.value.invalidated >= 1);
  assert.ok(addon._renderer.clearedModels.includes(true));
  assert.equal(view.term.clearedAtlasCount, 0, 'attachWebgl must not wipe shared CharAtlas across split panes');

  // 3. 必须无条件调用 term.refresh(0, rows - 1) 刷新整屏所有静态与动态行
  assert.ok(view.term.refreshes.length >= 1, 'term.refresh must be called unconditionally on WebGL re-attach');
  const lastRefresh = view.term.refreshes.at(-1);
  assert.deepEqual(lastRefresh, { start: 0, end: view.term.rows - 1 });

  view.dispose();
});

test('Issue #321: TerminalPane and SplitPanes source code contract guarantees zero reflow, background frame buffering and full static content restore on tab switch', async () => {
  const [paneJsx, splitJsx, terminalViewJs] = await Promise.all([
    readFile(new URL('../src/components/terminal/TerminalPane.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/components/terminal/SplitPanes.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/term/TerminalView.js', import.meta.url), 'utf8'),
  ]);

  // 1. TerminalView.attachWebgl 杜绝 force: true，且无条件调用 refreshViewport 强制整屏刷新
  assert.doesNotMatch(terminalViewJs, /attachWebgl[\s\S]*?fit\(\{\s*immediate:\s*true,\s*force:\s*true\s*\}\)/);
  assert.match(terminalViewJs, /if\s*\(!this\.isFitCurrent\(\)\)\s*\{/);
  assert.match(terminalViewJs, /refreshViewport\(\)\s*\{/);
  assert.match(terminalViewJs, /this\.term\.refresh\?\.\(0,\s*endRow\)/);

  // 2. TerminalPane 切入后台不执行退订（保留常驻订阅），暂存后台帧并在切回前台时无损冲刷恢复
  assert.doesNotMatch(paneJsx, /syncVisibility = \(visible\) => \{[\s\S]*?clientRef\.current\?\.unsubscribe[\s\S]*?mo = new MutationObserver/);
  assert.match(paneJsx, /if\s*\(!viewRef\.current\?\.isVisible\)\s*enqueueBackgroundFrame\(frame\);/);
  assert.match(paneJsx, /if\s*\(!viewRef\.current\?\.isVisible\)\s*return;/);
  assert.match(paneJsx, /flushBackgroundFrames\(\);/);
  assert.match(paneJsx, /if\s*\(grid\s*&&\s*!lastSubscribe\)\s*\{/);

  // 3. ResizeObserver 与 handleLayoutSettled 均检查 !view.isVisible，防止 useLayoutEffect 阶段提前触发 reset 而丢弃 subscribe
  assert.match(paneJsx, /if\s*\(!view\.isVisible\)\s*return;/);
  assert.match(paneJsx, /\|\|\s*!view\.isVisible\s*\|\|\s*host\.closest\('\.is-hidden'\)/);

  // 4. SplitPanes 显式透传 isVisible 给 renderPane
  assert.match(splitJsx, /renderPane\(agent,\s*\{[^}]*isVisible/);
});
