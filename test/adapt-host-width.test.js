/*
 * adaptToHostWidth: 主机 pane 比本地列宽时（tmux 未跟随我方 resize），
 * 缩小字号使 xterm 格子匹配主机宽度，避免折行撕开。
 *
 * 验证点：
 *   1. 主机比本地宽 → 适配（字号缩小、格子扩到主机宽度）
 *   2. 主机不比本地宽 → 不适配
 *   3. 适配后容器变宽 → 字号相应放大（保持主机宽度）
 *   4. 适配后容器太窄（字号 < MIN）→ 回退正常 fit
 *   5. clearAdaptation → 恢复默认字号
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TerminalView, MIN_ADAPT_FONT_SIZE } from '../src/term/TerminalView.js';

/**
 * 单元格 8×16px 的假终端。cell width = cols*8 / cols = 8px (for the initial grid),
 * 所以 800px 容器 → 100 列。
 */
class FakeTerminal {
  constructor(opts) {
    this.opts = opts;
    this.options = { ...opts };
    this.cols = 80;
    this.rows = 24;
    this.writes = [];
    this.resets = 0;
    this.resizes = [];
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
  resize(cols, rows) { this.resizes.push([cols, rows]); this.cols = cols; this.rows = rows; }
  reset() { this.resets += 1; }
  write(data) { this.writes.push(data); }
  focus() {}
  blur() {}
  scrollToBottom() {}
  dispose() {}
}

function makeView(containerW = 800, containerH = 400) {
  const container = {
    isConnected: true,
    clientWidth: containerW,
    clientHeight: containerH,
    addEventListener() {},
    removeEventListener() {},
  };
  const reports = [];
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminal,
    onResize: (rows, cols) => reports.push([rows, cols]),
  });
  view.open();
  return { view, container, reports };
}

test('主机 150 列 > 本地 100 列 → 适配：字号缩小、格子扩到 150', () => {
  const { view } = makeView(800, 400);
  // 初始 fit：800/8=100 列
  assert.equal(view.term.cols, 100, `initial cols=100, got ${view.term.cols}`);
  assert.equal(view._adaptedHostCols, 0, 'not adapted yet');

  const ok = view.adaptToHostWidth(150, 50);
  assert.equal(ok, true, 'adaptation should succeed');
  assert.equal(view.term.cols, 150, 'grid expanded to host width');
  assert.equal(view.term.rows, 50, 'grid rows set to host rows');
  assert.ok(view.fontSize < 13, `font shrank from 13 to ${view.fontSize}`);
  assert.ok(view.fontSize >= MIN_ADAPT_FONT_SIZE, `font above minimum: ${view.fontSize}`);
  assert.equal(view._adaptedHostCols, 150);
  view.dispose();
});

test('主机 80 列 ≤ 本地 100 列 → 不适配', () => {
  const { view } = makeView(800, 400);
  const ok = view.adaptToHostWidth(80, 24);
  assert.equal(ok, false, 'should not adapt when host is narrower');
  assert.equal(view._adaptedHostCols, 0);
  view.dispose();
});

test('主机 100 列 = 本地 100 列 → 不适配（等号不触发）', () => {
  const { view } = makeView(800, 400);
  const ok = view.adaptToHostWidth(100, 25);
  assert.equal(ok, false, 'equal width: no adaptation needed');
  view.dispose();
});

test('适配后容器变宽 → 字号放大，仍保持主机宽度', () => {
  const { view, container } = makeView(800, 400);
  view.adaptToHostWidth(150, 50);
  const fontAfterAdapt = view.fontSize;
  const colsAfterAdapt = view.term.cols;

  // 容器变宽到 1200px：1200/(150*0.6)=13.3 → 字号应放大
  container.clientWidth = 1200;
  view.fit();
  assert.equal(view.term.cols, colsAfterAdapt, `still at host width ${colsAfterAdapt}`);
  assert.ok(view.fontSize > fontAfterAdapt, `font grew: ${fontAfterAdapt} → ${view.fontSize}`);
  assert.equal(view._adaptedHostCols, 150, 'still in adapted mode');
  view.dispose();
});

test('适配后容器太窄（字号 < MIN）→ 回退正常 fit', () => {
  const { view, container } = makeView(800, 400);
  view.adaptToHostWidth(150, 50);
  assert.equal(view._adaptedHostCols, 150);
  const adaptedFont = view.fontSize;

  // 容器缩到 300px：300/(150*0.6)=3.3 < MIN(8) → 回退
  container.clientWidth = 300;
  container.clientHeight = 400;
  view.fit();
  assert.equal(view._adaptedHostCols, 0, 'adaptation cleared');
  assert.equal(view.fontSize, 13, 'font restored to default');
  assert.ok(view.term.cols < 150, `cols reverted below host width: ${view.term.cols}`);
  view.dispose();
});

test('clearAdaptation 恢复默认字号并重 fit', () => {
  const { view } = makeView(800, 400);
  view.adaptToHostWidth(150, 50);
  assert.ok(view.fontSize < 13, `font shrank to ${view.fontSize}`);

  view.clearAdaptation();
  assert.equal(view._adaptedHostCols, 0);
  assert.equal(view.fontSize, 13, 'font restored');
  assert.equal(view.term.cols, 100, `cols back to 100: got ${view.term.cols}`);
  view.dispose();
});

test('重复适配同一宽度 → 幂等（hostCols <= term.cols 后不再触发）', () => {
  const { view } = makeView(800, 400);
  view.adaptToHostWidth(150, 50);
  const font1 = view.fontSize;
  const cols1 = view.term.cols;

  // 再次适配同一宽度 → term.cols 已是 150, hostCols(150) <= 150 → no-op
  const ok = view.adaptToHostWidth(150, 50);
  assert.equal(ok, false, 'second adapt to same width is a no-op');
  assert.equal(view.fontSize, font1);
  assert.equal(view.term.cols, cols1);
  view.dispose();
});

test('适配到更宽 → 进一步缩小字号', () => {
  const { view } = makeView(1200, 400);
  // 初始：1200/8=150 列
  assert.equal(view.term.cols, 150);

  // 适配到 200 列：1200/(200*0.6)=10px ≥ 8
  const ok = view.adaptToHostWidth(200, 50);
  assert.equal(ok, true);
  assert.equal(view.term.cols, 200);
  assert.ok(view.fontSize < 13, `font shrank to ${view.fontSize}`);
  view.dispose();
});

test('MIN_ADAPT_FONT_SIZE 导出值合理', () => {
  assert.ok(MIN_ADAPT_FONT_SIZE >= 6, 'minimum should be readable');
  assert.ok(MIN_ADAPT_FONT_SIZE <= 12, 'minimum should not be the default');
});