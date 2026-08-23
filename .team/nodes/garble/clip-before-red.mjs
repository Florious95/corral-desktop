#!/usr/bin/env node
/** 修前红：未裁的 113×x+CJK 在 114 列 xterm 上若「不折行」则失败。期望 exit 1 当误断言不折。 */
import assert from 'node:assert/strict';
import { Terminal } from '@xterm/xterm/lib/xterm.mjs';

const term = new Terminal({
  cols: 114, rows: 6, scrollback: 0, allowProposedApi: true, convertEol: false,
});
const line = `${'x'.repeat(113)}中`;
await new Promise((resolve) => {
  term.write(line, () => resolve());
});
const wrapped = term.buffer.active.getLine(1) && term.buffer.active.getLine(1).isWrapped;
const y = term.buffer.active.cursorY;
term.dispose();
assert.equal(y, 0, '修前：未裁行必须落到第 2 视觉行（本断言应当失败）');
assert.equal(wrapped, false);
