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

function computedCols(container, term) {
  const cellW = (term.cols * 8) / term.cols;
  return Math.max(2, Math.floor(container.clientWidth / cellW));
}

test('H2: n=30 rapid 800↔400 within debounce locally reflows (pre-fix behaviour via immediate)', async () => {
  const { view, container, reports } = makeView();
  view.open();
  assert.equal(view.term.cols, 100);
  await sleep(GRID_DEBOUNCE_MS + 80);
  reports.length = 0;
  view.term.resizes.length = 0;
  view.term.torn = false;
  view.term._shrunk = false;

  let midCols = 0;
  for (let i = 0; i < N; i += 1) {
    container.clientWidth = i % 2 === 0 ? 400 : 800;
    const want = computedCols(container, view.term);
    if (want !== 100 && want !== 50) midCols += 1;
    view.fit({ immediate: true });
  }
  container.clientWidth = 800;
  view.fit({ immediate: true });
  await sleep(GRID_DEBOUNCE_MS + 80);

  const h1 = { midCols, note: 'cell.w tracks term.cols*8 so computed cols only 100 or 50, not a third value' };
  const lastReport = reports[reports.length - 1];
  const serverNoop = lastReport && lastReport[0] === 25 && lastReport[1] === 100;
  assert.equal(view.term.torn, true, 'immediate fit: shrink-then-grow tears local grid');
  assert.equal(h1.midCols, 0, 'H1 falsified for synced cell probe: no transitional third cols');
  assert.equal(serverNoop, true, 'settled report is original 25x100 → daemon resize no-op');
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

test('settled new width still resizes once after debounce', async () => {
  const { view, container, reports } = makeView();
  view.open();
  await sleep(GRID_DEBOUNCE_MS + 80);
  reports.length = 0;
  container.clientWidth = 400;
  view.fit();
  assert.equal(view.term.cols, 100, 'not yet');
  await sleep(GRID_DEBOUNCE_MS + 80);
  assert.equal(view.term.cols, 50);
  assert.deepEqual(reports, [[25, 50]]);
  view.dispose();
});
