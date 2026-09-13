import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isCmdV, isCtrlV, readCtrlV, readClipboardImage, textFromPasteEvent } from '../src/term/clipboard.js';

test('clipboard shortcuts keep Cmd+V and Ctrl+V distinct', () => {
  assert.equal(isCmdV({ type: 'keydown', key: 'v', metaKey: true, ctrlKey: false, altKey: false }), true);
  assert.equal(isCtrlV({ type: 'keydown', key: 'v', metaKey: false, ctrlKey: true, altKey: false }), true);
  assert.equal(isCtrlV({ type: 'keydown', key: 'v', metaKey: true, ctrlKey: true, altKey: false }), false);
});

test('Ctrl+V reads native image bytes and never turns plain text into an input frame', async () => {
  const png = new Uint8Array([137, 80, 78, 71]);
  let webReadCalls = 0;
  let webReadTextCalls = 0;
  const navigatorObj = { clipboard: {
    read: async () => { webReadCalls += 1; return []; },
    readText: async () => { webReadTextCalls += 1; return 'not sent'; },
  } };
  const result = await readCtrlV({ navigatorObj, nativeInvoke: async (name) => {
    assert.equal(name, 'read_clipboard_image');
    return { name: 'clipboard.png', mime: 'image/png', bytes: [...png] };
  } });
  assert.equal(result.kind, 'image');
  assert.deepEqual([...result.attachment.bytes], [...png]);
  assert.equal(webReadCalls, 0);
  assert.equal(webReadTextCalls, 0);

  const textOnly = await readCtrlV({ navigatorObj, nativeInvoke: async () => null });
  assert.deepEqual(textOnly, { kind: 'empty' });
  assert.equal(webReadCalls, 0);
  assert.equal(webReadTextCalls, 0);
});

test('Cmd+V text is the only paste payload even when clipboard carries an image', () => {
  const event = { clipboardData: { getData: (type) => type === 'text/plain' ? 'caption' : '' } };
  assert.equal(textFromPasteEvent(event), 'caption');
  const imageOnly = { clipboardData: { getData: () => '' } };
  assert.equal(textFromPasteEvent(imageOnly), '');
});

test('native clipboard command returns real command bytes without Web Clipboard access', async () => {
  let webReadCalls = 0;
  const result = await readClipboardImage({
    navigatorObj: { clipboard: { read: async () => { webReadCalls += 1; throw new Error('must not be called'); } } },
    nativeInvoke: async (name) => {
      assert.equal(name, 'read_clipboard_image');
      return { name: 'clipboard.png', mime: 'image/png', bytes: [1, 2, 3] };
    },
  });
  assert.deepEqual([...result.bytes], [1, 2, 3]);
  assert.equal(webReadCalls, 0);
});

test('native clipboard no-image result is an empty Ctrl+V without Web text fallback', async () => {
  let webReadTextCalls = 0;
  const result = await readCtrlV({
    navigatorObj: { clipboard: { readText: async () => { webReadTextCalls += 1; return 'must not be sent'; } } },
    nativeInvoke: async (name) => {
      assert.equal(name, 'read_clipboard_image');
      return null;
    },
  });
  assert.deepEqual(result, { kind: 'empty' });
  assert.equal(webReadTextCalls, 0);
});
