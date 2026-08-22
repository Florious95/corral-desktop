/*
 * DeviceManager — the single boundary between the UI and the protocol layer
 * (CLIENT-CONTRACT §2).
 *
 * One agentmirrord connection = one Device = one vendor Client. The manager
 * owns N of them and publishes one merged, device-tagged model. Addressing is
 * always by uid (`${deviceId}::${ref}`) / spaceKey (`${deviceId}::${cwd}`):
 * bare refs must never cross device boundaries, two hosts collide on
 * `socket\x1f%paneId` far too easily.
 *
 * What this layer does NOT do: re-implement seq recovery, backoff or
 * subscription replay — the vendor Client already owns those (§3.6, §3.7).
 */

import { Client, ClientState } from '../vendor/agentmirror/client.js';
import { inferProvider } from './providers.js';
import * as store from './store.js';
import { wsToHttpOrigin, sanitizeUploadError } from '../term/clipboardPaste.js';

const MODEL_DEBOUNCE_MS = 100;

/** Client-side workspace aggregate (§0.2): the server no longer computes it. */
function aggregateState(sessions) {
  if (sessions.some((s) => s.status === 'working')) return 'working';
  if (sessions.some((s) => s.status === 'idle')) return 'idle';
  return 'unknown';
}

/** level2 provider strings are snake_case ("claude_code"); UI keys are kebab-case. */
function providerOf(name, serverProvider) {
  return inferProvider(name)
    ?? (typeof serverProvider === 'string' ? inferProvider(serverProvider.replace(/_/g, '-')) : null);
}

function segmentsOf(cwd) {
  return String(cwd || '').split('/').filter(Boolean);
}

function tail(segments, depth) {
  return segments.length === 0 ? '/' : segments.slice(-depth).join('/');
}

/**
 * basename labels, extended leftwards one path segment at a time until each
 * colliding group is unique (§2.3). Same cwd on two devices can never separate —
 * the device badge disambiguates those, so the loop stops when nothing grows.
 */
function labelSpaces(spaces) {
  const segs = spaces.map((s) => segmentsOf(s.cwd));
  const labels = segs.map((s) => tail(s, 1));
  for (let depth = 1; depth < 32; depth++) {
    const groups = new Map();
    labels.forEach((l, i) => {
      const g = groups.get(l);
      if (g) g.push(i); else groups.set(l, [i]);
    });
    let grew = false;
    for (const idxs of groups.values()) {
      if (idxs.length < 2) continue;
      for (const i of idxs) {
        const next = tail(segs[i], depth + 1);
        if (next !== labels[i]) { labels[i] = next; grew = true; }
      }
    }
    if (!grew) break;
  }
  spaces.forEach((s, i) => { s.label = labels[i]; });
  return spaces;
}

/**
 * Owns every device connection and publishes the merged model.
 * @contract
 * @pre storage holds the v1 schema (§4); wsFactory is injectable for tests
 * @post every callback payload carries deviceId; tokens never leave this module
 * @err connection/auth failures surface as device state + lastError, not throws
 * @inv checked=false filters the model only — the connection stays up
 */
export class DeviceManager {
  /**
   * @param {Object} [opts]
   * @param {Storage} [opts.storage]
   * @param {(url:string)=>WebSocket} [opts.wsFactory]
   * @param {{baseMs:number,maxMs:number,factor:number,jitter:number}} [opts.backoff]
   * @param {number} [opts.modelDebounceMs]
   * @param {(workspaces:Object[])=>void} [opts.onModelChange]
   * @param {(devices:Object[])=>void} [opts.onDeviceChange]
   * @param {(e:{deviceId:string,uid:string,frame:Object})=>void} [opts.onBinary]
   * @param {(e:{deviceId:string,reqId:number,ok:boolean,reason:string|null})=>void} [opts.onInputResult]
   * @param {(e:{deviceId:string,code:string,message:string})=>void} [opts.onError]
   */
  constructor(opts = {}) {
    this.storage = opts.storage !== undefined ? opts.storage : globalThis.localStorage;
    this.wsFactory = opts.wsFactory;
    this.backoff = opts.backoff;
    this.modelDebounceMs = opts.modelDebounceMs ?? MODEL_DEBOUNCE_MS;

    this.onModelChange = opts.onModelChange || (() => {});
    this.onDeviceChange = opts.onDeviceChange || (() => {});
    this.onBinary = opts.onBinary || (() => {});
    this.onInputResult = opts.onInputResult || (() => {});
    this.onError = opts.onError || (() => {});

    // No checkedDevices key yet (first run / older data) → everything is checked.
    const explicit = store.hasCheckedDevices(this.storage);
    const checked = new Set(store.loadCheckedDevices(this.storage));
    const loaded = opts.seedDevices !== undefined
      ? opts.seedDevices
      : store.loadDevices(this.storage);
    this._devices = loaded
      .map((d) => ({ ...d, checked: explicit ? checked.has(d.id) : true }));

    this._clients = new Map();   // deviceId -> Client
    this._status = new Map();    // deviceId -> { state, lastError }
    this._level2 = new Map();    // deviceId -> { cwd, seq, sessions: Map<ref, {...}>, lastSeen }
    this._connected = false;
    this._modelTimer = null;
  }

  // ---- devices ----

  /** @returns {{id,name,url,checked,state,lastError}[]} ⛔ never carries token. */
  get devices() {
    return this._devices.map((d) => {
      const st = this._status.get(d.id);
      return {
        id: d.id,
        name: d.name,
        url: d.url,
        checked: d.checked,
        state: st?.state ?? ClientState.STOPPED,
        lastError: st?.lastError ?? null,
      };
    });
  }

  /** @returns {string} the new deviceId */
  addDevice({ name, url, token }) {
    const id = globalThis.crypto.randomUUID();
    this._devices.push({ id, name, url, token, checked: true });
    this._persistDevices();
    if (this._connected) this._spawn(id);
    this._emitDevices();
    this._scheduleModel();
    return id;
  }

  /** Name-only edits keep the socket; url/token edits rebuild the connection. */
  updateDevice(id, patch = {}) {
    const d = this._devices.find((x) => x.id === id);
    if (!d) return false;
    const reconnect = (patch.url !== undefined && patch.url !== d.url)
      || (patch.token !== undefined && patch.token !== d.token);
    if (patch.name !== undefined) d.name = patch.name;
    if (patch.url !== undefined) d.url = patch.url;
    if (patch.token !== undefined) d.token = patch.token;
    this._persistDevices();
    if (reconnect) {
      this._kill(id);
      this._status.delete(id);
      if (this._connected) this._spawn(id);
    }
    this._emitDevices();
    this._scheduleModel();
    return true;
  }

  removeDevice(id) {
    const i = this._devices.findIndex((x) => x.id === id);
    if (i < 0) return false;
    this._kill(id);
    this._devices.splice(i, 1);
    this._status.delete(id);
    this._level2.delete(id);
    this._persistDevices();
    store.forgetDevice(id, this.storage);
    this._emitDevices();
    this._scheduleModel();
    return true;
  }

  /** Display filter only — the connection stays up so re-checking is instant. */
  setChecked(id, checked) {
    const d = this._devices.find((x) => x.id === id);
    if (!d || d.checked === checked) return false;
    d.checked = checked === true;
    store.saveCheckedDevices(this._devices.filter((x) => x.checked).map((x) => x.id), this.storage);
    this._emitDevices();
    this._scheduleModel();
    return true;
  }

  // ---- connections ----

  connectAll() {
    this._connected = true;
    for (const d of this._devices) {
      if (!this._clients.has(d.id)) this._spawn(d.id);
      else this._clients.get(d.id).connect(); // no-op unless STOPPED
    }
  }

  disconnectAll() {
    this._connected = false;
    for (const id of [...this._clients.keys()]) this._kill(id);
    this._emitDevices();
  }

  /** Retry a device that gave up (bad token, explicit stop). */
  reconnect(id) {
    const c = this._clients.get(id);
    if (!c) {
      if (!this._devices.some((d) => d.id === id)) return false;
      this._spawn(id);
      return true;
    }
    this._setStatus(id, { lastError: null, authRejected: false });
    c.connect();
    return true;
  }

  isReady(deviceId) {
    return this._clients.get(deviceId)?.isReady === true;
  }

  // ---- aggregated model ----

  /** @returns {Object[]} AggregatedWorkspace[] for checked devices, sorted by device then cwd. */
  get workspaces() {
    const out = [];
    for (const d of this._devices) {
      if (!d.checked) continue;
      const client = this._clients.get(d.id);
      if (!client) continue;
      const lvl = this._level2.get(d.id);
      for (const w of client.workspaces) {
        const live = lvl && lvl.cwd === w.cwd ? lvl.sessions : null;
        const sessions = (w.sessions || []).map((s) => {
          const x = live?.get(s.ref);
          return {
            uid: `${d.id}::${s.ref}`,
            deviceId: d.id,
            deviceName: d.name,
            ref: s.ref,
            name: s.name,
            cwd: s.cwd,
            rows: s.rows,
            cols: s.cols,
            title: x?.title || '',
            status: x?.status || 'unknown',
            provider: providerOf(s.name, x?.provider),
          };
        });
        out.push({
          spaceKey: `${d.id}::${w.cwd}`,
          deviceId: d.id,
          deviceName: d.name,
          cwd: w.cwd,
          label: '',
          sessionCount: w.session_count ?? sessions.length,
          aggregateState: aggregateState(sessions),
          sessions,
        });
      }
    }
    out.sort((a, b) => (a.deviceName < b.deviceName ? -1 : a.deviceName > b.deviceName ? 1
      : a.cwd < b.cwd ? -1 : a.cwd > b.cwd ? 1 : 0));
    return labelSpaces(out);
  }

  space(spaceKey) {
    return this.workspaces.find((w) => w.spaceKey === spaceKey);
  }

  agent(uid) {
    for (const w of this.workspaces) {
      const s = w.sessions.find((x) => x.uid === uid);
      if (s) return s;
    }
    return undefined;
  }

  // ---- session actions (routed by uid) ----

  subscribe(uid, rows, cols) {
    const t = this._route(uid);
    return t ? t.client.subscribe(t.ref, rows, cols) : false;
  }

  unsubscribe(uid) {
    const t = this._route(uid);
    return t ? t.client.unsubscribe(t.ref) : false;
  }

  /** @returns {{deviceId:string,reqId:number}|null} */
  input(uid, text) {
    const t = this._route(uid);
    const reqId = t ? t.client.input(t.ref, text) : null;
    return reqId === null ? null : { deviceId: t.deviceId, reqId };
  }

  /** @returns {{deviceId:string,reqId:number}|null} one named key, no Enter appended. */
  keys(uid, key) {
    const t = this._route(uid);
    const reqId = t ? t.client.keys(t.ref, key) : null;
    return reqId === null ? null : { deviceId: t.deviceId, reqId };
  }

  /** @returns {{deviceId:string,reqId:number}|null} */
  scrollback(uid, fromLine, count) {
    const t = this._route(uid);
    const reqId = t ? t.client.scrollback(t.ref, fromLine, count) : null;
    return reqId === null ? null : { deviceId: t.deviceId, reqId };
  }

  resize(uid, rows, cols) {
    const t = this._route(uid);
    return t ? t.client.resize(t.ref, rows, cols) : false;
  }

  /** @returns {boolean} no ack; failure is an error frame. */
  scrollWheel(uid, delta) {
    const t = this._route(uid);
    return t ? t.client.scrollWheel(t.ref, delta) : false;
  }

  /** @returns {{deviceId:string,reqId:number}|null} */
  inputAttachment(uid, path) {
    const t = this._route(uid);
    const reqId = t ? t.client.inputAttachment(t.ref, path) : null;
    return reqId === null ? null : { deviceId: t.deviceId, reqId };
  }

  /**
   * POST /upload then input.attachment_path. Token only in the Authorization
   * header — never in thrown messages.
   * @param {Blob} file
   * @param {typeof fetch} [fetchImpl]
   */
  async uploadImage(uid, file, fetchImpl = fetch) {
    if (!file || typeof file.type !== 'string' || !file.type.startsWith('image/')) {
      throw new Error('不是图片');
    }
    const t = this._route(uid);
    if (!t) throw new Error('未发送');
    const d = this._devices.find((x) => x.id === t.deviceId);
    if (!d) throw new Error('未发送');
    const url = `${wsToHttpOrigin(t.client.url)}/upload`;
    const body = new FormData();
    body.append('file', file, file.name || 'paste.png');
    let res;
    try {
      res = await fetchImpl(url, {
        method: 'POST',
        headers: { Authorization: `Bearer ${d.token}` },
        body,
      });
    } catch {
      throw new Error(sanitizeUploadError(0, true));
    }
    if (!res.ok) throw new Error(sanitizeUploadError(res.status, false));
    let json;
    try { json = await res.json(); } catch { throw new Error('上传失败'); }
    const path = json && typeof json.path === 'string' ? json.path : '';
    if (!path) throw new Error('上传失败');
    const sent = this.inputAttachment(uid, path);
    if (!sent) throw new Error('未发送');
    return sent;
  }

  // ---- level2 (titles / status / provider) ----

  /**
   * Track one workspace's live second-level view. One cwd per device (the
   * server's level2WS is single-valued): a second call overwrites the first.
   */
  subscribeLevel2(spaceKey) {
    const sep = String(spaceKey).indexOf('::');
    if (sep < 0) return false;
    const deviceId = spaceKey.slice(0, sep);
    const cwd = spaceKey.slice(sep + 2);
    const client = this._clients.get(deviceId);
    if (!client || cwd.length === 0) return false;
    if (this._level2.get(deviceId)?.cwd === cwd) return true; // already tracking: don't re-scan
    this._level2.set(deviceId, { cwd, seq: null, sessions: new Map(), lastSeen: 0 });
    this._scheduleModel();
    return client.subscribeLevel2(cwd);
  }

  unsubscribeLevel2(deviceId) {
    const client = this._clients.get(deviceId);
    if (!client) return false;
    this._level2.delete(deviceId);
    this._scheduleModel();
    return client.unsubscribeLevel2();
  }

  // ---- internals ----

  _route(uid) {
    const sep = String(uid).indexOf('::');
    if (sep < 0) return null;
    const deviceId = uid.slice(0, sep);
    const client = this._clients.get(deviceId);
    return client ? { deviceId, ref: uid.slice(sep + 2), client } : null;
  }

  _spawn(deviceId) {
    const d = this._devices.find((x) => x.id === deviceId);
    if (!d) return;
    const client = new Client({
      url: d.url,
      token: d.token,
      wsFactory: this.wsFactory,
      backoff: this.backoff,
      onStateChange: (s) => this._onState(deviceId, s),
      onFrame: (type, payload) => this._onFrame(deviceId, type, payload),
      onBinary: (frame) => this.onBinary({ deviceId, uid: `${deviceId}::${frame.ref}`, frame }),
      onLocalError: (code, message) => this.onError({ deviceId, code, message }),
      onInputResult: (reqId, ok, reason) => this.onInputResult({ deviceId, reqId, ok, reason }),
      // A rejected token closes the socket right after auth_ack; keep the
      // actionable cause instead of the generic "WebSocket closed (1005)".
      onConnectionIssue: (reason) => {
        if (this._status.get(deviceId)?.authRejected) return;
        this._setStatus(deviceId, { lastError: reason });
      },
    });
    this._clients.set(deviceId, client);
    this._status.set(deviceId, { state: ClientState.STOPPED, lastError: null });
    client.connect();
  }

  _kill(deviceId) {
    const c = this._clients.get(deviceId);
    if (!c) return;
    c.disconnect();
    this._clients.delete(deviceId);
    this._level2.delete(deviceId);
  }

  _onState(deviceId, state) {
    // Reconnect replays level2_subscribe, and the server restarts its seq with
    // it — forget the old one so the first frame back isn't read as a gap.
    const lvl = this._level2.get(deviceId);
    if (lvl && state === ClientState.READY) lvl.seq = null;
    const ok = state === ClientState.READY;
    this._setStatus(deviceId, { state, lastError: ok ? null : undefined, authRejected: ok ? false : undefined });
    this._scheduleModel();
  }

  _onFrame(deviceId, type, payload) {
    switch (type) {
      case 'auth_ack':
        if (payload.ok !== true) {
          const message = 'token 无效或已过期';
          this._setStatus(deviceId, { lastError: message, authRejected: true });
          this.onError({ deviceId, code: 'auth', message });
        }
        return;
      case 'listing':
      case 'list_delta':
        this._scheduleModel();
        return;
      case 'level2_frame':
      case 'level2_heartbeat': {
        const lvl = this._level2.get(deviceId);
        if (!lvl || lvl.cwd !== payload.workspace) return; // stale: we moved on
        const gap = lvl.seq !== null && payload.seq !== lvl.seq + 1;
        lvl.seq = payload.seq;
        lvl.lastSeen = Date.now();
        if (type === 'level2_frame') {
          // Whole-view replacement, not a delta (§2.5).
          lvl.sessions = new Map((payload.sessions || []).map((s) => [s.ref, s]));
          this._scheduleModel();
        }
        if (gap) {
          lvl.seq = null;
          this._clients.get(deviceId)?.subscribeLevel2(lvl.cwd);
        }
        return;
      }
      case 'error':
        this.onError({ deviceId, code: payload.code, message: payload.reason || payload.code });
        return;
      default:
    }
  }

  _setStatus(deviceId, patch) {
    const next = { ...(this._status.get(deviceId) || { state: ClientState.STOPPED, lastError: null, authRejected: false }) };
    for (const [k, v] of Object.entries(patch)) if (v !== undefined) next[k] = v;
    this._status.set(deviceId, next);
    this._emitDevices();
  }

  _emitDevices() {
    this.onDeviceChange(this.devices);
  }

  /** Several devices push at once; coalesce so the UI re-renders once. */
  _scheduleModel() {
    if (this._modelTimer) return;
    this._modelTimer = setTimeout(() => {
      this._modelTimer = null;
      this.onModelChange(this.workspaces);
    }, this.modelDebounceMs);
    if (this._modelTimer.unref) this._modelTimer.unref();
  }

  _persistDevices() {
    store.saveDevices(this._devices, this.storage);
    store.saveCheckedDevices(this._devices.filter((d) => d.checked).map((d) => d.id), this.storage);
  }
}

export { ClientState };
