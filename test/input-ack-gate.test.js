import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  ACK_CLEARED, ACK_TIMEOUT, TOAST_ACK_TIMEOUT,
  createInputAckGate, submitPaneEnter, waitAckUnbounded, ackKey,
} from '../src/term/inputAckGate.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test('修前: waitAckUnbounded 在 ack 永不到达时于有界窗口内不 settle（坏态红）', async () => {
  const waiters = new Map();
  const acks = new Map();
  let settled = false;
  const p = waitAckUnbounded({ deviceId: 'local', reqId: 1 }, waiters, acks).then(() => {
    settled = true;
  });
  await sleep(40);
  assert.equal(settled, false);
  assert.equal(waiters.size, 1);
  // 不让 Promise 泄漏到 runner：人为结掉
  waiters.get(ackKey({ deviceId: 'local', reqId: 1 }))({ ok: true });
  await p;
});

test('修后: ack 永不到达时 waitAck 在 timeoutMs 内以 ack_timeout 返回', async () => {
  const g = createInputAckGate({ timeoutMs: 30 });
  const t0 = Date.now();
  const r = await g.waitAck({ deviceId: 'local', reqId: 7 });
  const dt = Date.now() - t0;
  assert.equal(r.ok, false);
  assert.equal(r.reason, ACK_TIMEOUT);
  assert.ok(dt >= 25 && dt < 200, `elapsed ${dt}`);
  assert.deepEqual(g.snapshot(), { waiters: 0, acks: 0, lastText: 0 });
});

test('修后: 超时后下一次回车立刻发出（pending 已清）', async () => {
  const g = createInputAckGate({ timeoutMs: 25 });
  const sent = { deviceId: 'local', reqId: 3 };
  g.noteText('u1', sent);
  const toasts = [];
  const enters = [];
  const pending = g.takePending('u1');
  const first = await submitPaneEnter({
    ready: true,
    pending,
    waitAck: (s) => g.waitAck(s),
    sendBareEnter: () => { enters.push('first'); return true; },
    onToast: (m) => toasts.push(m),
  });
  assert.equal(first.sent, false);
  assert.equal(first.reason, ACK_TIMEOUT);
  assert.equal(toasts[0], TOAST_ACK_TIMEOUT);
  assert.deepEqual(enters, []);
  const second = await submitPaneEnter({
    ready: true,
    pending: g.takePending('u1'),
    waitAck: (s) => g.waitAck(s),
    sendBareEnter: () => { enters.push('second'); return true; },
    onToast: (m) => toasts.push(m),
  });
  assert.equal(second.sent, true);
  assert.deepEqual(enters, ['second']);
});

test('好态: 正常 ack 后回车发出；ok:false 不提交旧缓冲', async () => {
  const g = createInputAckGate({ timeoutMs: 200 });
  const sent = { deviceId: 'local', reqId: 9 };
  const enters = [];
  const p = submitPaneEnter({
    ready: true,
    pending: sent,
    waitAck: (s) => g.waitAck(s),
    sendBareEnter: () => { enters.push(1); return true; },
    onToast: () => {},
  });
  g.onInputResult({ deviceId: 'local', reqId: 9, ok: true, reason: null });
  assert.equal((await p).sent, true);
  assert.deepEqual(enters, [1]);

  const g2 = createInputAckGate({ timeoutMs: 200 });
  const p2 = submitPaneEnter({
    ready: true,
    pending: { deviceId: 'local', reqId: 2 },
    waitAck: (s) => g2.waitAck(s),
    sendBareEnter: () => { enters.push(2); return true; },
    onToast: () => {},
  });
  g2.onInputResult({ deviceId: 'local', reqId: 2, ok: false, reason: 'busy' });
  const r2 = await p2;
  assert.equal(r2.sent, false);
  assert.equal(r2.reason, 'busy');
  assert.deepEqual(enters, [1]);
});

test('重连 flush: waiter 结掉且 lastTextByUid / waiters 清空', async () => {
  const g = createInputAckGate({ timeoutMs: 5000 });
  g.noteText('u1', { deviceId: 'local', reqId: 4 });
  const waiting = g.waitAck({ deviceId: 'local', reqId: 4 });
  assert.equal(g.snapshot().waiters, 1);
  assert.equal(g.snapshot().lastText, 1);
  g.flush();
  const r = await waiting;
  assert.equal(r.ok, false);
  assert.equal(r.reason, ACK_CLEARED);
  assert.deepEqual(g.snapshot(), { waiters: 0, acks: 0, lastText: 0 });
});

test('重连 flush 清掉早到的失败 ack，避免卡住后续回车', async () => {
  const g = createInputAckGate({ timeoutMs: 50 });
  g.onInputResult({ deviceId: 'local', reqId: 1, ok: false, reason: 'connection lost' });
  assert.equal(g.snapshot().acks, 1);
  g.flush();
  assert.equal(g.snapshot().acks, 0);
  const enters = [];
  const r = await submitPaneEnter({
    ready: true,
    pending: undefined,
    waitAck: (s) => g.waitAck(s),
    sendBareEnter: () => { enters.push('ok'); return true; },
    onToast: () => {},
  });
  assert.equal(r.sent, true);
  assert.deepEqual(enters, ['ok']);
});
