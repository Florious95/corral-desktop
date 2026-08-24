import { test } from 'node:test';
import assert from 'node:assert/strict';
import { UploadError, uploadImage } from '../src/core/upload.js';

test('upload_http native branch sends one command and returns absolute path', async () => {
  const calls = [];
  const path = await uploadImage({
    url: 'ws://127.0.0.1:9911/ws', token: 'secret-token', name: 'a.png', mime: 'image/png', bytes: [1, 2],
    nativeInvoke: async (name, args) => { calls.push([name, args]); return '/host/uploads/a.png'; },
  });
  assert.equal(path, '/host/uploads/a.png');
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], 'upload_http');
  assert.equal(calls[0][1].url, 'http://127.0.0.1:9911/upload');
  assert.equal(calls[0][1].token, 'secret-token');
  assert.deepEqual(calls[0][1].bytes, [1, 2]);
});

test('web upload distinguishes 401 from an unreachable daemon', async () => {
  const unauthorized = async () => ({ ok: false, status: 401 });
  await assert.rejects(
    uploadImage({ url: 'ws://127.0.0.1:1/ws', token: 'x', name: 'a.png', mime: 'image/png', bytes: [1], fetchImpl: unauthorized }),
    (e) => e instanceof UploadError && e.code === 'unauthorized',
  );
  await assert.rejects(
    uploadImage({ url: 'ws://127.0.0.1:1/ws', token: 'x', name: 'a.png', mime: 'image/png', bytes: [1], fetchImpl: async () => { throw new Error('ECONNREFUSED'); } }),
    (e) => e instanceof UploadError && e.code === 'unreachable',
  );
});
