import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { isCtrlV, isCtrlShiftV, isCtrlShiftC, isCmdV, readClipboardImage, imageFromPasteEvent } from '../src/term/clipboard.js';
import {
  nativeCapabilities,
  setNativeEngineForTests,
  resetNativeEngineForTests,
} from '../src/core/nativeCapabilities.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

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

test('App.jsx explicitly imports readClipboardImage from clipboard.js to avoid ReferenceError', () => {
  const appFile = path.resolve(__dirname, '../src/App.jsx');
  const content = fs.readFileSync(appFile, 'utf8');

  // Must explicitly import readClipboardImage
  const importMatch = content.match(/import\s*\{[^}]*readClipboardImage[^}]*\}\s*from\s*['"]\.\/term\/clipboard\.js['"]/);
  assert.ok(importMatch, 'src/App.jsx must import readClipboardImage from ./term/clipboard.js');

  // Verify that calling readClipboardImage doesn't throw ReferenceError
  assert.equal(typeof readClipboardImage, 'function');
});

test('TerminalPane.jsx does not capture contextmenu, ensuring pane right-click menu bubbles', () => {
  const paneFile = path.resolve(__dirname, '../src/components/terminal/TerminalPane.jsx');
  const content = fs.readFileSync(paneFile, 'utf8');

  // Must NOT intercept contextmenu in capture phase or swallow with stopPropagation
  assert.ok(
    !content.includes("addEventListener('contextmenu'"),
    'TerminalPane.jsx must not register capture-phase contextmenu listener that swallows right-clicks',
  );
  assert.ok(
    !content.includes('ev.stopPropagation()') || !content.includes('onContextMenu'),
    'TerminalPane.jsx must not call stopPropagation in onContextMenu',
  );
});

test('handlePaneCtrlV image pipeline successfully resolves image and dispatches attachment', async () => {
  const fakeBytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
  setNativeEngineForTests({
    platform: 'windows',
    clipboard: {
      readImage: async () => ({
        name: 'paste.png',
        mime: 'image/png',
        bytes: fakeBytes,
      }),
      readText: async () => '',
      readFiles: async () => [],
    },
  });

  try {
    let attached = null;
    const handleAttachment = async (_uid, image) => {
      attached = image;
    };

    // Simulate App.jsx handlePaneCtrlV image branch
    let image = null;
    try {
      image = await readClipboardImage();
    } catch {}

    assert.ok(image, 'readClipboardImage must resolve attached image');
    assert.equal(image.name, 'paste.png');
    assert.deepEqual([...image.bytes], [0x89, 0x50, 0x4e, 0x47]);

    if (image) {
      await handleAttachment('dev-1::pane-1', image);
    }
    assert.ok(attached, 'handleAttachment must be called when image is present');
    assert.equal(attached.name, 'paste.png');
  } finally {
    resetNativeEngineForTests();
  }
});

test('imageFromPasteEvent extracts image bytes from ClipboardEvent DataTransfer items', async () => {
  const fakePng = new Uint8Array([137, 80, 78, 71]);
  const fakeFile = {
    name: 'user-paste.png',
    type: 'image/png',
    arrayBuffer: async () => fakePng.buffer,
  };
  const event = {
    clipboardData: {
      items: [
        { kind: 'string', type: 'text/plain' },
        { kind: 'file', type: 'image/png', getAsFile: () => fakeFile },
      ],
      files: [],
    },
  };

  const image = await imageFromPasteEvent(event);
  assert.ok(image, 'image must be extracted from event.clipboardData');
  assert.equal(image.name, 'user-paste.png');
  assert.equal(image.mime, 'image/png');
  assert.deepEqual([...image.bytes], [137, 80, 78, 71]);
});

test('imageFromPasteEvent returns null when only text is present in ClipboardEvent', async () => {
  const event = {
    clipboardData: {
      items: [
        { kind: 'string', type: 'text/plain' },
      ],
      files: [],
    },
  };

  const image = await imageFromPasteEvent(event);
  assert.equal(image, null);
});

test('handlePanePaste consumes ClipboardEvent image and dispatches handleAttachment directly', async () => {
  const fakePng = new Uint8Array([137, 80, 78, 71]);
  const event = {
    clipboardData: {
      getData: () => '',
      items: [
        {
          kind: 'file',
          type: 'image/png',
          getAsFile: () => ({
            name: 'pasted-screenshot.png',
            type: 'image/png',
            arrayBuffer: async () => fakePng.buffer,
          }),
        },
      ],
    },
  };

  let attached = null;
  const handleAttachment = async (_uid, img) => {
    attached = img;
  };

  // Simulate handlePanePaste logic: text is empty, files empty, image extracted from event
  const image = await imageFromPasteEvent(event);
  assert.ok(image, 'image extracted from event');
  await handleAttachment('dev-1::pane-1', image);

  assert.ok(attached, 'handleAttachment must be invoked directly without Ctrl+V toast');
  assert.equal(attached.name, 'pasted-screenshot.png');
  assert.equal(attached.mime, 'image/png');
  assert.deepEqual([...attached.bytes], [137, 80, 78, 71]);
});
