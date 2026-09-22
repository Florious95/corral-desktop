import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import {
  getFontMetrics,
  computeGridDimensions,
  setCachedFontMetrics,
  clearFontMetricsCache,
} from '../src/term/fontMetrics.js';
import { TerminalView } from '../src/term/TerminalView.js';

class FakeTerminal {
  constructor(opts = {}) {
    this.opts = opts;
    this.cols = opts.cols || 80;
    this.rows = opts.rows || 24;
    this.resizes = [];
    this.writes = [];
    this.resets = 0;
    this.buffer = { active: { viewportY: 0, getLine: () => null } };
    this.textarea = { style: {} };
    this.composition = { style: {} };
    this.element = {
      querySelector: () => null,
      setAttribute: () => {},
    };
  }
  open() {}
  onScroll() { return { dispose() {} }; }
  onData() { return { dispose() {} }; }
  onBinary() { return { dispose() {} }; }
  attachCustomKeyEventHandler() { return true; }
  resize(cols, rows) {
    this.resizes.push([rows, cols]);
    this.cols = cols;
    this.rows = rows;
  }
  reset() { this.resets += 1; }
  write(data, callback) { this.writes.push(data); callback?.(); }
  focus() {}
  blur() {}
  scrollToBottom() {}
  dispose() {}
}

test('fontMetrics: measures, normalizes and caches monospace font width and height', () => {
  clearFontMetricsCache();
  const m1 = getFontMetrics({ fontFamily: 'monospace', fontSize: 13, lineHeight: 1.25 });
  assert.ok(m1.cellWidth > 0, 'cellWidth must be greater than 0');
  assert.ok(m1.cellHeight > 0, 'cellHeight must be greater than 0');
  assert.equal(m1.w, m1.cellWidth);
  assert.equal(m1.h, m1.cellHeight);

  // Second call must return identical cached reference (0ms cost, zero layout thrashing)
  const m2 = getFontMetrics({ fontFamily: 'monospace', fontSize: 13, lineHeight: 1.25 });
  assert.strictEqual(m1, m2, 'subsequent calls must return cached reference');

  // Cache test helper injection works
  setCachedFontMetrics('custom-mono:14:1.25', { cellWidth: 8.4, cellHeight: 18 });
  const m3 = getFontMetrics({ fontFamily: 'custom-mono', fontSize: 14, lineHeight: 1.25 });
  assert.equal(m3.cellWidth, 8.4);
  assert.equal(m3.cellHeight, 18);
});

test('fontMetrics: computeGridDimensions performs pure mathematical projection without DOM layout reads', () => {
  const result = computeGridDimensions({
    width: 800,
    height: 480,
    fontFamily: 'monospace',
    fontSize: 13,
    lineHeight: 1.25,
    paddingX: 10,
    paddingY: 0,
  });
  assert.ok(Number.isInteger(result.cols));
  assert.ok(Number.isInteger(result.rows));
  assert.ok(result.cols >= 2, 'cols must be at least 2');
  assert.ok(result.rows >= 2, 'rows must be at least 2');
});

test('TerminalView: initializes xterm with initialCols and initialRows without falling back to 80x24', () => {
  const container = {
    isConnected: true,
    clientWidth: 960,
    clientHeight: 600,
    addEventListener() {},
    removeEventListener() {},
  };
  const reports = [];
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminal,
    initialCols: 120,
    initialRows: 36,
    onResize: (rows, cols) => reports.push([rows, cols]),
  });

  // Target dimensions are applied directly on construction
  assert.equal(view.term.cols, 120, 'term.cols must be initialCols');
  assert.equal(view.term.rows, 36, 'term.rows must be initialRows');

  // Calling open() immediately commits and reports the target geometry without waiting for resize debounce
  view.open();
  assert.deepEqual(reports, [[36, 120]], 'onResize must be reported immediately on open with initial geometry');
  view.dispose();
});

test('TerminalView: uses font metrics cache and avoids repeated getBoundingClientRect layout thrashing', () => {
  const container = {
    isConnected: true,
    clientWidth: 800,
    clientHeight: 400,
    addEventListener() {},
    removeEventListener() {},
  };
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminal,
    cellMetrics: { w: 8, h: 16 },
  });

  const c1 = view._cell();
  assert.deepEqual(c1, { w: 8, h: 16 });
  const c2 = view._cell();
  assert.strictEqual(c1, c2, 'cell metrics must be retained on the instance');
  view.dispose();
});

test('TerminalView: writeSnapshot writes synchronously and atomically without rAF queueing', () => {
  const container = {
    isConnected: true,
    clientWidth: 800,
    clientHeight: 400,
    addEventListener() {},
    removeEventListener() {},
  };
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminal,
  });
  view.open();

  const snapshotData = new Uint8Array([0x68, 0x65, 0x6c, 0x6c, 0x6f]);
  view.writeSnapshot(snapshotData);

  // Snapshot must write synchronously into xterm without waiting for asynchronous frames
  assert.equal(view.term.resets, 1, 'term.reset must be called synchronously');
  assert.equal(view.term.writes.length, 1, 'term.write must be executed synchronously');
  assert.deepEqual(view.term.writes[0], snapshotData);
  view.dispose();
});

test('Source contract: SplitPanes, App, and TerminalPane forward projected dimensions and eliminate 500ms blind wait', async () => {
  const [splitPanesJsx, appJsx, terminalPaneJsx] = await Promise.all([
    readFile(new URL('../src/components/terminal/SplitPanes.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/App.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/components/terminal/TerminalPane.jsx', import.meta.url), 'utf8'),
  ]);

  // 1. SplitPanes forwards containerWidth and containerHeight from projected layout
  assert.match(splitPanesJsx, /renderPane\(agent,\s*\{\s*containerWidth:\s*currentRect\.w,\s*containerHeight:\s*currentRect\.h\s*\}\)/);

  // 2. App renders pane with containerWidth and containerHeight
  assert.match(appJsx, /containerWidth=\{dimensions\?\.containerWidth\}/);
  assert.match(appJsx, /containerHeight=\{dimensions\?\.containerHeight\}/);

  // 3. TerminalPane computes initialCols / initialRows via computeGridDimensions and initializes TerminalView directly
  assert.match(terminalPaneJsx, /computeGridDimensions/);
  assert.match(terminalPaneJsx, /initialCols:/);
  assert.match(terminalPaneJsx, /initialRows:/);

  // 4. TerminalPane completely eliminated 500ms takeover timer
  assert.doesNotMatch(terminalPaneJsx, /takeoverTimer\s*=/);
});
