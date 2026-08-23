import { test } from 'node:test';
import assert from 'node:assert/strict';
import { unicodeBlock, uPlus } from '../.team/nodes/garble/unicode-block.mjs';

test('uPlus pads to 4 hex digits', () => {
  assert.equal(uPlus(0x4E2D), 'U+4E2D');
  assert.equal(uPlus(0xA), 'U+000A');
});

test('unicodeBlock names CJK and fullwidth', () => {
  assert.equal(unicodeBlock(0x7684), 'CJK Unified Ideographs');
  assert.equal(unicodeBlock(0xFF0C), 'Halfwidth and Fullwidth Forms');
  assert.equal(unicodeBlock(0x3001), 'CJK Symbols and Punctuation');
  assert.equal(unicodeBlock(0x2500), 'Box Drawing');
});
