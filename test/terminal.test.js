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

import { TerminalView } from '../src/term/TerminalView.js';
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
  focus() {}
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

test('onData 把按键交给调用方；disableStdin 为 false', () => {
  const got = [];
  const { view } = makeView({ onData: (d) => got.push(d) });
  view.open();
  assert.equal(view.term.opts.disableStdin, false);
  view.term.emitData('x');
  assert.deepEqual(got, ['x']);
  view.dispose();
});
