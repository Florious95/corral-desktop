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
  refresh() {}
  clearTextureAtlas() {}
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

test('Issue #321: TerminalPane and SplitPanes source code contract guarantees zero reflow on tab switch', async () => {
  const [paneJsx, splitJsx, terminalViewJs] = await Promise.all([
    readFile(new URL('../src/components/terminal/TerminalPane.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/components/terminal/SplitPanes.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/term/TerminalView.js', import.meta.url), 'utf8'),
  ]);

  // 1. TerminalView.attachWebgl 杜绝 force: true
  assert.doesNotMatch(terminalViewJs, /attachWebgl[\s\S]*?fit\(\{\s*immediate:\s*true,\s*force:\s*true\s*\}\)/);
  assert.match(terminalViewJs, /if\s*\(!this\.isFitCurrent\(\)\)\s*\{/);

  // 2. TerminalPane.visibility_resume 杜绝 force: true
  assert.doesNotMatch(paneJsx, /visibility_resume.*force:\s*true/);
  assert.match(paneJsx, /sendIfNeeded\(\{\s*type:\s*'subscribe',\s*rows:\s*grid\.rows,\s*cols:\s*grid\.cols\s*\},\s*'visibility_resume'\);/);

  // 3. SplitPanes 显式透传 isVisible 给 renderPane
  assert.match(splitJsx, /renderPane\(agent,\s*\{[^}]*isVisible/);
});
