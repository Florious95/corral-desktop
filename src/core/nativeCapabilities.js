/**
 * AgentMirror 桌面端 · 原生能力抽象层（Native Capabilities Adapter）
 *
 * 统一收敛桌面壳的原生交互，提供四项白名单能力闭集：
 * 1. window: close, minimize, toggleMaximize, isMaximized, maximize, unmaximize, toggleFullscreen, isFullscreen, setFullscreen, startDragging
 * 2. clipboard: readText, readImage, readFiles
 * 3. upload: uploadHttp
 * 4. secureStore: get, set（严格锁定白名单 key === 'devices'）
 *
 * 运行时自动分发：
 * - Swift 原生外壳: window.webkit.messageHandlers.native
 * - Tauri 桌面外壳: window.__TAURI_INTERNALS__
 * - Web / Mock 降级: Node.js 单元测试与无原生环境浏览器
 */

export function uint8ArrayToBase64(bytes) {
  if (!bytes) return '';
  const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  if (typeof Buffer !== 'undefined') {
    return Buffer.from(u8.buffer, u8.byteOffset, u8.byteLength).toString('base64');
  }
  let binary = '';
  const len = u8.byteLength;
  for (let i = 0; i < len; i++) {
    binary += String.fromCharCode(u8[i]);
  }
  return btoa(binary);
}

export function base64ToUint8Array(base64) {
  if (!base64 || typeof base64 !== 'string') return new Uint8Array(0);
  if (typeof Buffer !== 'undefined') {
    const buf = Buffer.from(base64, 'base64');
    return new Uint8Array(buf.buffer, buf.byteOffset, buf.byteLength);
  }
  const binary = atob(base64);
  const len = binary.length;
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

let rpcSeq = 0;
const pendingRpc = new Map();

let currentEpoch = null;
let currentGeneration = 0;
let currentWindowState = null;
let surfaceRevision = 0;
let bootstrapPromise = null;

let lastEventSeq = -1;

export function getSwiftState() {
  return {
    epoch: currentEpoch,
    geometryGeneration: currentGeneration,
    surfaceRevision,
    windowState: currentWindowState,
    lastEventSeq,
  };
}

export function resetSwiftStateForTests() {
  currentEpoch = null;
  currentGeneration = 0;
  currentWindowState = null;
  surfaceRevision = 0;
  bootstrapPromise = null;
  lastEventSeq = -1;
}

if (typeof window !== 'undefined' && !window.__nativeEventListenerRegistered) {
  window.__nativeEventListenerRegistered = true;
  window.addEventListener('agentmirror:native', (e) => {
    const detail = e?.detail;
    if (detail && typeof detail === 'object') {
      // 1. Version check: only v1 supported
      if (detail.v !== 1) return;
      // 2. Epoch check: must have valid epoch matching current
      if (typeof detail.epoch !== 'string' || !detail.epoch) return;
      if (currentEpoch && detail.epoch !== currentEpoch) return;
      // 3. Sequence check: must be strictly monotonic (no duplicates, no backwards)
      if (typeof detail.seq !== 'number' || detail.seq <= lastEventSeq) return;

      lastEventSeq = detail.seq;
      if (!currentEpoch) currentEpoch = detail.epoch;

      if (detail.event === 'window.state' && detail.payload) {
        currentWindowState = detail.payload;
        if (typeof detail.payload.geometryGeneration === 'number') {
          currentGeneration = detail.payload.geometryGeneration;
        }
        window.dispatchEvent(new CustomEvent('agentmirror:window-state-updated', { detail: detail.payload }));
      }
      if (detail.event === 'window.resizeSettled') {
        window.dispatchEvent(new CustomEvent('agentmirror:window-resize-settled'));
      }
    }
  });
}

function ensureSwiftCallback() {
  if (typeof window !== 'undefined' && !window.__nativeCallback) {
    window.__nativeCallback = (id, result, error, meta) => {
      const p = pendingRpc.get(id);
      if (!p) return; // id 不匹配或已被处理直接作废丢弃
      pendingRpc.delete(id);

      // OPEN-3: 严格校验 epoch 匹配
      const replyEpoch = meta?.epoch || (result && typeof result === 'object' ? result.epoch : null);
      if (p.method !== 'bootstrap' && currentEpoch && replyEpoch && replyEpoch !== currentEpoch) {
        const err = new Error('stale_geometry: epoch mismatch');
        err.code = 'stale_geometry';
        p.reject(err);
        return;
      }

      if (error) {
        const err = new Error(typeof error === 'string' ? error : error?.message || 'RPC failed');
        if (error?.code) err.code = error.code;
        p.reject(err);
      } else {
        p.resolve(result);
      }
    };
  }
}

async function rawCallSwiftRPC(method, params = {}, { sendEpoch = false } = {}) {
  ensureSwiftCallback();
  const id = `req-${++rpcSeq}-${Date.now()}`;
  const envelope = { v: 1, id, method, params };
  if (sendEpoch && currentEpoch) {
    envelope.epoch = currentEpoch;
  }
  const handler = window.webkit?.messageHandlers?.native;
  if (!handler || typeof handler.postMessage !== 'function') {
    const err = new Error(`Swift native handler unavailable for method ${method}`);
    err.code = 'unavailable';
    throw err;
  }

  try {
    const res = handler.postMessage(envelope);
    // Modern WKScriptMessageHandlerWithReply returns a Promise
    if (res && typeof res.then === 'function') {
      const reply = await res;
      // OPEN-3: 严格校验 reply.id 与 req.id
      if (reply && reply.id && reply.id !== id) {
        const err = new Error('invalid_response: reply id mismatch');
        err.code = 'invalid_response';
        throw err;
      }

      // OPEN-3: 严格校验 reply envelope（v === 1, id 存在且精确匹配）
      if (!reply || typeof reply !== 'object' || reply.v !== 1 || typeof reply.id !== 'string') {
        const err = new Error('invalid_response: missing or invalid reply envelope');
        err.code = 'invalid_response';
        throw err;
      }

      // OPEN-3: 严格校验 reply.epoch 与 currentEpoch
      if (method !== 'bootstrap' && currentEpoch) {
        if (!reply.epoch || reply.epoch !== currentEpoch) {
          const err = new Error('stale_geometry: missing or mismatched reply epoch');
          err.code = 'stale_geometry';
          throw err;
        }
      }

      if (reply.ok === false) {
        const code = reply.error?.code || 'unknown';
        const msg = reply.error?.message || reply.error?.code || 'RPC failed';
        const err = new Error(msg);
        err.code = code;
        throw err;
      }
      return reply.result !== undefined ? reply.result : reply;
    }
  } catch (e) {
    // If postMessage threw synchronously, propagate directly
    throw e;
  }

  // Legacy callback fallback
  return new Promise((resolve, reject) => {
    const timeoutId = setTimeout(() => {
      pendingRpc.delete(id);
      const err = new Error(`Swift RPC timeout for method ${method}`);
      err.code = 'timeout';
      reject(err);
    }, 15000);
    pendingRpc.set(id, {
      method,
      reqEpoch: currentEpoch,
      resolve: (val) => { clearTimeout(timeoutId); resolve(val); },
      reject: (err) => { clearTimeout(timeoutId); reject(err); },
    });
  });
}

export async function bootstrapSwift() {
  if (bootstrapPromise) return bootstrapPromise;
  bootstrapPromise = (async () => {
    try {
      const res = await rawCallSwiftRPC('bootstrap', {});
      if (res && typeof res === 'object') {
        currentEpoch = res.epoch || null;
        if (res.window) {
          currentWindowState = res.window;
          if (typeof res.window.geometryGeneration === 'number') {
            currentGeneration = res.window.geometryGeneration;
          }
        }
      }
      return res;
    } catch (e) {
      bootstrapPromise = null;
      throw e;
    }
  })();
  return bootstrapPromise;
}

async function callSwiftRPC(method, params = {}) {
  if (method !== 'bootstrap') {
    if (!currentEpoch) {
      await bootstrapSwift();
    }
  }
  return rawCallSwiftRPC(method, params, { sendEpoch: method !== 'bootstrap' });
}

function assertDevicesKey(key) {
  if (key !== 'devices') {
    throw new Error(`secureStore: key must be 'devices', got '${key}'`);
  }
}

// In-memory store for Web/Mock fallback
const mockSecureStore = new Map();

export function detectNativeEnvironment() {
  if (typeof window !== 'undefined' && window.webkit?.messageHandlers?.native) {
    return 'swift';
  }
  if (typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window) {
    return 'tauri';
  }
  return 'mock';
}

export function detectPlatform() {
  if (testEngineOverride?.platform) {
    return typeof testEngineOverride.platform === 'function'
      ? testEngineOverride.platform()
      : testEngineOverride.platform;
  }
  if (typeof navigator !== 'undefined') {
    const ua = navigator.userAgent || '';
    const platform = navigator.userAgentData?.platform || navigator.platform || '';
    if (/win/i.test(platform) || /windows/i.test(ua)) return 'windows';
    if (/mac/i.test(platform) || /macintosh/i.test(ua)) return 'macos';
  }
  if (typeof process !== 'undefined' && process.platform) {
    if (process.platform === 'win32') return 'windows';
    if (process.platform === 'darwin') return 'macos';
  }
  return 'unknown';
}

let testEngineOverride = null;

export function setNativeEngineForTests(engine) {
  testEngineOverride = engine;
}

export function resetNativeEngineForTests() {
  testEngineOverride = null;
  mockSecureStore.clear();
  currentEpoch = null;
  currentGeneration = 0;
  currentWindowState = null;
  surfaceRevision = 0;
  bootstrapPromise = null;
}

export const UI_SNAPSHOT_ALLOWED_KEYS = new Set([
  'am.workspace.v2',
  'am.workspace.v1',
  'am.panes',
  'am.activePane',
  'am.fav',
  'am.selected',
  'am.collapsed',
  'am.spacesOpen',
  'am.agentsOpen',
]);

export function filterUiSnapshot(raw) {
  if (!raw || typeof raw !== 'object') return {};
  const clean = {};
  for (const [k, v] of Object.entries(raw)) {
    if (UI_SNAPSHOT_ALLOWED_KEYS.has(k) && typeof v === 'string') {
      clean[k] = v;
    }
  }
  return clean;
}

/**
 * 原生能力统一门面
 */
let cachedTauriInvoke = null;
async function getTauriInvoke() {
  if (!cachedTauriInvoke) {
    const mod = await import('@tauri-apps/api/core');
    cachedTauriInvoke = mod.invoke;
  }
  return cachedTauriInvoke;
}

export const nativeCapabilities = {
  get environment() {
    if (testEngineOverride?.environment) {
      return typeof testEngineOverride.environment === 'function'
        ? testEngineOverride.environment()
        : testEngineOverride.environment;
    }
    return detectNativeEnvironment();
  },

  get platform() {
    return detectPlatform();
  },

  window: {
    async close() {
      if (testEngineOverride?.window?.close) return testEngineOverride.window.close();
      const env = detectNativeEnvironment();
      if (env === 'swift') {
        return callSwiftRPC('window.close');
      }
      if (env === 'tauri') {
        const { getCurrentWindow } = await import('@tauri-apps/api/window');
        return getCurrentWindow().close();
      }
      if (typeof window !== 'undefined' && window.opener && typeof window.close === 'function') {
        window.close();
      }
    },

    async minimize() {
      if (testEngineOverride?.window?.minimize) return testEngineOverride.window.minimize();
      const env = detectNativeEnvironment();
      if (env === 'swift') {
        return callSwiftRPC('window.minimize');
      }
      if (env === 'tauri') {
        const { getCurrentWindow } = await import('@tauri-apps/api/window');
        return getCurrentWindow().minimize();
      }
    },

    async isMaximized() {
      if (testEngineOverride?.window?.isMaximized) return testEngineOverride.window.isMaximized();
      const env = detectNativeEnvironment();
      if (env === 'tauri') {
        const { getCurrentWindow } = await import('@tauri-apps/api/window');
        return getCurrentWindow().isMaximized();
      }
      return false;
    },

    async maximize() {
      if (testEngineOverride?.window?.maximize) return testEngineOverride.window.maximize();
      const env = detectNativeEnvironment();
      if (env === 'tauri') {
        const { getCurrentWindow } = await import('@tauri-apps/api/window');
        return getCurrentWindow().maximize();
      }
      return true;
    },

    async unmaximize() {
      if (testEngineOverride?.window?.unmaximize) return testEngineOverride.window.unmaximize();
      const env = detectNativeEnvironment();
      if (env === 'tauri') {
        const { getCurrentWindow } = await import('@tauri-apps/api/window');
        return getCurrentWindow().unmaximize();
      }
      return false;
    },

    async toggleMaximize() {
      if (testEngineOverride?.window?.toggleMaximize) return testEngineOverride.window.toggleMaximize();
      if (testEngineOverride?.window?.isMaximized) {
        const max = await testEngineOverride.window.isMaximized();
        if (max) {
          if (testEngineOverride?.window?.unmaximize) await testEngineOverride.window.unmaximize();
          return false;
        } else {
          if (testEngineOverride?.window?.maximize) await testEngineOverride.window.maximize();
          return true;
        }
      }
      const env = detectNativeEnvironment();
      if (env === 'tauri') {
        const { getCurrentWindow } = await import('@tauri-apps/api/window');
        const w = getCurrentWindow();
        const max = await w.isMaximized();
        if (max) {
          await w.unmaximize();
          return false;
        } else {
          await w.maximize();
          return true;
        }
      }
      return false;
    },

    async toggleFullscreen() {
      if (testEngineOverride?.window?.toggleFullscreen) return testEngineOverride.window.toggleFullscreen();
      const env = detectNativeEnvironment();
      if (env === 'swift') {
        return callSwiftRPC('window.toggleFullscreen');
      }
      if (env === 'tauri') {
        const { getCurrentWindow } = await import('@tauri-apps/api/window');
        const w = getCurrentWindow();
        const fs = await w.isFullscreen();
        return w.setFullscreen(!fs);
      }
      if (typeof document !== 'undefined') {
        // 若浏览器支持 userActivation 且未被用户手势激活，直接安全返回 false，避免触发 Chrome 控制台警告
        if (typeof navigator !== 'undefined' && navigator.userActivation && !navigator.userActivation.isActive) {
          return false;
        }
        try {
          if (!document.fullscreenElement) {
            await document.documentElement?.requestFullscreen?.();
            return true;
          }
          await document.exitFullscreen?.();
          return false;
        } catch (_) {
          return false; // 浏览器拒绝全屏（如缺少用户手势）时安全降级，不抛出未处理异常
        }
      }
      return false;
    },

    async isFullscreen() {
      if (testEngineOverride?.window?.isFullscreen) return testEngineOverride.window.isFullscreen();
      const env = detectNativeEnvironment();
      if (env === 'swift') {
        return Boolean(await callSwiftRPC('window.isFullscreen'));
      }
      if (env === 'tauri') {
        const { getCurrentWindow } = await import('@tauri-apps/api/window');
        return getCurrentWindow().isFullscreen();
      }
      return typeof document !== 'undefined' ? Boolean(document.fullscreenElement) : false;
    },

    async setFullscreen(flag) {
      if (testEngineOverride?.window?.setFullscreen) return testEngineOverride.window.setFullscreen(flag);
      const env = detectNativeEnvironment();
      if (env === 'swift') {
        return callSwiftRPC('window.setFullscreen', { flag: Boolean(flag) });
      }
      if (env === 'tauri') {
        const { getCurrentWindow } = await import('@tauri-apps/api/window');
        return getCurrentWindow().setFullscreen(Boolean(flag));
      }
      if (typeof document !== 'undefined') {
        // 若要进入全屏，且浏览器支持 userActivation 但当前未激活手势，直接安全返回 false，避免触发 Chrome 控制台警告
        if (flag && typeof navigator !== 'undefined' && navigator.userActivation && !navigator.userActivation.isActive) {
          return false;
        }
        try {
          if (flag && !document.fullscreenElement) {
            await document.documentElement?.requestFullscreen?.();
            return true;
          }
          if (!flag && document.fullscreenElement) {
            await document.exitFullscreen?.();
            return false;
          }
        } catch (_) {
          return false; // 浏览器拒绝全屏（如缺少用户手势）时安全降级，不抛出未处理异常
        }
      }
      return false;
    },

    async startDragging() {
      if (testEngineOverride?.window?.startDragging) return testEngineOverride.window.startDragging();
      const env = detectNativeEnvironment();
      if (env === 'swift') {
        return callSwiftRPC('window.startDragging');
      }
      if (env === 'tauri') {
        const { getCurrentWindow } = await import('@tauri-apps/api/window');
        return getCurrentWindow().startDragging();
      }
    },
  },

  clipboard: {
    async readText() {
      if (testEngineOverride?.clipboard?.readText) return testEngineOverride.clipboard.readText();
      const env = detectNativeEnvironment();
      if (env === 'swift') {
        const text = await callSwiftRPC('clipboard.readText');
        return typeof text === 'string' ? text : '';
      }
      if (typeof navigator !== 'undefined' && navigator.clipboard?.readText) {
        try {
          return await navigator.clipboard.readText();
        } catch {
          return '';
        }
      }
      return '';
    },

    async readImage() {
      if (testEngineOverride?.clipboard?.readImage) return testEngineOverride.clipboard.readImage();
      const env = detectNativeEnvironment();
      if (env === 'swift') {
        const result = await callSwiftRPC('clipboard.image', {});
        if (!result) return null;
        let bytes;
        if (result.bytes instanceof Uint8Array) {
          bytes = result.bytes;
        } else if (typeof result.bytesBase64 === 'string') {
          bytes = base64ToUint8Array(result.bytesBase64);
        } else if (Array.isArray(result.bytes)) {
          bytes = Uint8Array.from(result.bytes);
        }
        if (!bytes || bytes.length === 0) return null;
        return {
          name: result.name || 'image',
          mime: result.mime || 'image/png',
          bytes,
        };
      }
      if (env === 'tauri') {
        try {
          const { invoke } = await import('@tauri-apps/api/core');
          const image = await invoke('read_clipboard_image');
          const bytes = image?.bytes;
          if (image && (Array.isArray(bytes) || bytes instanceof Uint8Array) && bytes.length > 0) {
            return {
              name: image.name || 'image',
              mime: image.mime || 'image/png',
              bytes: Uint8Array.from(bytes),
            };
          }
        } catch {
          // Native command not supported or failed on this platform, fall through
        }
      }
      if (typeof navigator !== 'undefined' && navigator.clipboard?.read) {
        try {
          const items = await navigator.clipboard.read();
          for (const item of items) {
            const imageType = item.types?.find((t) => t.startsWith('image/'));
            if (imageType) {
              const blob = await item.getType(imageType);
              const buffer = await blob.arrayBuffer();
              const bytes = new Uint8Array(buffer);
              if (bytes.length > 0) {
                return {
                  name: 'clipboard.png',
                  mime: imageType,
                  bytes,
                };
              }
            }
          }
        } catch {
          // Permissions or no image available
        }
      }
      return null;
    },

    async readFiles() {
      if (testEngineOverride?.clipboard?.readFiles) return testEngineOverride.clipboard.readFiles();
      const env = detectNativeEnvironment();
      if (env === 'swift') {
        const files = await callSwiftRPC('clipboard.files', {});
        if (files == null) return [];
        if (!Array.isArray(files)) throw new Error('剪贴板文件路径无效');
        return files;
      }
      if (env === 'tauri') {
        try {
          const { invoke } = await import('@tauri-apps/api/core');
          const files = await invoke('read_clipboard_files');
          if (files == null) return [];
          if (!Array.isArray(files)) throw new Error('剪贴板文件路径无效');
          return files;
        } catch {
          return [];
        }
      }
      return [];
    },
  },

  upload: {
    async uploadHttp({ url, token, filename, mime, bytes, body, bytesBase64, deviceId } = {}) {
      if (testEngineOverride?.upload?.uploadHttp) {
        return testEngineOverride.upload.uploadHttp({ url, token, filename, mime, bytes, body, bytesBase64, deviceId });
      }
      const safeFilename = filename || 'image';
      const safeMime = mime || 'application/octet-stream';

      let dataBytes = bytes || body;
      if (!dataBytes && bytesBase64) {
        dataBytes = base64ToUint8Array(bytesBase64);
      }
      if (!dataBytes) {
        throw new Error('invalid_file: empty upload bytes');
      }
      const u8 = dataBytes instanceof Uint8Array ? dataBytes : new Uint8Array(dataBytes);
      if (u8.length === 0) {
        throw new Error('invalid_file: empty upload bytes');
      }

      const env = detectNativeEnvironment();
      if (env === 'swift') {
        const payload = {
          url,
          token,
          deviceId: deviceId || '',
          filename: safeFilename,
          mime: safeMime,
          bytesBase64: bytesBase64 || uint8ArrayToBase64(u8),
        };
        const result = await callSwiftRPC('upload', payload);
        const path = typeof result === 'string' ? result : result?.path;
        if (!path || typeof path !== 'string') {
          throw new Error('invalid_response: missing upload path');
        }
        return path;
      }

      if (env === 'tauri') {
        const invoke = await getTauriInvoke();
        const result = await invoke('upload_http', {
          url,
          token,
          filename: safeFilename,
          mime: safeMime,
          bytes: Array.from(u8),
        });
        const path = typeof result === 'string' ? result : result?.path;
        if (!path || typeof path !== 'string') {
          throw new Error('invalid_response: missing upload path');
        }
        return path;
      }

      // Web / Mock fallback
      if (typeof fetch === 'function') {
        const body = new FormData();
        body.append('file', new Blob([u8], { type: safeMime }), safeFilename);
        const response = await fetch(url, {
          method: 'POST',
          headers: token ? { Authorization: `Bearer ${token}` } : {},
          body,
        });
        if (!response.ok) {
          throw new Error(`HTTP ${response.status}`);
        }
        const json = await response.json();
        if (!json?.path) throw new Error('invalid_response: missing path');
        return json.path;
      }
      throw new Error('upload unavailable in current environment');
    },
  },

  secureStore: {
    async get(key) {
      assertDevicesKey(key);
      if (testEngineOverride?.secureStore?.get) return testEngineOverride.secureStore.get(key);
      const env = detectNativeEnvironment();
      if (env === 'swift') {
        const res = await callSwiftRPC('devices.load', {});
        if (Array.isArray(res)) return res;
        if (res && Array.isArray(res.devices)) return res.devices;
        return res || [];
      }
      if (env === 'tauri') {
        const { load } = await import('@tauri-apps/plugin-store');
        const s = await load('devices.json', { autoSave: false });
        return s.get('devices');
      }
      return mockSecureStore.get(key) || null;
    },

    async set(key, value) {
      assertDevicesKey(key);
      if (!Array.isArray(value)) {
        throw new Error('secureStore: devices must be an array');
      }
      if (testEngineOverride?.secureStore?.set) return testEngineOverride.secureStore.set(key, value);
      const env = detectNativeEnvironment();
      if (env === 'swift') {
        await callSwiftRPC('devices.save', { devices: value });
        return true;
      }
      if (env === 'tauri') {
        const { load } = await import('@tauri-apps/plugin-store');
        const { invoke } = await import('@tauri-apps/api/core');
        const s = await load('devices.json', { autoSave: false });
        await s.set('devices', value);
        await s.save();
        await invoke('lock_devices_file');
        return true;
      }
      mockSecureStore.set(key, JSON.parse(JSON.stringify(value)));
      return true;
    },
  },

  surface: {
    async update(params = {}) {
      if (testEngineOverride?.surface?.update) {
        return testEngineOverride.surface.update(params);
      }
      const env = detectNativeEnvironment();
      if (env === 'swift') {
        if (!currentEpoch) {
          await bootstrapSwift();
        }

        const generation = typeof params.geometryGeneration === 'number'
          ? params.geometryGeneration
          : currentGeneration;

        const rev = typeof params.revision === 'number' ? params.revision : ++surfaceRevision;

        if (params.phase === 'disarm') {
          const disarmPayload = {
            phase: 'disarm',
            geometryGeneration: generation,
            revision: rev,
          };
          return callSwiftRPC('surface.update', disarmPayload);
        }

        const vp = params.viewportCSS || {
          width: typeof window !== 'undefined' ? window.innerWidth : 0,
          height: typeof window !== 'undefined' ? window.innerHeight : 0,
        };
        const dpr = (currentWindowState && typeof currentWindowState.devicePixelRatio === 'number')
          ? currentWindowState.devicePixelRatio
          : (params.devicePixelRatio || (typeof window !== 'undefined' ? window.devicePixelRatio : 1) || 1);

        const viewportWidth = (currentWindowState?.viewportCSS?.width && typeof currentWindowState.viewportCSS.width === 'number')
          ? Math.round(currentWindowState.viewportCSS.width)
          : Math.round(vp.width || 0);

        const viewportHeight = (currentWindowState?.viewportCSS?.height && typeof currentWindowState.viewportCSS.height === 'number')
          ? Math.round(currentWindowState.viewportCSS.height)
          : Math.round(vp.height || 0);

        const dragRects = (params.dragRects || []).map((r) => ({
          x: Math.max(0, Math.round(r.x)),
          y: Math.max(0, Math.round(r.y)),
          width: Math.max(0, Math.round(r.width)),
          height: Math.max(0, Math.round(r.height)),
        }));

        const exclusionRects = (params.exclusionRects || []).map((r) => ({
          x: Math.max(0, Math.round(r.x)),
          y: Math.max(0, Math.round(r.y)),
          width: Math.max(0, Math.round(r.width)),
          height: Math.max(0, Math.round(r.height)),
        }));

        // chromeRect must strictly contain all dragRects
        let maxDragY = 38;
        for (const r of dragRects) {
          if (r.y + r.height > maxDragY) {
            maxDragY = r.y + r.height;
          }
        }
        const chromeRect = params.chromeRect ? {
          x: Math.max(0, Math.round(params.chromeRect.x)),
          y: Math.max(0, Math.round(params.chromeRect.y)),
          width: Math.max(0, Math.round(params.chromeRect.width)),
          height: Math.max(0, Math.round(params.chromeRect.height)),
        } : {
          x: 0,
          y: 0,
          width: viewportWidth,
          height: Math.min(viewportHeight, maxDragY),
        };

        const payload = {
          phase: params.phase || 'arm',
          geometryGeneration: generation,
          revision: rev,
          viewportCSS: {
            width: viewportWidth,
            height: viewportHeight,
          },
          devicePixelRatio: params.devicePixelRatio || (typeof window !== 'undefined' ? window.devicePixelRatio : 1) || 1,
          dragRects,
          exclusionRects,
          chromeRect,
        };

        return callSwiftRPC('surface.update', payload);
      }
      return { ok: true };
    },
  },

  migration: {
    async loadUI() {
      if (testEngineOverride?.migration?.loadUI) return testEngineOverride.migration.loadUI();
      const env = detectNativeEnvironment();
      if (env === 'swift') {
        const res = await callSwiftRPC('migration.loadUI', {});
        return res || null;
      }
      return null;
    },

    async saveUI(snapshot) {
      if (testEngineOverride?.migration?.saveUI) return testEngineOverride.migration.saveUI(snapshot);
      const cleanSnapshot = filterUiSnapshot(snapshot);
      const env = detectNativeEnvironment();
      if (env === 'swift') {
        await callSwiftRPC('migration.saveUI', { snapshot: cleanSnapshot });
        return true;
      }
      if (env === 'tauri') {
        try {
          const { load } = await import('@tauri-apps/plugin-store');
          const s = await load('ui-snapshot-v1.json', { autoSave: false });
          await s.set('version', 1);
          await s.set('values', cleanSnapshot);
          await s.save();
          return true;
        } catch (_) {
          return false;
        }
      }
      return false;
    },
  },

  wsl: {
    async checkEnvironment() {
      if (testEngineOverride?.wsl?.checkEnvironment) {
        return testEngineOverride.wsl.checkEnvironment();
      }
      const platform = detectPlatform();
      const env = detectNativeEnvironment();
      if (platform === 'windows' && env === 'tauri') {
        try {
          const { invoke } = await import('@tauri-apps/api/core');
          const status = await invoke('check_wsl_environment');
          if (status && typeof status === 'object') {
            return {
              wsl_installed: Boolean(status.wsl_installed),
              ubuntu_installed: Boolean(status.ubuntu_installed),
              ubuntu_running: Boolean(status.ubuntu_running),
              tmux_installed: Boolean(status.tmux_installed),
              service_installed: Boolean(status.service_installed),
              service_running: Boolean(status.service_running),
              wsl_ip: typeof status.wsl_ip === 'string' ? status.wsl_ip : null,
            };
          }
        } catch (_) {
          // Tauri invoke 失败安全降级
        }
      }
      return {
        wsl_installed: false,
        ubuntu_installed: false,
        ubuntu_running: false,
        tmux_installed: false,
        service_installed: false,
        service_running: false,
        wsl_ip: null,
      };
    },

    async startService(serviceName = 'agentmirrord') {
      if (testEngineOverride?.wsl?.startService) {
        return testEngineOverride.wsl.startService(serviceName);
      }
      const platform = detectPlatform();
      const env = detectNativeEnvironment();
      if (platform === 'windows' && env === 'tauri') {
        const { invoke } = await import('@tauri-apps/api/core');
        return invoke('start_wsl_service', {
          service_cmd: serviceName,
          serviceCmd: serviceName,
          service: serviceName,
        });
      }
      const err = new Error('unsupported_platform: WSL2 is available on Windows only');
      err.code = 'unsupported_platform';
      throw err;
    },

    async readServiceToken() {
      if (testEngineOverride?.wsl?.readServiceToken) {
        return testEngineOverride.wsl.readServiceToken();
      }
      const platform = detectPlatform();
      const env = detectNativeEnvironment();
      if (platform === 'windows' && env === 'tauri') {
        try {
          const { invoke } = await import('@tauri-apps/api/core');
          let token;
          try {
            token = await invoke('get_wsl_pairing_token');
          } catch (_) {
            // Older installed shells expose the pre-alias command name.
            token = await invoke('read_wsl_service_token');
          }
          return typeof token === 'string' && token.trim().length > 0 ? token.trim() : null;
        } catch (_) {
          return null;
        }
      }
      return null;
    },

    async installService() {
      if (testEngineOverride?.wsl?.installService) {
        return testEngineOverride.wsl.installService();
      }
      const platform = detectPlatform();
      const env = detectNativeEnvironment();
      if (platform === 'windows' && env === 'tauri') {
        const { invoke } = await import('@tauri-apps/api/core');
        return invoke('install_wsl_service');
      }
      const err = new Error('unsupported_platform: WSL2 is available on Windows only');
      err.code = 'unsupported_platform';
      throw err;
    },
  },
};
