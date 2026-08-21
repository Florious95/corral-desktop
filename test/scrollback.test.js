import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fetchOlder, acceptScrollback } from '../src/vendor/agentmirror/scrollback.js';

test('history requests paginate backward from the previous returned range', () => {
  const calls = [];
  const page = {
    term: { rows: 24 }, ref: 's1', pendingScrollback: null,
    client: { scrollback: (...args) => { calls.push(args); return calls.length; } },
    showScrollbackPanel() {},
  };
  fetchOlder(() => page);
  assert.deepEqual(calls[0], ['s1', -50, 50]);
  acceptScrollback(page, { reqId: 1, fromLine: -50, lineCount: 50, data: new Uint8Array() });
  fetchOlder(() => page);
  assert.deepEqual(calls[1], ['s1', -100, 50]);
});
