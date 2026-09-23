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
import { setNativeEngineForTests, resetNativeEngineForTests } from '../src/core/nativeCapabilities.js';
import { parseAnsi } from '../src/components/terminal/ansi.js';
import { TERMINAL_FONT_FAMILIES } from '../src/core/settings.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 单元格 8×16px 的假终端。 */
class FakeTerminal {
  constructor(opts) {
    this.opts = opts;
    this.options = { fontFamily: opts.fontFamily, fontSize: opts.fontSize };
    this._core = { _renderService: { dimensions: { css: { cell: { width: 8, height: 16 } } } } };
    this.cols = 80;
    this.rows = 24;
    this.writes = [];
    this.resets = 0;
    this.scrollHandlers = [];
    this.dataHandlers = [];
    this.binaryHandlers = [];
    this.keyHandler = null;
    this.buffer = { active: { viewportY: 0, getLine: () => null } };
    this.textarea = { style: {} };
    this.composition = { style: {} };
    this.element = {
      querySelector: (selector) => {
        if (selector === '.xterm-screen') {
          return { getBoundingClientRect: () => ({ width: this.cols * 8, height: this.rows * 16 }) };
        }
        if (selector === '.composition-view') return this.composition;
        return null;
      },
    };
  }
  open() {}
  onScroll(cb) { this.scrollHandlers.push(cb); return { dispose: () => {} } }
  onData(cb) { this.dataHandlers.push(cb); return { dispose: () => {} } }
  onBinary(cb) { this.binaryHandlers.push(cb); return { dispose: () => {} } }
  attachCustomKeyEventHandler(fn) { this.keyHandler = fn; return true }
  emitScroll(line) { for (const cb of this.scrollHandlers) cb(line) }
  emitData(s) { for (const cb of this.dataHandlers) cb(s) }
  emitBinary(s) { for (const cb of this.binaryHandlers) cb(s) }
  resize(cols, rows) { this.cols = cols; this.rows = rows }
  reset() { this.resets += 1 }
  write(data, callback) { this.writes.push(data); callback?.(); }
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

test('native terminal rows have no extra leading and fallback grid uses the same cell height', () => {
  for (const [platform, lineHeight, rows] of [['windows', 1, 20], ['macos', 1, 20]]) {
    setNativeEngineForTests({ platform });
    const { view, container } = makeView();
    try {
      view.term.element = null;
      view.term._core = null;
      container.clientHeight = 260;
      view.fit();
      assert.equal(view.term.opts.lineHeight, lineHeight);
      assert.equal(view.rows, rows, `${platform} fallback grid agrees with renderer leading`);
    } finally {
      view.dispose();
      resetNativeEngineForTests();
    }
  }
});

test('字体预设 2↔6、3↔4 每次切换都触发终端更新', () => {
  const { view } = makeView({ fontFamily: TERMINAL_FONT_FAMILIES[0], fontSize: 13 });
  const fitCalls = [];
  const fit = view.fit.bind(view);
  view.fit = (opts) => { fitCalls.push(opts); return fit(opts); };
  view.open();
  fitCalls.length = 0;

  for (const [left, right] of [[1, 5], [2, 3]]) {
    for (const family of [left, right, left]) {
      view.updateFont({ fontFamily: TERMINAL_FONT_FAMILIES[family] });
      assert.ok(view.term.options.fontFamily.startsWith(TERMINAL_FONT_FAMILIES[family]));
      assert.ok(view.term.options.fontFamily.includes("Symbols Nerd Font Mono"));
      assert.equal(view.fontFamily, TERMINAL_FONT_FAMILIES[family]);
      assert.equal(fitCalls.length, 1, `font ${family + 1} should trigger a fit`);
      fitCalls.length = 0;
      view.updateFont({ fontFamily: TERMINAL_FONT_FAMILIES[family] });
      assert.equal(fitCalls.length, 0, 'reapplying the chosen font must not resize for its fallback suffix');
    }
  }
  view.dispose();
});

test('resize 上报合并成一次：连续 fit 只回调最终几何', async () => {
  const { view, container, calls } = makeView();
  view.open();                                  // 800/8=100 列, 400/16=25 行
  assert.deepEqual(view.term.cols, 100);
  assert.deepEqual(view.term.rows, 25);
  assert.deepEqual(calls.resize, [[25, 100]], '首订几何就绪后立即上报');
  calls.resize.length = 0;

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

test('completed layout flushes only the final grid and cancels the trailing resize timer', async () => {
  const { view, container, calls } = makeView();
  view.open();
  calls.resize.length = 0;
  container.clientWidth = 640;
  view.fit();
  container.clientWidth = 480;
  view.fit({ immediate: true, sync: true });
  assert.deepEqual(calls.resize, [[25, 60]], 'known final geometry does not wait 120ms');
  view.fit(); // ResizeObserver may deliver the already-committed size later.
  await sleep(160);
  assert.deepEqual(calls.resize, [[25, 60]], 'neither old timer nor observer duplicates the wire action');
  assert.equal(view.cols, 60);
  view.dispose();
});

test('a completed layout does not resize a fixed mobile grid', async () => {
  const { view, container, calls } = makeView();
  view.open();
  view.setFixedGrid({ rows: 44, cols: 46 });
  calls.resize.length = 0;
  container.clientWidth = 1600;
  view.fit({ immediate: true, sync: true });
  await sleep(160);
  assert.deepEqual(calls.resize, []);
  assert.equal(view.cols, 46);
  assert.equal(view.rows, 44);
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

test('C: after snapshot, settled shrink resets before resize (no wrap of old cells)', async () => {
  const { view, container } = makeView();
  view.open();
  await sleep(200);
  view.writeSnapshot(new Uint8Array([0x41]));
  const resetsAfterPaint = view.term.resets;
  container.clientWidth = 400;
  view.fit();
  await sleep(200);
  assert.ok(view.term.resets > resetsAfterPaint, 'old snapshot cleared before narrower grid');
  assert.equal(view.term.cols, 50);
  assert.equal(view._hasPainted, false);
  view.dispose();
});

test('snapshot 清屏重建、delta 追加；快照补回车语义而不改 delta', async () => {
  const { view } = makeView();
  view.open();
  const snap = new Uint8Array([0x41, 0x1b, 0x5b, 0x31, 0x3b, 0x31, 0x48]);
  view.writeSnapshot(snap);
  assert.equal(view.term.resets, 1);
  assert.equal(view.term.writes[0], snap, '整段原样喂给 xterm，不 trim、不按行拆');
  view.writeDelta(new Uint8Array([0x42]));
  await sleep(0);
  assert.equal(view.term.resets, 1);
  assert.equal(view.term.writes.length, 2);
  view.dispose();
});

test('snapshot 裸 LF 隐含 CR，delta 保持原始字节', async () => {
  const { view } = makeView();
  view.open();
  const snap = new Uint8Array([0x41, 0x0a, 0x42]);
  view.writeSnapshot(snap);
  assert.deepEqual([...view.term.writes[0]], [0x41, 0x0d, 0x0a, 0x42]);
  assert.deepEqual([...snap], [0x41, 0x0a, 0x42], 'snapshot source bytes are not mutated');

  const delta = new Uint8Array([0x43, 0x0a]);
  view.writeDelta(delta);
  await sleep(0);
  assert.equal(view.term.writes.length, 2);
  assert.equal(view.term.writes[1], delta, 'delta stays byte-identical');
  view.dispose();
});

test('delta burst is coalesced into one ordered complete xterm write', async () => {
  const { view } = makeView();
  view.open();
  const chunks = [new Uint8Array([0x41]), new Uint8Array([0x42, 0x43]), new Uint8Array([0x44])];
  for (const chunk of chunks) assert.equal(view.writeDelta(chunk), true);
  assert.equal(view.term.writes.length, 0, 'delta burst waits for the scheduler');
  await sleep(0);
  assert.equal(view.term.writes.length, 1);
  assert.deepEqual([...view.term.writes[0]], [0x41, 0x42, 0x43, 0x44]);
  view.dispose();
});

test('macOS input echo skips frame batching while keeping writes single-flight', async () => {
  setNativeEngineForTests({ platform: 'macos' });
  const { view } = makeView();
  const callbacks = [];
  view.term.write = (data, callback) => { view.term.writes.push(data); callbacks.push(callback); };
  try {
    view.open();
    view.term.emitData('a');
    view.writeDelta(new Uint8Array([65]));
    assert.equal(view.term.writes.length, 1, 'the first echo enters xterm immediately');
    view.term.emitData('b');
    view.writeDelta(new Uint8Array([66]));
    assert.equal(view.term.writes.length, 1, 'an unfinished parse still owns the writer');
    callbacks.shift()();
    assert.equal(view.term.writes.length, 2, 'pending input echo follows the completed parse without a frame wait');
    callbacks.shift()();
    view.writeDelta(new Uint8Array([67]));
    assert.equal(view.term.writes.length, 2, 'unsolicited output retains batching');
    await sleep(0);
    assert.deepEqual(view.term.writes.map(d => [...d]), [[65], [66], [67]]);
  } finally {
    view.dispose();
    resetNativeEngineForTests();
  }
});

test('delta backlog overflow requests snapshot recovery instead of silently dropping', async () => {
  const recoveries = [];
  const { view } = makeView({
    maxPendingWriteBytes: 4,
    onWriteBackpressure: (info) => recoveries.push(info),
  });
  view.open();
  assert.equal(view.writeDelta(new Uint8Array([1, 2, 3])), true);
  assert.equal(view.writeDelta(new Uint8Array([4, 5])), false);
  assert.deepEqual(recoveries, [{ queuedBytes: 3, maxPendingBytes: 4 }]);
  await sleep(0);
  assert.equal(view.term.writes.length, 0, 'overflow clears the queued stale deltas only with recovery signalled');

  view.writeSnapshot(new Uint8Array([9]));
  assert.equal(view.term.writes.length, 1);
  assert.deepEqual([...view.term.writes[0]], [9]);
  assert.equal(view.writeDelta(new Uint8Array([10])), true);
  await sleep(0);
  assert.deepEqual([...view.term.writes[1]], [10]);
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

test('焦点列实心不闪烁、失焦列空心：cursorBlink:false (UI-SPEC §6.2) + outline inactive + focus/blur', () => {
  const { view } = makeView();
  view.open();
  assert.equal(view.term.opts.cursorBlink, false);
  assert.equal(view.term.opts.cursorStyle, 'block');
  assert.equal(view.term.opts.cursorInactiveStyle, 'outline');
  view.focus();
  assert.equal(view.term.focused, true);
  view.blur();
  assert.equal(view.term.focused, false);
  view.dispose();
});

test('Cursor provider suppresses the parked hardware cursor after every write', () => {
  const { view } = makeView({ hideCursor: true });
  view.open();
  assert.equal(view.term.opts.cursorBlink, false);
  assert.equal(view.term.opts.cursorInactiveStyle, 'none');
  assert.deepEqual([...view.term.writes[0]], [0x1b, 0x5b, 0x3f, 0x32, 0x35, 0x6c]);
  view.writeSnapshot(new Uint8Array([0x41]));
  assert.deepEqual([...view.term.writes[1]], [0x41, 0x1b, 0x5b, 0x3f, 0x32, 0x35, 0x6c]);
  view.dispose();
});

test('Cursor IME anchor follows the visible Add a follow-up row', () => {
  const { view } = makeView({ hideCursor: true });
  let lineText = '→ Add a follow-up';
  view.term.buffer.active.getLine = (index) => index === 5
    ? { translateToString: () => lineText }
    : null;
  view.open();
  assert.equal(view.term.textarea.style.left, '16px');
  assert.equal(view.term.textarea.style.top, '80px');
  assert.equal(view.term.textarea.style.width, '8px');
  assert.equal(view.term.composition.style.left, '16px');
  assert.equal(view.term.composition.style.top, '80px');

  // After the placeholder is replaced, keep the same visible row and follow its end.
  lineText = '→ hello';
  view._syncCursorAnchor();
  assert.equal(view.term.textarea.style.left, '56px');
  assert.equal(view.term.textarea.style.top, '80px');
  view.dispose();
});

test('Cursor IME anchor wins after xterm rewrites helper styles', () => {
  const previousObserver = globalThis.MutationObserver;
  const observers = [];
  globalThis.MutationObserver = class {
    constructor(callback) { this.callback = callback; observers.push(this); }
    observe() {}
    disconnect() {}
  };
  let view;
  try {
    ({ view } = makeView({ hideCursor: true }));
    view.term.buffer.active.getLine = (index) => index === 5
      ? { translateToString: () => '→ Add a follow-up' }
      : null;
    view.open();
    view.term.textarea.style.top = '414px';
    view.term.composition.style.top = '414px';
    for (const observer of observers) observer.callback();
    assert.equal(view.term.textarea.style.top, '80px');
    assert.equal(view.term.composition.style.top, '80px');
  } finally {
    view?.dispose();
    if (previousObserver) globalThis.MutationObserver = previousObserver;
    else delete globalThis.MutationObserver;
  }
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

test('onBinary 把 X10 原始二进制 code units 交给调用方', () => {
  const got = [];
  const { view } = makeView({ onBinary: (d) => got.push(d) });
  view.open();
  const report = String.fromCharCode(0x1b, 0x5b, 0x4d, 0x20, 0xc8, 0xc9);
  view.term.emitBinary(report);
  assert.deepEqual(got, [report]);
  view.dispose();
});

test('fit follows changed renderer metrics without DOM measurement or a stale cell cache', () => {
  const { view, calls } = makeView();
  view.term.element.querySelector = () => { throw new Error('fit must not measure DOM'); };
  view.fit({ immediate: true, sync: true });
  assert.equal(view.cols, 100);
  view.term._core._renderService.dimensions.css.cell = { width: 7.5, height: 15 };
  view.fit({ immediate: true, sync: true });
  assert.equal(view.cols, 106);
  assert.equal(view.rows, 26);
  assert.deepEqual(calls.resize.at(-1), [26, 106]);
  view.dispose();
});
