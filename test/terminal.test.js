/*
 * TerminalView 的两条必须保留的行为（CLIENT-CONTRACT §1.3/§1.4）：
 *   ① resize 上报做 120ms 合并 —— 服务端每次真 reflow 都补一帧 snapshot，不合并会闪烁重画；
 *   ② 视口滚到顶（line<=0 且上次 >0）触发拉更早历史。
 * 外加只读历史面板的 ANSI 解析。
 *
 * xterm 用注入的 FakeTerminal 替身（TerminalView 的 TerminalCtor 选项），容器也是纯对象 ——
 * 不需要 jsdom，`node --test` 直接跑。
 */

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { TerminalView, inferSnapshotWidth } from '../src/term/TerminalView.js';
import { parseAnsi } from '../src/components/terminal/ansi.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 单元格 8×16px 的假终端。 */
class FakeTerminal {
  constructor(opts) {
    this.opts = opts;
    this.cols = 80;
    this.rows = 24;
    this.writes = [];
    this.resets = 0;
    this.scrollHandlers = [];
    this.dataHandlers = [];
    this.keyHandler = null;
    this.buffer = { active: { viewportY: 0 } };
    this.element = {
      querySelector: () => ({
        getBoundingClientRect: () => ({ width: this.cols * 8, height: this.rows * 16 }),
      }),
    };
  }
  open() {}
  onScroll(cb) { this.scrollHandlers.push(cb); return { dispose: () => {} } }
  onData(cb) { this.dataHandlers.push(cb); return { dispose: () => {} } }
  attachCustomKeyEventHandler(fn) { this.keyHandler = fn; return true }
  emitScroll(line) { for (const cb of this.scrollHandlers) cb(line) }
  emitData(s) { for (const cb of this.dataHandlers) cb(s) }
  resize(cols, rows) { this.cols = cols; this.rows = rows }
  reset() { this.resets += 1 }
  write(data) { this.writes.push(data) }
  focused = false;
  focus() { this.focused = true }
  blur() { this.focused = false }
  scrollToBottom() {}
  dispose() {}
}

function makeView(overrides = {}) {
  const wheelHandlers = [];
  const container = {
    isConnected: true,
    clientWidth: 800,
    clientHeight: 400,
    addEventListener: (type, fn) => { if (type === 'wheel') wheelHandlers.push(fn) },
    removeEventListener: () => {},
  };
  const calls = { resize: [], history: 0 };
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminal,
    onResize: (rows, cols) => calls.resize.push([rows, cols]),
    onHistoryBoundary: () => { calls.history += 1 },
    ...overrides,
  });
  return { view, container, calls, wheel: (deltaY) => wheelHandlers.forEach((fn) => fn({ deltaY })) };
}

test('resize 上报合并成一次：连续 fit 只回调最终几何', async () => {
  const { view, container, calls } = makeView();
  view.open();                                  // 800/8=100 列, 400/16=25 行
  assert.deepEqual(view.term.cols, 100);
  assert.deepEqual(view.term.rows, 25);

  container.clientWidth = 640;                  // 80 列
  view.fit();
  container.clientHeight = 320;                 // 20 行
  view.fit();
  assert.equal(calls.resize.length, 0, '120ms 之内不应上报');

  await sleep(200);
  assert.deepEqual(calls.resize, [[20, 80]], '合并后只上报一次最终 rows/cols');
  view.dispose();
});

test('几何没变不上报', async () => {
  const { view, calls } = makeView();
  view.open();
  await sleep(200);
  calls.resize.length = 0;
  view.fit();
  await sleep(200);
  assert.deepEqual(calls.resize, []);
  view.dispose();
});

test('滚到顶触发拉历史；停在顶部不重复触发', () => {
  const { view, calls } = makeView();
  view.open();
  view.term.emitScroll(5);
  assert.equal(calls.history, 0);
  view.term.emitScroll(0);
  assert.equal(calls.history, 1);
  view.term.emitScroll(0);                      // 上次已是 0，不再触发
  assert.equal(calls.history, 1);
  view.dispose();
});

test('顶部上滚滚轮触发拉历史（scrollback=0 时 onScroll 永不触发）', () => {
  const { view, calls, wheel } = makeView();
  view.open();
  wheel(50);                                    // 向下滚：不管
  assert.equal(calls.history, 0);
  wheel(-50);
  assert.equal(calls.history, 1);
  wheel(-50);                                   // 400ms 节流内
  assert.equal(calls.history, 1);
  view.term.buffer.active.viewportY = 3;        // 还能本地往上滚就先滚本地
  view.dispose();
});

test('snapshot 清屏重建、delta 追加，字节原样不动', () => {
  const { view } = makeView();
  view.open();
  const snap = new Uint8Array([0x41, 0x1b, 0x5b, 0x31, 0x3b, 0x31, 0x48]);
  view.writeSnapshot(snap);
  assert.equal(view.term.resets, 1);
  assert.equal(view.term.writes[0], snap, '整段原样喂给 xterm，不 trim、不按行拆');
  view.writeDelta(new Uint8Array([0x42]));
  assert.equal(view.term.resets, 1);
  assert.equal(view.term.writes.length, 2);
  view.dispose();
});

test('parseAnsi 只解 SGR，其余 ESC 吞掉', () => {
  const segs = parseAnsi('\x1b[31mred\x1b[0mplain\x1b[2Jgone');
  assert.deepEqual(segs.map((s) => s.text), ['red', 'plaingone']);
  assert.equal(segs[0].fg, '#c0392b');
  assert.equal(segs[1].fg, null);
});

test('parseAnsi 不生成标记，尖括号原样留在片段文本里', () => {
  const segs = parseAnsi('<script> & "x"');
  assert.equal(segs.length, 1);
  assert.equal(segs[0].text, '<script> & "x"');   // React 渲染片段自带转义，不需要预转义
});

test('焦点列实心闪烁、失焦列空心：cursorBlink + outline inactive + focus/blur', () => {
  const { view } = makeView();
  view.open();
  assert.equal(view.term.opts.cursorBlink, true);
  assert.equal(view.term.opts.cursorStyle, 'block');
  assert.equal(view.term.opts.cursorInactiveStyle, 'outline');
  view.focus();
  assert.equal(view.term.focused, true);
  view.blur();
  assert.equal(view.term.focused, false);
  view.dispose();
});

test('onData 把按键交给调用方；disableStdin 为 false', () => {
  const got = [];
  const { view } = makeView({ onData: (d) => got.push(d) });
  view.open();
  assert.equal(view.term.opts.disableStdin, false);
  view.term.emitData('x');
  assert.deepEqual(got, ['x']);
  view.dispose();
});

// ——— 宽主机模式（minCols） ———

test('setMinCols 让 fit() 不缩到容器列数以下', () => {
  const { view, container } = makeView();
  view.open();  // 800px / 8px = 100 cols
  assert.equal(view.term.cols, 100);
  assert.equal(view.containerCols, 100);

  // 主机 235 列：设 minCols
  view.setMinCols(235);
  assert.equal(view.term.cols, 235, 'xterm 扩到主机宽度');
  assert.equal(view.containerCols, 100, 'containerCols 仍反映容器像素');

  // 容器缩窄：minCols 继续兜底
  container.clientWidth = 480;  // 60 cols
  view.fit({ immediate: true });
  assert.equal(view.term.cols, 235, '容器缩到 60 列时 minCols=235 仍生效');
  assert.equal(view.containerCols, 60);
  view.dispose();
});

test('clearMinCols 回到容器像素列数', () => {
  const { view, container } = makeView();
  view.open();  // 100 cols
  view.setMinCols(235);
  assert.equal(view.term.cols, 235);

  view.clearMinCols();
  assert.equal(view.term.cols, 100, '清除后回到容器列数');
  assert.equal(view._minCols, 0);
  view.dispose();
});

test('容器变宽超过 minCols 时自然接管', () => {
  const { view, container } = makeView();
  view.open();  // 100 cols
  view.setMinCols(150);
  assert.equal(view.term.cols, 150);

  // 容器变宽到 200 cols：超过 minCols，自然接管
  container.clientWidth = 1600;  // 1600/8 = 200 cols
  view.fit({ immediate: true });
  assert.equal(view.term.cols, 200, '容器变宽后 effective = max(200, 150) = 200');
  assert.equal(view.containerCols, 200);
  view.dispose();
});

test('minCols 不影响 onResize 上报的 cols', async () => {
  const { view, container, calls } = makeView();
  view.open();  // 100 cols, 25 rows
  await sleep(200);
  calls.resize.length = 0;

  view.setMinCols(235);
  assert.equal(view.term.cols, 235);
  await sleep(200);            // 让 setMinCols 的 report 落定
  calls.resize.length = 0;     // 清掉 setMinCols 触发的上报

  // 容器缩窄：effective 仍 235（minCols 兜底），不应重复上报
  container.clientWidth = 560;  // 70 cols
  view.fit();
  await sleep(200);
  assert.deepEqual(calls.resize, [], 'effective cols 未变不上报');

  // 容器变宽超过 minCols：effective = 300，应上报新几何
  container.clientWidth = 2400;  // 300 cols
  view.fit();
  await sleep(200);
  assert.equal(calls.resize.length, 1, '容器变宽超过 minCols 应上报新几何');
  assert.deepEqual(calls.resize[0], [25, 300]);
  view.dispose();
});

// ——— inferSnapshotWidth ———

test('inferSnapshotWidth: CUP 序列取最大列', () => {
  // ESC[1;1H ESC[2;1H ESC[1;235H
  const bytes = new Uint8Array([
    0x1b, 0x5b, 0x31, 0x3b, 0x31, 0x48, // ESC[1;1H
    0x41,                                 // 'A'
    0x1b, 0x5b, 0x32, 0x3b, 0x31, 0x48, // ESC[2;1H
    0x42,                                 // 'B'
    0x1b, 0x5b, 0x31, 0x3b, 0x32, 0x33, 0x35, 0x48, // ESC[1;235H
  ]);
  assert.equal(inferSnapshotWidth(bytes), 235);
});

test('inferSnapshotWidth: CHA 序列也算', () => {
  // ESC[100G (CHA to col 100)
  const bytes = new Uint8Array([
    0x1b, 0x5b, 0x31, 0x30, 0x30, 0x47, // ESC[100G
  ]);
  assert.equal(inferSnapshotWidth(bytes), 100);
});

test('inferSnapshotWidth: 无 CSI 序列返回 0', () => {
  const bytes = new Uint8Array([0x41, 0x42, 0x43]); // plain text
  assert.equal(inferSnapshotWidth(bytes), 0);
});

test('inferSnapshotWidth: 空/null 安全', () => {
  assert.equal(inferSnapshotWidth(null), 0);
  assert.equal(inferSnapshotWidth(new Uint8Array([])), 0);
});

// ——— markReported ———

test('markReported 吞掉紧跟 subscribe 的重复 fit 上报', async () => {
  const { view, container, calls } = makeView();
  view.open();
  await sleep(200);
  calls.resize.length = 0;

  // 模拟 subscribe 后调 markReported
  view.markReported();

  // WebGL fit 触发（容器没变）：不应上报
  container.clientWidth = 800; // 同尺寸
  view.fit({ immediate: true });
  await sleep(200);
  assert.deepEqual(calls.resize, [], 'markReported 后第一次 fit 不上报');

  // 真正容器变化：应上报
  container.clientWidth = 640; // 80 cols
  view.fit();
  await sleep(200);
  assert.equal(calls.resize.length, 1, '后续变化正常上报');
  view.dispose();
});

// ——— 宽快照后再来窄快照才允许缩 ———

test('setMinCols 扩后 clearMinCols 缩（模拟宽快照→窄快照时序）', () => {
  const { view, container } = makeView();
  view.open(); // 100 cols
  assert.equal(view.term.cols, 100);

  // 宽快照到达：扩到 235
  view.setMinCols(235);
  assert.equal(view.term.cols, 235, '扩到快照宽度');

  // 窄快照到达（主机缩回 100）：clearMinCols 安全缩回
  view.clearMinCols();
  assert.equal(view.term.cols, 100, '匹配快照到达后安全缩回');
  view.dispose();
});
