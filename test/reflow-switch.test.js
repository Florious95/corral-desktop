/*
 * Rapid column-width switching (n≥30). Machine-readable torn = shrink-then-grow
 * of the local xterm grid without a matching snapshot refresh.
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TerminalView, GRID_DEBOUNCE_MS } from '../src/term/TerminalView.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const N = 30;

class FakeTerminal {
  constructor() {
    this.cols = 80;
    this.rows = 24;
    this.resizes = [];
    this.torn = false;
    this._shrunk = false;
    this.buffer = { active: { viewportY: 0 } };
    this.element = {
      querySelector: () => ({
        getBoundingClientRect: () => ({ width: this.cols * 8, height: this.rows * 16 }),
      }),
    };
  }
  open() {}
  onScroll() { return { dispose() {} }; }
  onData() { return { dispose() {} }; }
  attachCustomKeyEventHandler() { return true; }
  resize(cols, rows) {
    if (cols < this.cols) this._shrunk = true;
    if (cols > this.cols && this._shrunk) this.torn = true;
    this.resizes.push([rows, cols]);
    this.cols = cols;
    this.rows = rows;
  }
  reset() {}
  write() {}
  focus() {}
  blur() {}
  scrollToBottom() {}
  dispose() {}
}

function makeView() {
  const container = {
    isConnected: true,
    clientWidth: 800,
    clientHeight: 400,
    scrollHeight: 400,
    scrollTop: 0,
    style: {},
    addEventListener() {},
    removeEventListener() {},
  };
  const reports = [];
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminal,
    onResize: (rows, cols) => reports.push([rows, cols]),
  });
  return { view, container, reports };
}

test('H2: n=30 rapid 800↔400 even with immediate does not tear (grid locked after seed)', async () => {
  const { view, container, reports } = makeView();
  view.open();
  assert.equal(view.term.cols, 100);
  await sleep(GRID_DEBOUNCE_MS + 80);
  reports.length = 0;
  view.term.resizes.length = 0;
  view.term.torn = false;
  view.term._shrunk = false;

  for (let i = 0; i < N; i += 1) {
    container.clientWidth = i % 2 === 0 ? 400 : 800;
    view.fit({ immediate: true });
  }
  container.clientWidth = 800;
  view.fit({ immediate: true });
  await sleep(GRID_DEBOUNCE_MS + 80);

  assert.equal(view.term.cols, 100);
  assert.equal(view.term.torn, false);
  assert.deepEqual(view.term.resizes, []);
  assert.deepEqual(reports, []);
  view.dispose();
});

test('H2 good: n=30 same script with default (debounced) fit — zero local reflow, zero torn', async () => {
  const { view, container, reports } = makeView();
  view.open();
  await sleep(GRID_DEBOUNCE_MS + 80);
  reports.length = 0;
  view.term.resizes.length = 0;
  view.term.torn = false;
  view.term._shrunk = false;
  const startCols = view.term.cols;

  for (let i = 0; i < N; i += 1) {
    container.clientWidth = i % 2 === 0 ? 400 : 800;
    view.fit();
    await sleep(40);
  }
  container.clientWidth = 800;
  view.fit();
  await sleep(GRID_DEBOUNCE_MS + 80);

  assert.equal(view.term.cols, startCols);
  assert.equal(view.term.torn, false);
  assert.deepEqual(view.term.resizes, []);
  assert.deepEqual(reports, []);
  view.dispose();
});

test('settled narrower width does not resize after seed (squeeze only)', async () => {
  const { view, container, reports } = makeView();
  view.open();
  await sleep(GRID_DEBOUNCE_MS + 80);
  reports.length = 0;
  container.clientWidth = 400;
  container.scrollHeight = 400;
  view.fit();
  await sleep(GRID_DEBOUNCE_MS + 80);
  assert.equal(view.term.cols, 100);
  assert.deepEqual(reports, []);
  assert.equal(view._layout.visibleRows, 25);
  assert.equal(view._layout.overflowX, true);
  assert.equal(container.style.overflow, 'auto');
  view.dispose();
});
