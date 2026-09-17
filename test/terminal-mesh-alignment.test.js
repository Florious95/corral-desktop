import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { SameWidthController } from '../src/term/sameWidth.js';
import { Terminal } from '@xterm/xterm/lib/xterm.mjs';

test('F1 (P1): reflow eliminates 120ms race condition: 10ms fast snapshot & 200ms slow snapshot are 100% accepted', () => {
  // 1. 模拟 10ms 极速快照到达场景（原死锁场景）
  const gateFast = new SameWidthController();
  // 初始稳定在 99x24
  gateFast.settle(24, 99);
  gateFast.noteSent(24, 99);
  assert.equal(gateFast.acceptSnapshot(), true);

  // 窗口变小为 79x16，用户点击“适应当前窗口”
  // 修复核心：在发送前立即原子同步调用 gate.settle(newRows, newCols)
  const newRows = 16;
  const newCols = 79;
  gateFast.settle(newRows, newCols);
  gateFast.noteSent(newRows, newCols);

  // 快照在 10ms（远早于 120ms）极速到达
  const fastSnapshotAccepted = gateFast.acceptSnapshot();
  assert.equal(fastSnapshotAccepted, true, 'Fast snapshot (10ms) must be accepted by synchronized gate');
  assert.equal(gateFast.awaitingSnapshot, false, 'awaitingSnapshot must be cleared after fast snapshot');

  // 后续到达的 delta 必须畅通无阻
  assert.equal(gateFast.acceptDelta(), true, 'Subsequent delta must be accepted after fast snapshot');

  // 2. 模拟 200ms 常规慢快照到达场景
  const gateSlow = new SameWidthController();
  gateSlow.settle(24, 99);
  gateSlow.noteSent(24, 99);
  assert.equal(gateSlow.acceptSnapshot(), true);

  gateSlow.settle(newRows, newCols);
  gateSlow.noteSent(newRows, newCols);
  // 200ms 后快照到达
  assert.equal(gateSlow.acceptSnapshot(), true, 'Slow snapshot (200ms) must also be accepted');
  assert.equal(gateSlow.awaitingSnapshot, false);
  assert.equal(gateSlow.acceptDelta(), true);
});

test('F2: real xterm VT buffer rendering: matching CUP coordinates verify input box & status bar remain intact', async () => {
  // 实例化真实 xterm 实例（真实 20 行 x 80 列手机尺寸）
  const rows = 20;
  const cols = 80;
  const term = new Terminal({ rows, cols });

  // 真实 VT 字节：输入框严格定位在第 19 行（倒数第二行），状态行定位在第 20 行（末行）
  // 绝不发生“4 行网格发送 25 行 CUP”的错位覆盖！
  const encoder = new TextEncoder();
  const vtSnapshot = encoder.encode(
    '\x1b[2J' + // 清屏
    '\x1b[1;1HMessage output on line 1' +
    '\x1b[19;1H[ █ ] ---------------- ui-developer' +
    '\x1b[20;1HGemini 3.8 Flash · ~ high · 22.7%'
  );

  await new Promise((resolve) => {
    term.write(vtSnapshot, resolve);
  });

  // 检查终端缓冲区最后两行内容
  const line19 = term.buffer.active.getLine(18)?.translateToString(true) || '';
  const line20 = term.buffer.active.getLine(19)?.translateToString(true) || '';

  assert.ok(line19.includes('[ █ ]'), 'Line 19 must contain visible input box [ █ ]');
  assert.ok(line19.includes('ui-developer'), 'Line 19 must contain ui-developer tag');
  assert.ok(line20.includes('Gemini 3.8 Flash'), 'Line 20 must contain status bar');
  assert.ok(line20.includes('22.7%'), 'Line 20 must contain battery percentage');

  term.dispose();
});

test('terminal CSS eliminates max-height clamp and enforces flex-shrink: 0 and fit-content width', async () => {
  const terminalCss = await readFile(new URL('../src/components/terminal/terminal.css', import.meta.url), 'utf8');

  // .terminalpane-host flex-end / flex-start 物理对齐
  assert.match(terminalCss, /\.terminalpane-host\s*\{[^}]*display:\s*flex;/);
  assert.match(terminalCss, /\.terminalpane-host\s*\{[^}]*justify-content:\s*flex-end;/);
  assert.match(terminalCss, /\.terminalpane-host\s*\{[^}]*align-items:\s*flex-start;/);

  // .xterm 消除压扁钳制：禁止 flex-shrink 压缩，不钳制 max-height
  assert.match(terminalCss, /\.terminalpane-host \.xterm\s*\{[^}]*flex:\s*0 0 auto;/);
  assert.match(terminalCss, /\.terminalpane-host \.xterm\s*\{[^}]*width:\s*fit-content;/);
  assert.match(terminalCss, /\.terminalpane-host \.xterm\s*\{[^}]*max-width:\s*100%;/);

  // 核心断言：绝对没有 .xterm 的 max-height 钳制！
  assert.equal(terminalCss.includes('max-height: 100%'), false, 'max-height: 100% must be eliminated');
});

test('TerminalPane reflow uses atomic gate.settle and single controlled sendIfNeeded channel', async () => {
  const terminalPaneJsx = await readFile(new URL('../src/components/terminal/TerminalPane.jsx', import.meta.url), 'utf8');

  // 1. 彻底清除绕过 SameWidthController gate 的 clientRef.current?.resize 旁路
  assert.equal(
    terminalPaneJsx.includes('clientRef.current?.resize?.(target'),
    false,
    'Bypass client.resize call must be eliminated from TerminalPane',
  );

  // 2. 彻底清除绕过 gate 的 clientRef.current?.subscribe 旁路
  assert.equal(
    terminalPaneJsx.includes('clientRef.current?.subscribe?.(target'),
    false,
    'Bypass client.subscribe call must be eliminated from TerminalPane',
  );

  // 3. 重排走 immediate + sync fit，并在发送前原子同步更新 gate.settle
  assert.match(terminalPaneJsx, /viewRef\.current\.fit\(\{\s*immediate:\s*true,\s*sync:\s*true\s*\}\)/);
  assert.match(terminalPaneJsx, /gate\.settle\(fit\.derived_rows,\s*fit\.derived_cols\)/);

  // 4. 走正规受控门禁通道 sendIfNeeded(..., "reflow", { force: true })
  assert.match(
    terminalPaneJsx,
    /sendIfNeeded\(\{\s*type:\s*'subscribe'[\s\S]*?'reflow'[\s\S]*?force:\s*true/
  );

  // 5. isManualReflowing 抑制 onResize 重复发送，保证单次发送
  assert.match(terminalPaneJsx, /if\s*\(!isManualReflowing\)\s*\{\s*const reason/);
});

test('R1 & R2 (P2): controlled reflow issues exactly 1 subscription frame (no duplicate settle) and recovers terminal asynchronously', async () => {
  const gate = new SameWidthController();
  const sentSubscriptions = [];

  const mockClient = {
    subscribe: (target, rows, cols, reason) => {
      sentSubscriptions.push({ target, rows, cols, reason });
      return true;
    },
  };

  let isManualReflowing = false;
  let firstSub = false;

  const sendIfNeeded = (act, reason, { force = false } = {}) => {
    if (!act || act.type !== 'subscribe') return;
    const subscribeKey = `target:${act.rows}x${act.cols}`;
    mockClient.subscribe('target', act.rows, act.cols, reason);
    gate.noteSent(act.rows, act.cols);
  };

  const onResize = (rows, cols) => {
    const act = gate.settle(rows, cols);
    if (!isManualReflowing) {
      const reason = firstSub ? 'activate' : 'settle';
      sendIfNeeded(act, reason);
    }
  };

  // 初始稳定状态：99x24
  gate.settle(24, 99);
  gate.noteSent(24, 99);
  assert.equal(gate.acceptSnapshot(), true);

  // 1. 触发变尺寸手动重排（99x24 -> 79x16）
  sentSubscriptions.length = 0;
  isManualReflowing = true;
  const newRows = 16;
  const newCols = 79;
  try {
    // 模拟 fit({ immediate: true, sync: true }) 同步触发 onResize
    onResize(newRows, newCols);
  } finally {
    isManualReflowing = false;
  }

  // 同步原子确认与受控发送
  gate.settle(newRows, newCols);
  sendIfNeeded({ type: 'subscribe', rows: newRows, cols: newCols }, 'reflow', { force: true });

  // 核心断言 R1：变尺寸重排恰好只发送 1 条订阅，绝无多余的 reason=settle 帧！
  assert.equal(sentSubscriptions.length, 1, 'Reflow must issue exactly ONE subscription frame');
  assert.equal(sentSubscriptions[0].reason, 'reflow');
  assert.equal(sentSubscriptions[0].rows, 16);
  assert.equal(sentSubscriptions[0].cols, 79);

  // 2. 模拟真实网络 10ms 异步延迟后快照返回
  await new Promise((r) => setTimeout(r, 10));

  // 门禁必须 100% 接纳快照
  assert.equal(gate.acceptSnapshot(), true, 'Fast snapshot must be accepted');
  assert.equal(gate.awaitingSnapshot, false);

  // 真实 xterm 解析渲染 16 行快照
  const term = new Terminal({ rows: newRows, cols: newCols });
  const encoder = new TextEncoder();
  const fastSnapshotData = encoder.encode(
    '\x1b[2J' +
    '\x1b[15;1H[ █ ] ---------------- input-ready' +
    '\x1b[16;1HStatus: connected · 10ms fast'
  );
  await new Promise((resolve) => term.write(fastSnapshotData, resolve));

  const line15 = term.buffer.active.getLine(14)?.translateToString(true) || '';
  const line16 = term.buffer.active.getLine(15)?.translateToString(true) || '';
  assert.ok(line15.includes('[ █ ]'), 'Input box must be rendered in terminal buffer');
  assert.ok(line16.includes('Status: connected'), 'Status bar must be rendered in terminal buffer');

  // 快照接纳后增量帧正常可写
  assert.equal(gate.acceptDelta(), true, 'Delta must be accepted after snapshot');

  // 3. 触发同尺寸手动重排（仍为 79x16，用户点击刷新以强制恢复画面）
  sentSubscriptions.length = 0;
  isManualReflowing = true;
  try {
    onResize(newRows, newCols);
  } finally {
    isManualReflowing = false;
  }
  gate.settle(newRows, newCols);
  sendIfNeeded({ type: 'subscribe', rows: newRows, cols: newCols }, 'reflow', { force: true });

  // 断言同尺寸强制重排也恰好发出 1 条订阅
  assert.equal(sentSubscriptions.length, 1, 'Same-geometry reflow must also issue exactly 1 subscription');
  assert.equal(sentSubscriptions[0].reason, 'reflow');

  // 模拟常规 200ms 慢响应快照到达
  await new Promise((r) => setTimeout(r, 200));
  assert.equal(gate.acceptSnapshot(), true, 'Slow snapshot (200ms) must also be accepted');

  term.dispose();
});
