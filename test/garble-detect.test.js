import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { detectGarble } from '../src/term/garbleDetect.js';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const GARBLE = join(ROOT, 'test', 'testdata', 'garble');

function load(name) {
  return new Uint8Array(readFileSync(join(GARBLE, name)));
}

test('bad: wide-host snapshot into 80-col grid is garbled', () => {
  const snapshot = load('wide-host.snapshot.bin');
  const r = detectGarble({ snapshot, termCols: 80, termRows: 24 });
  assert.equal(r.garbled, true);
  assert.ok(r.reasons.includes('overwide_line') || r.reasons.includes('box_run_exceeds_cols'));
  assert.ok(r.metrics.maxLineWidth > 80);
  assert.ok(!r.reasons.includes('missing_term_cols'));
});

test('good: wide-host snapshot at listing width 235 is not garbled', () => {
  const snapshot = load('wide-host.snapshot.bin');
  const r = detectGarble({ snapshot, termCols: 235, termRows: 50 });
  assert.equal(r.garbled, false);
  assert.deepEqual(r.reasons, []);
  assert.ok(r.metrics.maxLineWidth <= 235);
});

test('good: matched-host snapshot at listing width 80 is not garbled', () => {
  const snapshot = load('matched-host.snapshot.bin');
  const r = detectGarble({ snapshot, termCols: 80, termRows: 24 });
  assert.equal(r.garbled, false);
  assert.deepEqual(r.reasons, []);
});

test('does not treat max CUP column as grid width', () => {
  const snapshot = load('wide-host.snapshot.bin');
  const r = detectGarble({ snapshot, termCols: 80, termRows: 24 });
  // If we used CUP-as-width, a cursor near col 1 would look "narrow" and miss the tear.
  assert.ok(r.metrics.maxLineWidth > (r.metrics.maxCupCol || 0) || r.metrics.overwideLines > 0);
  assert.equal(r.garbled, true);
});

test('metrics: maxLineChars is code points of the widest stripped line; maxLineHasWide tracks CJK', () => {
  const ascii = detectGarble({ snapshot: 'hello\n', termCols: 80 });
  assert.equal(ascii.metrics.maxLineWidth, 5);
  assert.equal(ascii.metrics.maxLineChars, 5);
  assert.equal(ascii.metrics.maxLineHasWide, false);

  const cjk = detectGarble({ snapshot: '中\n', termCols: 80 });
  assert.equal(cjk.metrics.maxLineWidth, 2);
  assert.equal(cjk.metrics.maxLineChars, 1);
  assert.equal(cjk.metrics.maxLineHasWide, true);
});

test('metrics: nLinesWidthEqCols and nLinesWidthColsPlus1', () => {
  const eq = detectGarble({ snapshot: `${'a'.repeat(80)}\n`, termCols: 80 });
  assert.equal(eq.metrics.nLinesWidthEqCols, 1);
  assert.equal(eq.metrics.nLinesWidthColsPlus1, 0);
  assert.equal(eq.garbled, false);

  const plus = detectGarble({ snapshot: `${'a'.repeat(81)}\n`, termCols: 80 });
  assert.equal(plus.metrics.nLinesWidthEqCols, 0);
  assert.equal(plus.metrics.nLinesWidthColsPlus1, 1);
  assert.equal(plus.garbled, true);
});
