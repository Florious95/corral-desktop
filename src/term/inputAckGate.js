/**
 * Bounded wait for input_ack before sending the follow-up bare Enter.
 * Unbounded wait + leftover waiters after reconnect is how Enter died after
 * another client caused a desktop reflow (2026-08-22).
 */

export const ACK_TIMEOUT_MS = 5000;
export const ACK_TIMEOUT = 'ack_timeout';
export const ACK_CLEARED = 'ack_cleared';
export const TOAST_ACK_TIMEOUT = '上一条未确认，回车未发出，再按一次强制发送';
export const TOAST_ACK_CLEARED = '连接已重置，回车未发出，再按一次';

export function ackKey(sent) {
  return `${sent.deviceId}:${sent.reqId}`;
}

/**
 * @param {{ timeoutMs?: number }} [opts]
 */
export function createInputAckGate(opts = {}) {
  const timeoutMs = opts.timeoutMs ?? ACK_TIMEOUT_MS;
  const waiters = new Map(); // key → { resolve, timer }
  const acks = new Map();
  const lastTextByUid = new Map();

  function settleOne(key, result) {
    const w = waiters.get(key);
    if (w) {
      waiters.delete(key);
      clearTimeout(w.timer);
      w.resolve(result);
      return;
    }
    acks.set(key, result);
  }

  function onInputResult(r) {
    settleOne(ackKey(r), r);
  }

  function waitAck(sent) {
    const k = ackKey(sent);
    const ready = acks.get(k);
    if (ready) {
      acks.delete(k);
      return Promise.resolve(ready);
    }
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        const cur = waiters.get(k);
        if (cur && cur.resolve === resolve) {
          waiters.delete(k);
          resolve({
            ok: false,
            reason: ACK_TIMEOUT,
            deviceId: sent.deviceId,
            reqId: sent.reqId,
          });
        }
      }, timeoutMs);
      waiters.set(k, { resolve, timer });
    });
  }

  function noteText(uid, sent) {
    lastTextByUid.set(uid, sent);
  }

  function takePending(uid) {
    const p = lastTextByUid.get(uid);
    lastTextByUid.delete(uid);
    return p;
  }

  /** Drop orphans. Every in-flight waiter gets a distinguishable !ok. */
  function flush(reason = ACK_CLEARED) {
    const result = { ok: false, reason };
    const pending = [...waiters.values()];
    waiters.clear();
    for (const w of pending) {
      clearTimeout(w.timer);
      w.resolve(result);
    }
    acks.clear();
    lastTextByUid.clear();
  }

  return {
    onInputResult,
    waitAck,
    noteText,
    takePending,
    flush,
    snapshot: () => ({
      waiters: waiters.size,
      acks: acks.size,
      lastText: lastTextByUid.size,
    }),
  };
}

/**
 * Enter after optional text. Failed/timed-out text ack must not submit that
 * buffer again; the next call (pending already cleared) may send a bare Enter.
 */
export async function submitPaneEnter({
  ready, pending, waitAck, sendBareEnter, onToast,
}) {
  if (!ready) {
    onToast('未连接，未发送');
    return { sent: false, reason: 'not_ready' };
  }
  if (pending) {
    const res = await waitAck(pending);
    if (!res.ok) {
      if (res.reason === ACK_TIMEOUT) onToast(TOAST_ACK_TIMEOUT);
      else if (res.reason === ACK_CLEARED) onToast(TOAST_ACK_CLEARED);
      return { sent: false, reason: res.reason || 'ack_failed' };
    }
  }
  const ok = sendBareEnter();
  if (!ok) {
    onToast('未发送');
    return { sent: false, reason: 'send_failed' };
  }
  return { sent: true };
}

/** Pre-fix waiter: ack never arrives ⇒ this Promise never settles. */
export function waitAckUnbounded(sent, waiters, acks) {
  return new Promise((resolve) => {
    const k = ackKey(sent);
    const ready = acks.get(k);
    if (ready) {
      acks.delete(k);
      resolve(ready);
      return;
    }
    waiters.set(k, resolve);
  });
}
