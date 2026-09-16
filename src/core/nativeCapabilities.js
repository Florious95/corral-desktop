/**
 * AgentMirror 桌面端 · 原生能力抽象层（Native Capabilities Adapter）
 *
 * 统一收敛桌面壳的原生交互，提供四项白名单能力闭集：
 * 1. window: close, minimize, toggleFullscreen, isFullscreen, setFullscreen, startDragging
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

export function getSwiftState() {
  return {
    epoch: currentEpoch,
    geometryGeneration: currentGeneration,
    surfaceRevision,
    windowState: currentWindowState,
  };
}

export function resetSwiftStateForTests() {
  currentEpoch = null;
  currentGeneration = 0;
  currentWindowState = null;
  surfaceRevision = 0;
  bootstrapPromise = null;
}

if (typeof window !== 'undefined' && !window.__nativeEventListenerRegistered) {
  window.__nativeEventListenerRegistered = true;
  window.addEventListener('agentmirror:native', (e) => {
    const detail = e?.detail;
    if (detail) {
      if (detail.epoch) currentEpoch = detail.epoch;
      if (detail.event === 'window.state' && detail.payload) {
        currentWindowState = detail.payload;
        if (typeof detail.payload.geometryGeneration === 'number') {
          currentGeneration = detail.payload.geometryGeneration;
        }
        window.dispatchEvent(new CustomEvent('agentmirror:window-state-updated', { detail: detail.payload }));
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
      if (reply && typeof reply === 'object') {
        // OPEN-3: 严格校验 reply.id 与 req.id
        if (reply.id && reply.id !== id) {
          const err = new Error('invalid_response: reply id mismatch');
          err.code = 'invalid_response';
          throw err;
        }
        // OPEN-3: 严格校验 reply.epoch 与 currentEpoch
        if (method !== 'bootstrap' && currentEpoch && reply.epoch && reply.epoch !== currentEpoch) {
          const err = new Error('stale_geometry: epoch mismatch');
          err.code = 'stale_geometry';
          throw err;
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
      return reply;
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

/**
 * 原生能力统一门面
 */
export const nativeCapabilities = {
  get environment() {
    if (testEngineOverride?.environment) {
      return typeof testEngineOverride.environment === 'function'
        ? testEngineOverride.environment()
        : testEngineOverride.environment;
    }
    return detectNativeEnvironment();
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
        const { invoke } = await import('@tauri-apps/api/core');
        const image = await invoke('read_clipboard_image');
        const bytes = image?.bytes;
        if (!image || (!Array.isArray(bytes) && !(bytes instanceof Uint8Array)) || bytes.length === 0) {
          return null;
        }
        return {
          name: image.name || 'image',
          mime: image.mime || 'image/png',
          bytes: Uint8Array.from(bytes),
        };
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
        const { invoke } = await import('@tauri-apps/api/core');
        const files = await invoke('read_clipboard_files');
        if (files == null) return [];
        if (!Array.isArray(files)) throw new Error('剪贴板文件路径无效');
        return files;
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
        const { invoke } = await import('@tauri-apps/api/core');
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
};
