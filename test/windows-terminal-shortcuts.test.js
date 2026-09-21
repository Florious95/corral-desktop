import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isCtrlV, isCtrlShiftV, isCtrlShiftC, isCmdV } from '../src/term/clipboard.js';
import {
  nativeCapabilities,
  setNativeEngineForTests,
  resetNativeEngineForTests,
} from '../src/core/nativeCapabilities.js';

test('isCtrlV, isCtrlShiftV, and isCtrlShiftC distinguish modifiers accurately', () => {
  // Ctrl+V without Shift
  assert.equal(isCtrlV({ type: 'keydown', key: 'v', ctrlKey: true, metaKey: false, altKey: false, shiftKey: false }), true);
  assert.equal(isCtrlV({ type: 'keydown', key: 'V', ctrlKey: true, metaKey: false, altKey: false, shiftKey: false }), true);
  // Ctrl+Shift+V should NOT trigger plain isCtrlV
  assert.equal(isCtrlV({ type: 'keydown', key: 'V', ctrlKey: true, metaKey: false, altKey: false, shiftKey: true }), false);

  // isCtrlShiftV matches Ctrl+Shift+V
  assert.equal(isCtrlShiftV({ type: 'keydown', key: 'v', ctrlKey: true, metaKey: false, altKey: false, shiftKey: true }), true);
  assert.equal(isCtrlShiftV({ type: 'keydown', key: 'V', ctrlKey: true, metaKey: false, altKey: false, shiftKey: true }), true);
  assert.equal(isCtrlShiftV({ type: 'keydown', key: 'v', ctrlKey: true, metaKey: false, altKey: false, shiftKey: false }), false);

  // isCtrlShiftC matches Ctrl+Shift+C
  assert.equal(isCtrlShiftC({ type: 'keydown', key: 'c', ctrlKey: true, metaKey: false, altKey: false, shiftKey: true }), true);
  assert.equal(isCtrlShiftC({ type: 'keydown', key: 'C', ctrlKey: true, metaKey: false, altKey: false, shiftKey: true }), true);
  assert.equal(isCtrlShiftC({ type: 'keydown', key: 'c', ctrlKey: true, metaKey: false, altKey: false, shiftKey: false }), false);

  // isCmdV matches Cmd+V without Shift or Ctrl
  assert.equal(isCmdV({ type: 'keydown', key: 'v', metaKey: true, ctrlKey: false, altKey: false, shiftKey: false }), true);
  assert.equal(isCmdV({ type: 'keydown', key: 'v', metaKey: true, ctrlKey: true, altKey: false, shiftKey: false }), false);
});

test('Windows intelligent clipboard handles image priority and text fallback safely', async () => {
  setNativeEngineForTests({
    platform: 'windows',
    clipboard: {
      readImage: async () => null,
      readText: async () => 'echo "hello from windows"',
      readFiles: async () => [],
    },
  });

  try {
    const text = await nativeCapabilities.clipboard.readText();
    assert.equal(text, 'echo "hello from windows"');

    const image = await nativeCapabilities.clipboard.readImage();
    assert.equal(image, null);

    const files = await nativeCapabilities.clipboard.readFiles();
    assert.deepEqual(files, []);
  } finally {
    resetNativeEngineForTests();
  }
});

test('Windows clipboard reads image attachment when image data is present', async () => {
  const fakeBytes = new Uint8Array([1, 2, 3, 4]);
  setNativeEngineForTests({
    platform: 'windows',
    clipboard: {
      readImage: async () => ({
        name: 'screenshot.png',
        mime: 'image/png',
        bytes: fakeBytes,
      }),
      readText: async () => '',
      readFiles: async () => [],
    },
  });

  try {
    const image = await nativeCapabilities.clipboard.readImage();
    assert.ok(image, 'image must be detected');
    assert.equal(image.name, 'screenshot.png');
    assert.equal(image.mime, 'image/png');
    assert.deepEqual([...image.bytes], [1, 2, 3, 4]);
  } finally {
    resetNativeEngineForTests();
  }
});
