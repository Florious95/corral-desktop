/*
 * AgentMirror web client — connection manager.
 *
 * Lifecycle (docs/protocol.md §3): WS open → send auth (token once) → wait
 * auth_ack → READY → exchange business frames. READY drop → exponential backoff
 * reconnect → on READY re-list + replay subscriptions (requirement 004
 * stateless replay: the only state is the host's tmux). auth rejected / explicit
 * stop → permanent STOPPED.
 *
 * Mirrors app/.../conn/ConnectionManager.kt. The WebSocket transport is injected
 * (wsFactory) so tests drive a fake socket — the same seam as Kotlin's
 * transportFactory.
 *
 * The client owns the workspace model (built from listing + list_delta, with
 * server-side seq continuity: a delta that does not continue lastSeq triggers an
 * automatic re-list, §4.2) and the subscription replay bookkeeping. Inputs carry
 * a decidable timeout so "sent with no effect" cannot silently happen (§4.2).
 */

import { encodeControl, decodeControl } from './protocol.js';
import { decodeBinary } from './binary.js';

export const ClientState = Object.freeze({
  STOPPED: 'stopped',
  CONNECTING: 'connecting',
  AUTHENTICATING: 'authenticating',
  READY: 'ready',
  RECONNECTING: 'reconnecting',
});

const DEFAULT_INPUT_TIMEOUT_MS = 10_000;
const DEFAULT_BACKOFF = { baseMs: 1000, maxMs: 30_000, factor: 2, jitter: 0.3 };

/**
 * Owns one authenticated WebSocket lifecycle, workspace model, and subscription replay ledger.
 * @contract
 * @pre construction receives a non-empty URL/token and optional transport callbacks
 * @post connect drives auth/list; reconnect replays active subscriptions after READY
 * @err local protocol/transport/input-timeout failures surface through callbacks or STOPPED state
 * @inv token is sent only in auth and is never emitted through callbacks or model data
 */
export class Client {
  /**
   * @param {Object} opts
   * @param {string} opts.url   ws:// endpoint
   * @param {string} opts.token pairing token (written once upstream, never echoed)
   * @param {(url:string)=>WebSocket} [opts.wsFactory] injectable transport factory
   * @param {number} [opts.inputTimeoutMs]
   * @param {{baseMs:number,maxMs:number,factor:number,jitter:number}} [opts.backoff]
   * @param {(s:string)=>void} [opts.onStateChange]
   * @param {(type:string, payload:Object)=>void} [opts.onFrame]
   * @param {(frame:Object)=>void} [opts.onBinary]
   * @param {(code:string, message:string)=>void} [opts.onLocalError]
   * @param {(reqId:number, ok:boolean, reason:string|null)=>void} [opts.onInputResult]
   */
  constructor(opts) {
    if (!opts || !opts.url) throw new Error('Client: url required');
    if (!opts.token) throw new Error('Client: token required');
    this.url = opts.url;
    this.token = opts.token;
    this.wsFactory = opts.wsFactory || ((u) => new WebSocket(u));
    this.inputTimeoutMs = opts.inputTimeoutMs || DEFAULT_INPUT_TIMEOUT_MS;
    this.backoff = Object.assign({}, DEFAULT_BACKOFF, opts.backoff || {});

    this.onStateChange = opts.onStateChange || (() => {});
    this.onFrame = opts.onFrame || (() => {});
    this.onBinary = opts.onBinary || (() => {});
    this.onLocalError = opts.onLocalError || (() => {});
    this.onInputResult = opts.onInputResult || (() => {});
    this.onConnectionIssue = opts.onConnectionIssue || (() => {});

    this.ws = null;
    this.state = ClientState.STOPPED;
    this._permanent = false;
    this._authenticated = false;
    this.nextReqId = 1;
    this.lastSeq = null;
    this.activeSubscriptions = new Map(); // ref -> { rows, cols }
    this.overlaySocket = null;
    this.level2Workspace = null;           // single-valued: the server tracks one cwd per connection
    this.pendingInputs = new Map();        // reqId -> { timer }
    this.attempt = 0;
    this._reconnectTimer = null;

    // Rendered workspace model (server authoritative on aggregate_state).
    this.sessionsByRef = new Map();
    this.workspaces = [];
  }

  get isReady() { return this.state === ClientState.READY; }
  get activeRefs() { return [...this.activeSubscriptions.keys()]; }

  /** Look up one session by ref (may be undefined). */
  session(ref) { return this.sessionsByRef.get(ref); }

  /** Start connecting. No-op unless STOPPED. */
  connect() {
    if (this.state !== ClientState.STOPPED) return;
    this._permanent = false;
    this._authenticated = false;
    this.lastSeq = null;
    this.attempt = 0;
    this.attemptConnect();
  }

  /** Permanent close: cancel timers, close socket, STOPPED. */
  disconnect() {
    this._permanent = true;
    this.clearReconnect();
    this.clearPending('connection stopped');
    this.closeWs();
    this.setState(ClientState.STOPPED);
  }

  // ---- C→S business frames ----

  /** Request a full listing. Returns true if a frame went out. */
  list() {
    return this.sendControl('list', { req_id: this.nextReqId++ });
  }

  /** Subscribe to a session mirror; bookkept for replay across reconnects. */
  subscribe(ref, rows, cols) {
    this.activeSubscriptions.set(ref, { rows, cols });
    if (!this.isReady) return true; // bookkept; replayed on READY
    return this.sendControl('subscribe', { ref, rows, cols });
  }

  /** Stop mirroring (idempotent); removed from replay bookkeeping. */
  unsubscribe(ref) {
    this.activeSubscriptions.delete(ref);
    if (!this.isReady) return true;
    return this.sendControl('unsubscribe', { ref });
  }

  /**
   * Inject one whole text line (send-keys semantics; empty = bare Enter).
   * Result is delivered via onInputResult with the req_id returned here.
   * Returns null when the frame could not be sent.
   */
  input(ref, text) {
    const reqId = this.nextReqId++;
    let frame;
    try {
      frame = encodeControl('input', { req_id: reqId, ref, text: text || '' });
    } catch (e) {
      this.onLocalError(e.code, e.message);
      return null;
    }
    if (!this.sendRaw(frame)) return null;
    this.registerPending(reqId);
    return reqId;
  }

  /** Inject one named special key (no Enter appended). Result via onInputResult. */
  keys(ref, key) {
    const reqId = this.nextReqId++;
    let frame;
    try {
      frame = encodeControl('input', { req_id: reqId, ref, keys: [key] });
    } catch (e) {
      this.onLocalError(e.code, e.message);
      return null;
    }
    if (!this.sendRaw(frame)) return null;
    this.registerPending(reqId);
    return reqId;
  }

  /** Submit an uploaded image path. No text field (empty text would be bare Enter). */
  inputAttachment(ref, path) {
    const reqId = this.nextReqId++;
    let frame;
    try {
      frame = encodeControl('input', { req_id: reqId, ref, attachment_path: path });
    } catch (e) {
      this.onLocalError(e.code, e.message);
      return null;
    }
    if (!this.sendRaw(frame)) return null;
    this.registerPending(reqId);
    return reqId;
  }

  /** Mouse wheel. No ack; the server replies with error on failure. */
  scrollWheel(ref, delta) {
    return this.sendControl('scroll_wheel', { ref, delta });
  }

  /** Fetch one history page; reply arrives as a binary scrollback frame. */
  scrollback(ref, fromLine, count) {
    if (!this.isReady) return null;
    const reqId = this.nextReqId++;
    if (!this.sendControl('scrollback', { req_id: reqId, ref, from_line: fromLine, count })) return null;
    return reqId;
  }

  /** Report client terminal dims (applies to a subscribed session). */
  resize(ref, rows, cols) {
    if (!this.isReady) return false;
    return this.sendControl('resize', { ref, rows, cols });
  }

  /**
   * Open overlay capture for the tmux socket of the session being viewed.
   * Replayed after READY. Empty socket is refused (065: no first-found fallback).
   */
  subscribeOverlay(socket) {
    if (typeof socket !== 'string' || socket.length === 0) return false;
    this.overlaySocket = socket;
    if (!this.isReady) return true;
    return this.sendControl('overlay_subscribe', { socket });
  }

  /** Close overlay capture. Idempotent. */
  unsubscribeOverlay() {
    this.overlaySocket = null;
    if (!this.isReady) return true;
    return this.sendControl('overlay_unsubscribe', {});
  }

  /**
   * Subscribe the level-2 live stream (title/status/provider) of one workspace.
   * The server keeps ONE cwd per connection: a second call overwrites the first.
   * Replayed after READY. Empty cwd is refused.
   */
  subscribeLevel2(cwd) {
    if (typeof cwd !== 'string' || cwd.length === 0) return false;
    this.level2Workspace = cwd;
    if (!this.isReady) return true;
    return this.sendControl('level2_subscribe', { workspace: cwd });
  }

  /** Stop the level-2 stream so the daemon stops scanning. Idempotent. */
  unsubscribeLevel2() {
    this.level2Workspace = null;
    if (!this.isReady) return true;
    return this.sendControl('level2_unsubscribe', {});
  }

  // ---- internals ----

  setState(s) {
    if (this.state !== s) {
      this.state = s;
      this.onStateChange(s);
    }
  }

  attemptConnect() {
    this.setState(ClientState.CONNECTING);
    let ws;
    try {
      ws = this.wsFactory(this.url);
    } catch {
      this.scheduleReconnect();
      return;
    }
    this.ws = ws;
    ws.binaryType = 'arraybuffer';
    ws.onopen = () => this.handleOpen();
    ws.onmessage = (ev) => this.handleMessage(ev.data);
    ws.onclose = (ev) => this.handleClose(ev);
    ws.onerror = () => {}; // the close event follows and drives the state
  }

  handleOpen() {
    if (this.state === ClientState.STOPPED) {
      this.closeWs();
      return;
    }
    this.setState(ClientState.AUTHENTICATING);
    try {
      this.sendRaw(encodeControl('auth', { token: this.token }));
    } catch (e) {
      this.onLocalError(e.code, e.message);
      this.scheduleReconnect();
    }
  }

  handleMessage(data) {
    if (typeof data === 'string') {
      let frame;
      try {
        frame = decodeControl(data);
      } catch (e) {
        this.onLocalError(e.code, e.message);
        return;
      }
      this.handleFrame(frame.type, frame.payload);
    } else {
      let frame;
      try {
        frame = decodeBinary(new Uint8Array(data));
      } catch (e) {
        this.onLocalError(e.code, e.message);
        return;
      }
      this.onBinary(frame);
    }
  }

  handleFrame(type, payload) {
    switch (type) {
      case 'auth_ack': {
        this.onFrame(type, payload);
        if (payload.ok === true) {
          this._authenticated = true;
          this._permanent = false;
          this.attempt = 0;
          this.setState(ClientState.READY);
          this.list();
          this.replaySubscriptions();
        } else {
          // Rejected: the server closes the connection right after (§4.2). Treat
          // as permanent — no reconnect loop on a bad token.
          this._permanent = true;
          this.closeWs('auth rejected');
        }
        return;
      }
      case 'listing': {
        this.lastSeq = payload.seq;
        this.buildFromListing(payload);
        this.onFrame(type, payload);
        return;
      }
      case 'list_delta': {
        // Stateless recovery (§4.2): a delta that doesn't continue our last seq
        // (or arrives before any listing) forces a fresh full list.
        const continuous = this.lastSeq !== null && payload.seq === this.lastSeq + 1;
        if (!continuous) {
          this.list();
          return;
        }
        this.lastSeq = payload.seq;
        this.applyDelta(payload);
        this.onFrame(type, payload);
        return;
      }
      case 'input_ack': {
        this.resolveInput(payload);
        this.onFrame(type, payload);
        return;
      }
      default:
        this.onFrame(type, payload);
    }
  }

  handleClose(event = {}) {
    const reason = event.reason || (event.code ? `WebSocket closed (${event.code})` : 'WebSocket closed');
    this.onConnectionIssue(reason);
    if (this._permanent) {
      this.clearPending('connection rejected/closed');
      this.ws = null;
      this.setState(ClientState.STOPPED);
      return;
    }
    this.ws = null;
    this.clearPending('connection lost');
    if (this.state === ClientState.STOPPED) return; // explicit disconnect already ran
    this.scheduleReconnect();
  }

  replaySubscriptions() {
    for (const [ref, dims] of this.activeSubscriptions) {
      this.sendControl('subscribe', { ref, rows: dims.rows, cols: dims.cols });
    }
    if (this.overlaySocket) {
      this.sendControl('overlay_subscribe', { socket: this.overlaySocket });
    }
    if (this.level2Workspace) {
      this.sendControl('level2_subscribe', { workspace: this.level2Workspace });
    }
  }

  scheduleReconnect() {
    if (this.state === ClientState.STOPPED || this._reconnectTimer) return;
    this.setState(ClientState.RECONNECTING);
    const delay = this.nextDelayMs(this.attempt++);
    this._reconnectTimer = setTimeout(() => {
      this._reconnectTimer = null;
      this.attemptConnect();
    }, delay);
    if (this._reconnectTimer && this._reconnectTimer.unref) this._reconnectTimer.unref();
  }

  nextDelayMs(attempt) {
    const { baseMs, maxMs, factor, jitter } = this.backoff;
    const exp = baseMs * Math.pow(factor, attempt);
    const capped = Math.min(exp, maxMs);
    const spread = 1 + (jitter * (Math.random() * 2 - 1));
    return Math.max(0, Math.round(capped * spread));
  }

  clearReconnect() {
    if (this._reconnectTimer) {
      clearTimeout(this._reconnectTimer);
      this._reconnectTimer = null;
    }
  }

  registerPending(reqId) {
    const timer = setTimeout(() => {
      this.pendingInputs.delete(reqId);
      this.onInputResult(reqId, false, 'timeout');
    }, this.inputTimeoutMs);
    if (timer && timer.unref) timer.unref();
    this.pendingInputs.set(reqId, { timer });
  }

  resolveInput(ack) {
    const p = this.pendingInputs.get(ack.req_id);
    if (!p) return;
    clearTimeout(p.timer);
    this.pendingInputs.delete(ack.req_id);
    this.onInputResult(ack.req_id, ack.ok === true, ack.ok === true ? null : (ack.reason || 'unknown'));
  }

  clearPending(reason) {
    for (const [reqId, p] of this.pendingInputs) {
      clearTimeout(p.timer);
      this.onInputResult(reqId, false, reason);
    }
    this.pendingInputs.clear();
  }

  sendControl(type, payload) {
    try {
      return this.sendRaw(encodeControl(type, payload));
    } catch (e) {
      this.onLocalError(e.code, e.message);
      return false;
    }
  }

  sendRaw(text) {
    if (!this.ws || this.ws.readyState !== 1) return false;
    this.ws.send(text);
    return true;
  }

  closeWs() {
    if (this.ws) {
      try { this.ws.close(); } catch { /* already closed */ }
    }
  }

  // ---- workspace model (server authoritative on aggregates) ----

  buildFromListing(listing) {
    this.sessionsByRef.clear();
    for (const w of listing.workspaces || []) {
      for (const s of w.sessions || []) this.sessionsByRef.set(s.ref, s);
    }
    this.workspaces = (listing.workspaces || []).map((w) => ({
      cwd: w.cwd,
      session_count: w.session_count,
      aggregate_state: w.aggregate_state,
      sessions: (w.sessions || []).map((s) => ({ ...s })),
    }));
  }

  applyDelta(delta) {
    for (const s of delta.added_sessions || []) this.sessionsByRef.set(s.ref, s);
    for (const s of delta.changed_sessions || []) this.sessionsByRef.set(s.ref, s);
    for (const r of delta.removed_refs || []) this.sessionsByRef.delete(r);

    // Rebuild workspace groups from the flat session map (sessions carry their
    // cwd, so membership always follows the latest value).
    const groups = new Map();
    for (const s of this.sessionsByRef.values()) {
      let g = groups.get(s.cwd);
      if (!g) { g = { cwd: s.cwd, sessions: [] }; groups.set(s.cwd, g); }
      g.sessions.push(s);
    }
    // changed_workspaces carries server-computed aggregate/count overrides;
    // it only touches groups that still exist (a vanished workspace leaves the
    // rebuild with no sessions).
    for (const cw of delta.changed_workspaces || []) {
      const g = groups.get(cw.cwd);
      if (!g) continue;
      if (cw.aggregate_state !== undefined) g.aggregate_state = cw.aggregate_state;
      if (cw.session_count !== undefined) g.session_count = cw.session_count;
    }
    // Preserve known aggregates for untouched groups; default the rest.
    for (const g of groups.values()) {
      if (g.aggregate_state === undefined) {
        const prev = this.workspaces.find((w) => w.cwd === g.cwd);
        g.aggregate_state = prev ? prev.aggregate_state : 'unknown';
      }
      if (g.session_count === undefined) g.session_count = g.sessions.length;
    }
    this.workspaces = [...groups.values()].sort((a, b) => (a.cwd < b.cwd ? -1 : a.cwd > b.cwd ? 1 : 0));
  }
}
