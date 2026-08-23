import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Terminal } from '@xterm/xterm/lib/xterm.mjs';
import { clipCaptureToCols, displayWidth } from '../src/term/garbleDetect.js';

const COLS = 114;

function writeLine(term, text) {
  return new Promise((resolve) => {
    term.reset();
    term.write(text, () => resolve());
  });
}

test('bad tooth: unclipped 113×x + CJK wraps on 114-col xterm', async () => {
  const term = new Terminal({
    cols: COLS, rows: 6, scrollback: 0, allowProposedApi: true, convertEol: false,
  });
  const line = `${'x'.repeat(113)}中`;
  await writeLine(term, line);
  assert.equal(term.buffer.active.cursorY, 1);
  assert.equal(term.buffer.active.getLine(1).isWrapped, true);
  term.dispose();
});

test('good: clipped 113×x + CJK occupies one visual row', async () => {
  const term = new Terminal({
    cols: COLS, rows: 6, scrollback: 0, allowProposedApi: true, convertEol: false,
  });
  const line = `${'x'.repeat(113)}中`;
  const clipped = clipCaptureToCols(line, COLS);
  assert.equal(clipped.includes('中'), false);
  assert.equal(displayWidth(clipped), 113);
  await writeLine(term, clipped);
  assert.equal(term.buffer.active.cursorY, 0);
  assert.equal(term.buffer.active.getLine(0).isWrapped, false);
  const l1 = term.buffer.active.getLine(1);
  assert.equal(l1 && l1.translateToString(true).trim(), '');
  term.dispose();
});

test('fill 114 ASCII is not clipped', () => {
  const s = 'x'.repeat(114);
  assert.equal(clipCaptureToCols(s, COLS), s);
});

test('fill 57 CJK is not clipped', () => {
  const s = '中'.repeat(57);
  assert.equal(clipCaptureToCols(s, COLS), s);
  assert.equal(displayWidth(s), 114);
});

test('short line is unchanged', () => {
  assert.equal(clipCaptureToCols('hi', COLS), 'hi');
});

test('SGR is kept while overflowing CJK is dropped', () => {
  const line = `\x1b[31m${'x'.repeat(113)}中\x1b[0m`;
  const clipped = clipCaptureToCols(line, COLS);
  assert.equal(clipped.startsWith('\x1b[31m'), true);
  assert.equal(clipped.endsWith('\x1b[0m'), true);
  assert.equal(clipped.includes('中'), false);
  assert.equal(clipped.includes('x'.repeat(113)), true);
});

test('detectGarble still flags unclipped 115 (labeler unchanged)', async () => {
  const { detectGarble } = await import('../src/term/garbleDetect.js');
  const line = `${'x'.repeat(113)}中`;
  const r = detectGarble({ snapshot: line, termCols: COLS });
  assert.equal(r.garbled, true);
  assert.ok(r.reasons.includes('overwide_line'));
  assert.equal(r.metrics.maxLineWidth, 115);
});
