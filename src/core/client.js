import { Client as CoreClient } from '../../deps/corral-core/web/js/client.js';
import { encodeControl, decodeControl, isExtension } from './protocol.js';
import { bookkeep, unbook, bookOf, geomTrace } from '../term/geomTrace.js';
export { ClientState } from '../../deps/corral-core/web/js/client.js';

/** Desktop extensions only; core owns transport, listing, replay and pending. */
export class Client extends CoreClient {
  constructor(opts) {
    super(opts);
    this.level2Workspace = null;
    const onBinary = this.onBinary;
    this.onBinary = (frame) => {
      const session = this.session(frame.ref);
      geomTrace(frame.kind === 1 ? 'snapshot' : frame.kind === 2 ? 'delta' : 'scrollback', {
        ref: frame.ref, kind: frame.kind,
        frame_cols: session?.cols ?? null, frame_rows: session?.rows ?? null,
        bytes_len: frame.data?.byteLength || frame.data?.length || 0,
      });
      onBinary(frame);
    };
  }

  subscribe(ref, rows, cols, reason = 'user') {
    bookkeep(ref, rows, cols);
    const ready = this.isReady;
    const ok = super.subscribe(ref, rows, cols);
    this.traceGeometry('subscribe', { ref, rows, cols }, reason, ready && ok, ready);
    return ok;
  }

  unsubscribe(ref) {
    unbook(ref);
    return super.unsubscribe(ref);
  }

  resize(ref, rows, cols, reason = 'user') {
    const ready = this.isReady;
    const ok = super.resize(ref, rows, cols);
    this.traceGeometry('resize', { ref, rows, cols }, reason, ok, ready);
    return ok;
  }

  traceGeometry(event, p, reason, ok, ready = true) {
    geomTrace(event, { ...p, reason, ok, skipped: !ready ? 'not_ready' : ok ? null : 'send_failed', ...bookOf(p.ref) });
  }

  replaySubscriptions() {
    this.tracingReplay = true;
    try { super.replaySubscriptions(); } finally { this.tracingReplay = false; }
    if (this.level2Workspace) this.sendControl('level2_subscribe', { workspace: this.level2Workspace });
  }

  subscribeLevel2(cwd) {
    if (typeof cwd !== 'string' || !cwd) return false;
    this.level2Workspace = cwd;
    return !this.isReady || this.sendControl('level2_subscribe', { workspace: cwd });
  }

  unsubscribeLevel2() {
    this.level2Workspace = null;
    return !this.isReady || this.sendControl('level2_unsubscribe', {});
  }

  scrollWheel(ref, delta) { return this.sendControl('scroll_wheel', { ref, delta }); }
  attachPreview(ref, path) { return this.sendControl('attach_preview', { ref, path }); }

  inputAttachment(ref, path, text = '') {
    if (typeof path !== 'string' || !path.startsWith('/')) {
      this.onLocalError('invalid_field', 'attachment path must be absolute');
      return null;
    }
    return this.sendExtendedInput({ ref, text, attachment_path: path });
  }

  inputBytes(ref, bytes) {
    const value = bytes instanceof Uint8Array
      ? bytes
      : bytes instanceof ArrayBuffer
        ? new Uint8Array(bytes)
        : Array.isArray(bytes) && bytes.every((n) => Number.isInteger(n) && n >= 0 && n <= 255)
          ? Uint8Array.from(bytes)
          : null;
    if (!value || value.length === 0) {
      this.onLocalError('invalid_field', 'input bytes must be non-empty');
      return null;
    }
    return this.sendExtendedInput({ ref, bytes: value });
  }

  keys(ref, key) {
    return key === 'backspace' ? this.sendExtendedInput({ ref, keys: [key] }) : super.keys(ref, key);
  }

  // Upstream input()/keys() close over its codec, so only new input variants
  // need this entry. Allocation and ACK/timeout/disconnect handling remain core.
  sendExtendedInput(payload) {
    const reqId = this.nextReqId++;
    if (!this.sendControl('input', { req_id: reqId, ...payload })) return null;
    this.registerPending(reqId);
    return reqId;
  }

  sendControl(type, payload) {
    let ok;
    if (!isExtension(type, payload)) ok = super.sendControl(type, payload);
    else {
      try { ok = this.sendRaw(encodeControl(type, payload)); }
      catch (e) { this.onLocalError(e.code, e.message); return false; }
    }
    if (type === 'subscribe' && this.tracingReplay) this.traceGeometry('subscribe', payload, 'reconnect', ok);
    return ok;
  }

  handleMessage(data) {
    if (typeof data !== 'string') return super.handleMessage(data);
    let root;
    try { root = JSON.parse(data); } catch { return super.handleMessage(data); }
    if (!isExtension(root?.type, root?.payload)) return super.handleMessage(data);
    let frame;
    try { frame = decodeControl(data); }
    catch (e) { this.onLocalError(e.code, e.message); return; }
    this.handleFrame(frame.type, frame.payload);
  }
}
