import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { TerminalView } from '../src/term/TerminalView.js';

class MockElement {
  constructor() {
    this.style = {};
    this.children = [];
    this.isConnected = true;
    this.clientWidth = 800;
    this.clientHeight = 600;
  }
  appendChild(child) { this.children.push(child); }
  removeChild(child) {
    const idx = this.children.indexOf(child);
    if (idx !== -1) this.children.splice(idx, 1);
  }
  querySelector() { return null; }
  querySelectorAll() { return []; }
  addEventListener() {}
  removeEventListener() {}
  getBoundingClientRect() { return { width: 800, height: 600, top: 0, left: 0 }; }
}

class FakeTerminal {
  constructor(opts = {}) {
    this.opts = opts;
    this.cols = opts.cols || 80;
    this.rows = opts.rows || 24;
    this.element = new MockElement();
    this.textarea = new MockElement();
    this.buffer = {
      active: {
        cursorY: 0,
        cursorX: 0,
        viewportY: 0,
        getLine: () => null,
      },
    };
  }
  open() {}
  onScroll() { return { dispose() {} }; }
  onData() { return { dispose() {} }; }
  onBinary() { return { dispose() {} }; }
  onCursorMove() { return { dispose() {} }; }
  onRender() { return { dispose() {} }; }
  write() {}
  reset() {}
  resize(cols, rows) { this.cols = cols; this.rows = rows; }
  focus() {}
  blur() {}
  dispose() {}
}

test('macOS GPU Idle: TerminalView strictly sets cursorBlink: false to eliminate 600ms WebGL render loop', () => {
  const container = new MockElement();
  const view = new TerminalView(container, { TerminalCtor: FakeTerminal });
  assert.equal(view.term.opts.cursorBlink, false, 'cursorBlink must be false to prevent WebglAddon CursorBlinkStateManager setInterval');
  view.dispose();
});

test('macOS GPU Idle: TerminalView preserves cursorBlink: false under hideCursor: true', () => {
  const container = new MockElement();
  const view = new TerminalView(container, { hideCursor: true, TerminalCtor: FakeTerminal });
  assert.equal(view.term.opts.cursorBlink, false);
  view.dispose();
});

test('macOS GPU Idle: chrome.css .tb-tab-lamp.is-working has static glow and no infinite animations', async () => {
  const css = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');
  assert.match(css, /\.tb-tab-lamp\.is-working\s*\{[^}]*box-shadow:\s*0 0 6px var\(--green-ring\);/);
  assert.equal(
    /\.tb-tab-lamp\.is-working\s*\{[^}]*animation:[^;]*infinite/.test(css),
    false,
    '.tb-tab-lamp.is-working must not use infinite animation',
  );
  assert.equal(
    css.includes('@keyframes tb-lamp-pulse'),
    false,
    '@keyframes tb-lamp-pulse must be cleanly removed',
  );
});

test('macOS GPU Idle: sidebar.css .agents-dot has static glow and no infinite animations', async () => {
  const css = await readFile(new URL('../src/components/sidebar/sidebar.css', import.meta.url), 'utf8');
  assert.match(css, /\.agents-dot\.is-working\s*\{[^}]*box-shadow:\s*0 0 6px var\(--green-ring\);/);
  assert.match(css, /\.agents-dot\.is-blocked\s*\{[^}]*box-shadow:\s*0 0 6px var\(--amber-ring\);/);
  assert.equal(
    /\.agents-dot\.(is-working|is-blocked)\s*\{[^}]*animation:[^;]*infinite/.test(css),
    false,
    '.agents-dot must not use infinite animation',
  );
});

test('macOS GPU Idle: sidebar.css .spaces-dot has static glow and no infinite animations', async () => {
  const css = await readFile(new URL('../src/components/sidebar/sidebar.css', import.meta.url), 'utf8');
  assert.match(css, /\.spaces-dot\.is-working\s*\{[^}]*box-shadow:\s*0 0 5px var\(--green-ring\);/);
  assert.match(css, /\.spaces-dot\.is-blocked\s*\{[^}]*box-shadow:\s*0 0 5px var\(--amber-ring\);/);
  assert.equal(
    /\.spaces-dot\.(is-working|is-blocked)\s*\{[^}]*animation:[^;]*infinite/.test(css),
    false,
    '.spaces-dot must not use infinite animation',
  );
});

test('macOS GPU Idle: UI-SPEC.md documents 2026-09-24 GPU idle rulings', async () => {
  const spec = await readFile(new URL('../docs/UI-SPEC.md', import.meta.url), 'utf8');
  assert.match(spec, /2026-09-24 裁定，macOS GPU 降载与消除无限合成/);
  assert.match(spec, /cursorBlink:false[`'"]?[（(]严格关闭闪烁，彻底消除 WebGL 600ms 定时器空转重绘/);
});
