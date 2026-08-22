import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseOnData, NativeInputPump, unsupportedKeyEvent } from '../src/term/nativeInput.js';
import {
  splitPasteText, pickPasteImage, handleClipboardData, wsToHttpOrigin,
  sanitizeUploadError, PASTE_TEXT_MAX_UTF8,
} from '../src/term/clipboardPaste.js';
import { DeviceManager } from '../src/core/devices.js';

test('Ctrl+V byte is silent, not 协议发不了', () => {
  const ev = parseOnData('\x16');
  assert.equal(ev[0].type, 'mouse-silent');
  const hints = [];
  const pump = new NativeInputPump({
    sendText: () => {}, sendKey: () => {}, sendEnter: () => {},
    onUnsupported: (l) => hints.push(l),
  });
  pump.onData('\x16');
  assert.deepEqual(hints, []);
  pump.dispose();
});

test('unsupportedKeyEvent lets Ctrl+V and Cmd+V through to paste', () => {
  assert.equal(unsupportedKeyEvent({ type: 'keydown', key: 'v', ctrlKey: true }), null);
  assert.equal(unsupportedKeyEvent({ type: 'keydown', key: 'v', metaKey: true }), null);
});

test('splitPasteText keeps newlines and chunks by UTF-8 cap', () => {
  const chunks = splitPasteText('a\nb\nc');
  assert.deepEqual(chunks, ['a\nb\nc']);
  const big = 'x'.repeat(PASTE_TEXT_MAX_UTF8 + 10);
  const parts = splitPasteText(big);
  assert.equal(parts.length, 2);
  assert.equal(parts.join('').length, big.length);
});

test('pickPasteImage prefers image files over plain text', () => {
  const img = { type: 'image/png', name: 'a.png' };
  const data = {
    files: [img],
    items: [],
    getData: () => 'hello',
  };
  assert.equal(pickPasteImage(data), img);
  assert.equal(pickPasteImage({ files: [{ type: 'text/plain' }], items: [] }), null);
});

test('handleClipboardData: text is sent whole including newlines, no extra enter', async () => {
  const sent = [];
  await handleClipboardData(
    { files: [], items: [], getData: () => 'ls\n-la' },
    { sendText: (t) => sent.push(t), sendImage: async () => {}, onError: () => {} },
  );
  assert.deepEqual(sent, ['ls\n-la']);
});

test('wsToHttpOrigin maps daemon WS to HTTP upload origin', () => {
  assert.equal(wsToHttpOrigin('ws://127.0.0.1:9900/ws'), 'http://127.0.0.1:9900');
  assert.equal(wsToHttpOrigin('wss://host.example:443/ws'), 'https://host.example');
});

test('sanitizeUploadError never includes credentials', () => {
  assert.equal(sanitizeUploadError(0, true), '上传失败：无法连接');
  assert.equal(sanitizeUploadError(401, false), '上传失败：未授权');
  assert.equal(sanitizeUploadError(500, false), '上传失败');
});

test('DeviceManager.uploadImage: 401 / unreachable / non-image; token not in errors', async () => {
  const storage = {
    _m: new Map(),
    getItem(k) { return this._m.has(k) ? this._m.get(k) : null; },
    setItem(k, v) { this._m.set(k, String(v)); },
    removeItem(k) { this._m.delete(k); },
  };
  const dm = new DeviceManager({ storage, backoff: { baseMs: 20, maxMs: 40, factor: 1, jitter: 0 } });
  const id = dm.addDevice({ name: 'L', url: 'ws://127.0.0.1:9/ws', token: 'secret-token-value' });
  // pretend connected client exists
  const uid = `${id}::s1`;
  dm._clients.set(id, { url: 'ws://127.0.0.1:9/ws', inputAttachment: () => 1 });
  const png = new File([new Uint8Array([1, 2, 3])], 'a.png', { type: 'image/png' });
  try {
    await dm.uploadImage(uid, { type: 'text/plain' });
    assert.fail('expected throw');
  } catch (e) {
    assert.equal(e.message, '不是图片');
    assert.equal(String(e.message).includes('secret-token-value'), false);
  }
  try {
    await dm.uploadImage(uid, png, async () => { throw new Error('network'); });
    assert.fail('expected throw');
  } catch (e) {
    assert.equal(e.message, '上传失败：无法连接');
    assert.equal(String(e.message).includes('secret-token-value'), false);
  }
  try {
    await dm.uploadImage(uid, png, async () => ({ ok: false, status: 401 }));
    assert.fail('expected throw');
  } catch (e) {
    assert.equal(e.message, '上传失败：未授权');
    assert.equal(String(e.message).includes('secret-token-value'), false);
  }
  const sent = await dm.uploadImage(
    uid,
    png,
    async (url, opts) => {
      assert.match(url, /\/upload$/);
      assert.ok(opts.headers.Authorization.startsWith('Bearer '));
      return { ok: true, json: async () => ({ path: '/host/uploads/a.png' }) };
    },
  );
  assert.equal(sent.reqId, 1);
});
