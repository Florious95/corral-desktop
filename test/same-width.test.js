import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Terminal } from '@xterm/xterm/lib/xterm.mjs';
import { SameWidthController, wrapStats } from '../src/term/sameWidth.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const WIDE = join(root, 'test/testdata/garble/wide-host.snapshot.bin');

async function paint(bytes, cols, rows) {
  const term = new Terminal({
    cols, rows, scrollback: 1000, convertEol: false, allowProposedApi: true,
  });
  await new Promise((resolve) => { term.write(bytes, () => resolve()); });
  return term;
}

function rowText(term, y, cols) {
  const line = term.buffer.active.getLine(y);
  if (!line) return '';
  let s = '';
  for (let x = 0; x < cols; x++) {
    const cell = line.getCell(x);
    if (cell) s += cell.getChars() || ' ';
  }
  return s.trimEnd();
}

test('a: 235-col capture into 114-col grid wraps > 50% (bad state stays red)', async () => {
  const bytes = new Uint8Array(readFileSync(WIDE));
  const term = await paint(bytes, 114, 39);
  const st = wrapStats(term);
  assert.equal(st.bufferLen, 152);
  assert.equal(st.wrapped, 102);
  assert.ok(st.ratio > 0.5, `wrap ratio ${st.ratio}`);
  assert.equal(rowText(term, 2, 114), '/ 500K');
  term.dispose();
});

test('b: same-width 235→235 wrap baseline must not regress', async () => {
  const bytes = new Uint8Array(readFileSync(WIDE));
  const term = await paint(bytes, 235, 50);
  const st = wrapStats(term);
  assert.equal(st.bufferLen, 99);
  assert.equal(st.wrapped, 49);
  assert.ok(st.ratio < 0.5, `same-width wrap ratio ${st.ratio}`);
  term.dispose();
});

test('A: no subscribe until settle; first action is subscribe at settled grid', () => {
  const g = new SameWidthController();
  g.proposeGrid(24, 80);
  assert.deepEqual(g.nextAction(), { type: 'none' });
  assert.deepEqual(g.settle(39, 114), { type: 'subscribe', rows: 39, cols: 114 });
  g.noteSent(39, 114);
  assert.deepEqual(g.nextAction(), { type: 'none' });
});

test('B: settled width change re-subscribes (resize would no-op)', () => {
  const g = new SameWidthController();
  g.settle(39, 114);
  g.noteSent(39, 114);
  g.acceptSnapshot();
  assert.deepEqual(g.settle(39, 50), { type: 'subscribe', rows: 39, cols: 50 });
});

test('open → window width → split: every painted snapshot matches that grid', () => {
  const g = new SameWidthController();
  const painted = [];
  const step = (rows, cols) => {
    const act = g.settle(rows, cols);
    if (act.type === 'subscribe') g.noteSent(act.rows, act.cols);
    if (g.acceptSnapshot()) painted.push({ cap: g.painted.cols, grid: cols });
  };
  step(24, 80);
  step(24, 100);
  step(24, 50);
  assert.deepEqual(painted, [
    { cap: 80, grid: 80 },
    { cap: 100, grid: 100 },
    { cap: 50, grid: 50 },
  ]);
});

test('C: reject snapshot/delta while grid ≠ last sent; accept after match', () => {
  const g = new SameWidthController();
  g.settle(39, 114);
  g.noteSent(39, 114);
  assert.equal(g.acceptDelta(), false);
  assert.equal(g.acceptSnapshot(), true);
  assert.equal(g.acceptDelta(), true);
  g.settle(39, 50);
  assert.equal(g.acceptSnapshot(), false, 'old-width snapshot must not paint into new grid');
  assert.equal(g.acceptDelta(), false);
  g.noteSent(39, 50);
  assert.equal(g.acceptSnapshot(), true);
  assert.equal(g.acceptDelta(), true);
});
