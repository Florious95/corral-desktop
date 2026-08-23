import { test } from 'node:test';
import assert from 'node:assert/strict';
import { firstMismatch } from '../.team/nodes/garble/cause-diff.mjs';

test('firstMismatch: identical is green', () => {
  const d = firstMismatch('ab\ncd', 'ab\ncd');
  assert.equal(d.equal, true);
  assert.equal(d.row, null);
});

test('firstMismatch: reports first row/col, not a score', () => {
  const d = firstMismatch('ab\nxy', 'ab\nxz');
  assert.equal(d.equal, false);
  assert.equal(d.row, 2);
  assert.equal(d.col, 2);
});
