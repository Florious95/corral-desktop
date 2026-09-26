/*
 * DeviceManager — the single boundary between the UI and the protocol layer
 * (CLIENT-CONTRACT §2).
 *
 * One agentmirrord connection = one Device = one core Client. The manager
 * owns N of them and publishes one merged, device-tagged model. Addressing is
 * always by uid (`${deviceId}::${ref}`) / spaceKey (`${deviceId}::${cwd}`):
 * bare refs must never cross device boundaries, two hosts collide on
 * `socket\x1f%paneId` far too easily.
 *
 * What this layer does NOT do: re-implement seq recovery, backoff or
 * subscription replay — the core Client already owns those (§3.6, §3.7).
 */

import { Client, ClientState } from './client.js';
import { inferCanonicalProvider, normalizeProvider, DEFAULT_LAUNCHERS } from './providers.js';
import { uploadImage } from './upload.js';
import { DEFAULT_LOCAL_DEVICE, isLocalUrl } from './local.js';
import { buildPairingPayload } from './pairing.js';
import { normalizeCwd, isSameSpaceKey, windowsToWsl } from '../lib/wslPath.js';
import { safeRandomUUID } from '../lib/uuid.js';
import * as store from './store.js';

const MODEL_DEBOUNCE_MS = 100;

/** Client-side workspace aggregate (§0.2): the server no longer computes it. */
const VALID_STATUSES = new Set(['working', 'idle']);

/**
 * 全局状态解析与闭集归一（2026-09-17 裁定）：
 * 1. listing / list_delta 为全局单一状态真相源：只要显式携带 activity 或 status（包括 'unknown'），权威以其为准，绝不被旧 level2 覆盖；
 * 2. 仅当 listing 完全缺少状态字段时（兼容旧协议），才允许 level2 补充状态；
 * 3. 闭集归一：仅 'working' 与 'idle' 保留，非法值或未知值一律归一为 'unknown'。
 */
export function normalizeSessionStatus(session, liveSession) {
  if (!session || typeof session !== 'object') return 'unknown';
  let raw;
  if (session.activity !== undefined) {
    raw = session.activity;
  } else if (session.status !== undefined) {
    raw = session.status;
  } else if (liveSession?.status !== undefined) {
    raw = liveSession.status;
  }
  return VALID_STATUSES.has(raw) ? raw : 'unknown';
}

function aggregateState(sessions) {
  if (sessions.some((s) => s.status === 'working' || s.state === 'working')) return 'working';
  if (sessions.some((s) => s.status === 'idle' || s.state === 'idle')) return 'idle';
  return 'unknown';
}

/**
 * Provider DTOs are authoritative. Only a completely absent provider field
 * uses the old session-name inference fallback; explicit unknown/invalid
 * values fail closed instead of being replaced by a title-derived provider.
 * Pi sessions (name 'pi' or pi-semantic) are recognised even when server reports unknown or empty.
 */
export function providerOf(name, serverProvider) {
  if (serverProvider === undefined || serverProvider === null || serverProvider === '') {
    return inferCanonicalProvider(name);
  }
  const norm = normalizeProvider(serverProvider);
  if (norm === 'unknown') {
    const inferred = inferCanonicalProvider(name);
    if (inferred === 'pi' || name === 'pi') {
      return 'pi';
    }
  }
  return norm;
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
 *      except an explicit createPairingPayload() QR handoff
 * @err connection/auth failures surface as device state + lastError, not throws
 * @inv checked=false filters the model only — the connection stays up
 */
export class DeviceManager {
  /**
   * @param {Object} [opts]
   * @param {Storage} [opts.storage]
   * @param {(url:string)=>WebSocket} [opts.wsFactory]
   * @param {boolean} [opts.autoLocal] add the default loopback Local device
   * @param {{baseMs:number,maxMs:number,factor:number,jitter:number}} [opts.backoff]
   * @param {number} [opts.modelDebounceMs]
   * @param {(workspaces:Object[])=>void} [opts.onModelChange]
   * @param {(devices:Object[])=>void} [opts.onDeviceChange]
   * @param {(e:{deviceId:string,uid:string,frame:Object})=>void} [opts.onBinary]
   * @param {(e:{deviceId:string,reqId:number,ok:boolean,reason:string|null})=>void} [opts.onInputResult]
   * @param {(e:{deviceId:string,kind:string,reqId:number,payload:Object})=>void} [opts.onLifecycleResult]
   * @param {(deviceId:string)=>void} [opts.onCapabilityChange]
   * @param {(e:{deviceId:string,code:string,message:string})=>void} [opts.onError]
   */
  constructor(opts = {}) {
    this.storage = opts.storage !== undefined ? opts.storage : globalThis.localStorage;
    this.wsFactory = opts.wsFactory;
    this.backoff = opts.backoff;
    this.nativeInvoke = opts.nativeInvoke;
    this.fetchImpl = opts.fetchImpl;
    this.cryptoImpl = opts.cryptoImpl;
    this.modelDebounceMs = opts.modelDebounceMs ?? MODEL_DEBOUNCE_MS;

    this.onModelChange = opts.onModelChange || (() => {});
    this.onDeviceChange = opts.onDeviceChange || (() => {});
    this.onBinary = opts.onBinary || (() => {});
    this.onInputResult = opts.onInputResult || (() => {});
    this.onLifecycleResult = opts.onLifecycleResult || (() => {});
    this.onCapabilityChange = opts.onCapabilityChange || (() => {});
    this.onError = opts.onError || (() => {});
    this.onPresenceUpdate = opts.onPresenceUpdate || (() => {});

    // No checkedDevices key yet (first run / older data) → everything is checked.
    const explicit = store.hasCheckedDevices(this.storage);
    const checked = new Set(store.loadCheckedDevices(this.storage));
    const loaded = opts.seedDevices !== undefined
      ? opts.seedDevices
      : store.loadDevices(this.storage);
    this._devices = loaded
      .map((d) => ({
        ...d,
        url: d.id === 'local' && (d.url === 'ws://localhost:9900/ws' || d.url === 'ws://127.0.0.1:9900/ws')
          ? DEFAULT_LOCAL_DEVICE.url
          : d.url,
        checked: explicit ? checked.has(d.id) : true,
      }));
    // Production opts in to keeping one trusted loopback target available;
    // tests remain isolated unless they explicitly request local discovery.
    if (opts.autoLocal === true && !this._devices.some((d) => isLocalUrl(d.url))) {
      this._devices.push({ ...DEFAULT_LOCAL_DEVICE, checked: true });
    }

    this._clients = new Map();   // deviceId -> Client
    this._status = new Map();    // deviceId -> { state, lastError }
    this._level2 = new Map();    // deviceId -> { cwd, seq, sessions: Map<ref, {...}>, lastSeen }
    this._listingFresh = new Map(); // deviceId -> boolean: 本代 listing 首帧是否已有效就绪
    this._launchers = new Map(); // deviceId -> auth_ack.agent_launchers
    this._sessionDetails = new Map(); // uid -> { name, title, cwd, rows, cols, status, provider }
    this._localHostIdentity = null; // { host_id, name, port } from /pair/whoami
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
    const id = safeRandomUUID(this.cryptoImpl);
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
    const changed = (patch.name !== undefined && patch.name !== d.name)
      || (patch.url !== undefined && patch.url !== d.url)
      || (patch.token !== undefined && patch.token !== d.token);
    if (!changed) return true;
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
    this._launchers.delete(id);
    const prefix = `${id}::`;
    for (const uid of [...this._sessionDetails.keys()]) {
      if (uid.startsWith(prefix)) this._sessionDetails.delete(uid);
    }
    const checkedIds = this._devices.filter((x) => x.checked).map((x) => x.id);
    this._persistDevices(false);
    store.forgetDevice(id, this.storage, checkedIds);
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

  /** Connect all devices or retry/connect a specific device by ID. */
  connect(id) {
    if (!id) {
      this.connectAll();
      return true;
    }
    return this.reconnect(id);
  }

  /** Check if a device has a configured non-empty authentication token. */
  hasDeviceToken(id) {
    const d = this._devices.find((x) => x.id === id);
    return typeof d?.token === 'string' && d.token.length > 0;
  }

  /** Retrieve the device authentication token. */
  getDeviceToken(id) {
    const d = this._devices.find((x) => x.id === id);
    return typeof d?.token === 'string' ? d.token : '';
  }

  isReady(deviceId) {
    return this._clients.get(deviceId)?.isReady === true;
  }

  /**
   * Explicitly hand pairing material to the QR modal. Prefer a reachable
   * non-loopback device, then fall back to a configured loopback entry.
   * If local host identity is known, binds host_id and metadata (Issue #207).
   * @returns {{v:number,url:string,token:string,ts_authkey:string,candidates:string[],host_id?:string,port?:number,name?:string}|null}
   */
  createPairingPayload() {
    const withToken = this._devices.filter((d) => typeof d.token === 'string' && d.token.length > 0);
    const source = withToken.find((d) => !isLocalUrl(d.url)) || withToken[0];
    if (!source) return null;
    const identity = isLocalUrl(source.url) ? this._localHostIdentity : null;
    try {
      return buildPairingPayload({
        url: source.url,
        token: source.token,
        host_id: identity?.host_id,
        name: identity?.name,
        port: identity?.port,
      });
    } catch {
      return null;
    }
  }

  /** Return a token-free QR draft when the local endpoint needs manual pairing. */
  createPairingDraft() {
    const source = this._devices.find((d) => isLocalUrl(d.url)) || this._devices[0];
    if (!source) return null;
    const identity = isLocalUrl(source.url) ? this._localHostIdentity : null;
    return {
      v: 1,
      url: source.url,
      token: '',
      ts_authkey: '',
      candidates: [source.url],
      ...(identity ? {
        host_id: identity.host_id,
        name: identity.name,
        port: identity.port,
      } : {}),
    };
  }

  setLocalHostIdentity(identity) {
    if (!identity || typeof identity !== 'object') {
      this._localHostIdentity = null;
      return;
    }
    this._localHostIdentity = {
      host_id: typeof identity.host_id === 'string' ? identity.host_id.trim() : '',
      name: typeof identity.name === 'string' ? identity.name.trim() : '',
      port: Number(identity.port) || 9900,
    };
  }

  getLocalHostIdentity() {
    return this._localHostIdentity;
  }

  /**
   * Eagerly or on-demand fetch local daemon identity from /pair/whoami (Issue #207).
   */
  async fetchLocalHostIdentity() {
    const localDevice = this._devices.find((d) => isLocalUrl(d.url)) || this._devices[0];
    if (!localDevice) return null;
    const fetchFn = this.fetchImpl || globalThis.fetch;
    if (typeof fetchFn !== 'function') return null;

    try {
      let whoamiUrl = 'http://127.0.0.1:9900/pair/whoami';
      if (localDevice.url) {
        try {
          const u = new URL(localDevice.url);
          const host = u.hostname === 'localhost' ? '127.0.0.1' : (u.hostname || '127.0.0.1');
          const port = u.port || '9900';
          whoamiUrl = `http://${host}:${port}/pair/whoami`;
        } catch {}
      }

      const res = await fetchFn(whoamiUrl);
      if (!res || !res.ok) return null;
      const data = await res.json();
      if (data && data.host_id) {
        this.setLocalHostIdentity(data);
        return this._localHostIdentity;
      }
    } catch {
      return null;
    }
    return null;
  }

  /** Persist a manually supplied secure token for the next pairing handoff. */
  savePairingToken(token) {
    if (typeof token !== 'string' || token.length === 0) return false;
    const source = this._devices.find((d) => isLocalUrl(d.url)) || this._devices[0];
    if (!source) return false;
    source.token = token;
    this._persistDevices();
    return true;
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
      // 连接代新鲜度判定（2026-09-17 裁定）：
      // 客户端必须处于 READY 且已收到当前连接代的有效 listing 首帧；
      // 若处于断线、重连或重连后首帧未到，状态降级为 unknown，不报虚假 working。
      const devStatus = this._status.get(d.id);
      const isReady = devStatus ? devStatus.state === ClientState.READY : (client.isReady !== false);
      const isFresh = isReady && (this._listingFresh.has(d.id) ? this._listingFresh.get(d.id) === true : true);

      const workspaceGroups = new Map();
      for (const w of client.workspaces) {
        const normWcwd = normalizeCwd(w.cwd);
        let group = workspaceGroups.get(normWcwd);
        if (!group) {
          group = {
            cwd: normWcwd,
            sessionCount: w.session_count,
            aggregateState: w.aggregate_state,
            sessions: [],
          };
          workspaceGroups.set(normWcwd, group);
        }
        const live = lvl && normalizeCwd(lvl.cwd) === normWcwd ? lvl.sessions : null;
        for (const s of w.sessions || []) {
          const uid = `${d.id}::${s.ref}`;
          const detail = this._sessionDetails.get(uid);
          const x = live?.get(s.ref);

          // R1: 以 listing/list_delta 为全局单一真相源，绝不让旧 level2 压制全局状态
          // R4: 状态闭集归一化
          const effectiveSession = s.status ? s : (detail || s);
          const status = isFresh ? normalizeSessionStatus(effectiveSession, x) : 'unknown';
          const title = s.title || detail?.title || x?.title || '';
          const provider = x?.provider !== undefined ? x.provider : (s.provider || detail?.provider);
          const name = detail?.name ?? s.name;

          group.sessions.push({
            uid,
            deviceId: d.id,
            deviceName: d.name,
            ref: s.ref,
            name,
            cwd: normalizeCwd(s.cwd || normWcwd),
            rows: s.rows ?? detail?.rows,
            cols: s.cols ?? detail?.cols,
            title,
            status,
            state: status,
            // level2 is newer than listing when it supplies a provider; if its
            // field is absent, retain the reliable listing DTO value.
            provider: providerOf(name, provider),
          });
        }
        if (w.session_count !== undefined) {
          group.sessionCount = Math.max(group.sessionCount ?? 0, w.session_count);
        }
      }

      for (const [normWcwd, group] of workspaceGroups) {
        out.push({
          spaceKey: `${d.id}::${normWcwd}`,
          deviceId: d.id,
          deviceName: d.name,
          cwd: normWcwd,
          label: '',
          sessionCount: group.sessionCount ?? group.sessions.length,
          aggregateState: aggregateState(group.sessions),
          sessions: group.sessions,
        });
      }
    }
    out.sort((a, b) => (a.deviceName < b.deviceName ? -1 : a.deviceName > b.deviceName ? 1
      : a.cwd < b.cwd ? -1 : a.cwd > b.cwd ? 1 : 0));
    return labelSpaces(out);
  }

  space(spaceKey) {
    return this.workspaces.find((w) => isSameSpaceKey(w.spaceKey, spaceKey));
  }

  agent(uid) {
    for (const w of this.workspaces) {
      const s = w.sessions.find((x) => x.uid === uid);
      if (s) return s;
    }
    return undefined;
  }

  /** 直通查询指定会话状态快照 */
  getSessionStatus(uid) {
    const s = this.agent(uid);
    return s ? { status: s.status, state: s.state, title: s.title, provider: s.provider } : null;
  }

  /** 直通全域会话状态快照映射 */
  get globalSessionStatus() {
    const map = new Map();
    for (const w of this.workspaces) {
      for (const s of w.sessions || []) {
        map.set(s.uid, { status: s.status, state: s.state, title: s.title, provider: s.provider });
      }
    }
    return map;
  }

  /** Return only launchers advertised by this authenticated device, falling back to canonical defaults. */
  getAgentLaunchers(deviceId) {
    const advertised = this._launchers.get(deviceId);
    if (Array.isArray(advertised) && advertised.length > 0) {
      return advertised.map((launcher) => ({ ...launcher }));
    }
    return DEFAULT_LAUNCHERS.map((launcher) => ({ ...launcher }));
  }

  // ---- session actions (routed by uid) ----

  subscribe(uid, rows, cols, reason = 'user', opts = {}) {
    const t = this._route(uid);
    return t ? t.client.subscribe(t.ref, rows, cols, reason, opts) : false;
  }

  getPresence(uid) {
    const t = this._route(uid);
    return t ? t.client.presenceByRef.get(t.ref) || null : null;
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

  /** Send an already-uploaded absolute host path in attachment_path only. */
  inputAttachment(uid, path, text = '') {
    const t = this._route(uid);
    const reqId = t ? t.client.inputAttachment(t.ref, path, text) : null;
    return reqId === null ? null : { deviceId: t.deviceId, reqId };
  }

  inputBytes(uid, bytes) {
    const t = this._route(uid);
    const reqId = t ? t.client.inputBytes(t.ref, bytes) : null;
    return reqId === null ? null : { deviceId: t.deviceId, reqId };
  }

  /** Attach an already-uploaded absolute path without creating an input ack. */
  attachPreview(uid, path) {
    const t = this._route(uid);
    return t ? t.client.attachPreview(t.ref, path) : false;
  }

  /** Request a new Agent on the exact device/workspace/anchor selected by UI. */
  createAgent({ deviceId, workspace, anchorRef, provider, name, bypass = false }) {
    const client = this._clients.get(deviceId);
    const reqId = client?.createAgent({
      workspace, anchor_ref: anchorRef, provider, name, bypass,
    });
    return reqId === null || reqId === undefined ? null : { deviceId, reqId };
  }

  /** Request termination of exactly one uid; wire addressing stays bare ref. */
  closeSession(uid) {
    const t = this._route(uid);
    const reqId = t?.client.closeSession(t.ref);
    return reqId === null || reqId === undefined ? null : { deviceId: t.deviceId, reqId };
  }

  /** Shared Ctrl+V / file-picker chain: upload once, then leave a preview. */
  async uploadAndPreview(uid, attachment) {
    const t = this._route(uid);
    const d = this._devices.find((x) => x.id === t?.deviceId);
    if (!t || !d) throw new Error('未找到设备');
    const path = await uploadImage({
      url: d.url,
      token: d.token,
      name: attachment?.name,
      mime: attachment?.mime,
      bytes: attachment?.bytes,
      nativeInvoke: this.nativeInvoke,
      fetchImpl: this.fetchImpl,
    });
    if (!this.attachPreview(uid, path)) throw new Error('未发送图片预览');
    return { path };
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

  resize(uid, rows, cols, reason = 'fit') {
    const t = this._route(uid);
    return t ? t.client.resize(t.ref, rows, cols, reason) : false;
  }

  /** @returns {boolean} no ack; failure is an error frame. */
  scrollWheel(uid, delta) {
    const t = this._route(uid);
    return t ? t.client.scrollWheel(t.ref, delta) : false;
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
    const rawCwd = spaceKey.slice(sep + 2);
    const cwd = normalizeCwd(rawCwd);
    const client = this._clients.get(deviceId);
    if (!client || cwd.length === 0) return false;
    const existing = this._level2.get(deviceId);
    if (existing?.cwd === cwd || (existing?.cwd && normalizeCwd(existing.cwd) === cwd)) return true; // already tracking: don't re-scan
    this._level2.set(deviceId, { cwd, seq: null, sessions: new Map(), lastSeen: 0 });
    this._scheduleModel();
    return client.subscribeLevel2(cwd);
  }

  unsubscribeLevel2(deviceId) {
    if (!deviceId) {
      let any = false;
      for (const [id, client] of this._clients) {
        if (this._level2.has(id)) {
          this._level2.delete(id);
          client.unsubscribeLevel2();
          any = true;
        }
      }
      if (any) this._scheduleModel();
      return any;
    }
    const id = String(deviceId).includes('::') ? deviceId.slice(0, deviceId.indexOf('::')) : deviceId;
    const client = this._clients.get(id);
    if (!client) return false;
    this._level2.delete(id);
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
    const local = isLocalUrl(d.url);
    const token = typeof d.token === 'string' ? d.token : '';
    if (!local && token.length === 0) {
      this._status.set(deviceId, { state: ClientState.STOPPED, lastError: 'token required' });
      this._emitDevices();
      return;
    }
    const client = new Client({
      url: d.url,
      token,
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
    this._launchers.set(deviceId, []);
    this._listingFresh.set(deviceId, false);
    this._status.set(deviceId, { state: ClientState.STOPPED, lastError: null });
    client.connect();
  }

  _kill(deviceId) {
    const c = this._clients.get(deviceId);
    if (!c) return;
    c.disconnect();
    this._clients.delete(deviceId);
    this._level2.delete(deviceId);
    this._listingFresh.delete(deviceId);
    this._launchers.delete(deviceId);
  }

  _onState(deviceId, state) {
    // Reconnect replays level2_subscribe, and the server restarts its seq with
    // it — forget the old one so the first frame back isn't read as a gap.
    const lvl = this._level2.get(deviceId);
    if (lvl && state === ClientState.READY) lvl.seq = null;
    const ok = state === ClientState.READY;
    if (!ok) {
      this._listingFresh.set(deviceId, false);
      const client = this._clients.get(deviceId);
      if (client) {
        const subKeys = client.activeSubscriptions?.keys ? [...client.activeSubscriptions.keys()] : [];
        const presKeys = client.presenceByRef?.keys ? [...client.presenceByRef.keys()] : [];
        const activeRefs = new Set([...subKeys, ...presKeys]);
        for (const ref of activeRefs) {
          this.onPresenceUpdate({
            deviceId,
            uid: `${deviceId}::${ref}`,
            ref,
            hasMobile: false,
            mobileCount: 0,
            desktopCount: 0,
            disconnected: true,
          });
        }
        client.presenceByRef?.clear?.();
      }
    }
    if (!ok && (this._launchers.get(deviceId)?.length || 0) > 0) {
      this._launchers.set(deviceId, []);
      this.onCapabilityChange(deviceId);
    }
    this._setStatus(deviceId, { state, lastError: ok ? null : undefined, authRejected: ok ? false : undefined });
    this._scheduleModel();
  }

  _recordListingSessions(deviceId, payload) {
    const liveRefs = new Set();
    for (const w of payload.workspaces || []) {
      const canonicalCwd = normalizeCwd(w.cwd);
      for (const s of w.sessions || []) {
        liveRefs.add(s.ref);
        const uid = `${deviceId}::${s.ref}`;
        const canonicalSessionCwd = s.cwd ? normalizeCwd(s.cwd) : canonicalCwd;
        this._sessionDetails.set(uid, {
          ...s,
          cwd: canonicalSessionCwd,
        });
      }
    }
    const prefix = `${deviceId}::`;
    for (const uid of [...this._sessionDetails.keys()]) {
      if (uid.startsWith(prefix) && !liveRefs.has(uid.slice(prefix.length))) {
        this._sessionDetails.delete(uid);
      }
    }
  }

  _recordDeltaSessions(deviceId, payload) {
    for (const s of payload.added_sessions || []) {
      const uid = `${deviceId}::${s.ref}`;
      this._sessionDetails.set(uid, {
        ...s,
        cwd: s.cwd ? normalizeCwd(s.cwd) : s.cwd,
      });
    }
    for (const s of payload.changed_sessions || []) {
      const uid = `${deviceId}::${s.ref}`;
      const existing = this._sessionDetails.get(uid);
      const canonicalCwd = s.cwd ? normalizeCwd(s.cwd) : existing?.cwd;
      this._sessionDetails.set(uid, {
        ...existing,
        ...s,
        cwd: canonicalCwd || existing?.cwd || s.cwd,
        name: s.name !== undefined ? s.name : existing?.name,
        title: s.title !== undefined ? s.title : existing?.title,
      });
    }
    for (const ref of payload.removed_refs || []) {
      const uid = `${deviceId}::${ref}`;
      this._sessionDetails.delete(uid);
    }
  }

  _onFrame(deviceId, type, payload) {
    switch (type) {
      case 'auth_ack':
        this._launchers.set(deviceId, payload.ok === true && Array.isArray(payload.agent_launchers)
          ? payload.agent_launchers : []);
        this.onCapabilityChange(deviceId);
        if (payload.ok !== true) {
          const message = 'token 无效或已过期';
          this._setStatus(deviceId, { lastError: message, authRejected: true });
          this.onError({ deviceId, code: 'auth', message });
        }
        return;
      case 'listing':
        this._listingFresh.set(deviceId, true);
        this._recordListingSessions(deviceId, payload);
        this._scheduleModel();
        return;
      case 'list_delta':
        this._recordDeltaSessions(deviceId, payload);
        this._scheduleModel();
        return;
      case 'presence_update': {
        const uid = `${deviceId}::${payload.ref}`;
        this.onPresenceUpdate({
          deviceId,
          uid,
          ref: payload.ref,
          hasMobile: payload.has_mobile === true,
          mobileCount: payload.mobile_count ?? 0,
          desktopCount: payload.desktop_count ?? 0,
          disconnected: payload.disconnected === true,
        });
        return;
      }
      case 'create_agent_result':
        this.onLifecycleResult({ deviceId, kind: type, reqId: payload.req_id, payload });
        return;
      case 'close_session_result':
        this.onLifecycleResult({ deviceId, kind: type, reqId: payload.req_id, payload });
        return;
      case 'level2_frame':
      case 'level2_heartbeat': {
        const lvl = this._level2.get(deviceId);
        if (!lvl || normalizeCwd(lvl.cwd) !== normalizeCwd(payload.workspace)) return; // stale: we moved on
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

  _persistDevices(saveChecked = true) {
    store.saveDevices(this._devices, this.storage);
    if (saveChecked) {
      store.saveCheckedDevices(this._devices.filter((d) => d.checked).map((d) => d.id), this.storage);
    }
  }
}

export { ClientState };
