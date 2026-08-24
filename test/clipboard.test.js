import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isCmdV, isCtrlV, readCtrlV, readClipboardImage, textFromPasteEvent } from '../src/term/clipboard.js';

test('clipboard shortcuts keep Cmd+V and Ctrl+V distinct', () => {
  assert.equal(isCmdV({ type: 'keydown', key: 'v', metaKey: true, ctrlKey: false, altKey: false }), true);
  assert.equal(isCtrlV({ type: 'keydown', key: 'v', metaKey: false, ctrlKey: true, altKey: false }), true);
  assert.equal(isCtrlV({ type: 'keydown', key: 'v', metaKey: true, ctrlKey: true, altKey: false }), false);
});

test('Ctrl+V reads image bytes and never turns plain text into an input frame', async () => {
  const png = new Uint8Array([137, 80, 78, 71]);
  const navigatorObj = { clipboard: {
    read: async () => [{ types: ['image/png'], getType: async () => new Blob([png], { type: 'image/png' }) }],
    readText: async () => 'not sent',
  } };
  const result = await readCtrlV({ navigatorObj });
  assert.equal(result.kind, 'image');
  assert.deepEqual([...result.attachment.bytes], [...png]);

  const textOnly = { clipboard: { read: async () => [], readText: async () => 'use Cmd+V' } };
  assert.deepEqual(await readCtrlV({ navigatorObj: textOnly }), { kind: 'text', text: 'use Cmd+V' });
});

test('Cmd+V text is the only paste payload even when clipboard carries an image', () => {
  const event = { clipboardData: { getData: (type) => type === 'text/plain' ? 'caption' : '' } };
  assert.equal(textFromPasteEvent(event), 'caption');
  const imageOnly = { clipboardData: { getData: () => '' } };
  assert.equal(textFromPasteEvent(imageOnly), '');
});

test('WKWebView native clipboard fallback returns real command bytes', async () => {
  const result = await readClipboardImage({
    navigatorObj: { clipboard: { read: async () => { throw new Error('not supported'); } } },
    nativeInvoke: async (name) => {
      assert.equal(name, 'read_clipboard_image');
      return { name: 'clipboard.png', mime: 'image/png', bytes: [1, 2, 3] };
    },
  });
  assert.deepEqual([...result.bytes], [1, 2, 3]);
});
