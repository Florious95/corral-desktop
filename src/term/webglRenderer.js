/*
 * Optional WebGL renderer. customGlyphs 用几何画框线/块元素，避开字形宽度+亚像素取整。
 * 任何失败都返回 null，调用方继续用 DOM renderer（今天的行为）。
 */

import { nativeCapabilities } from '../core/nativeCapabilities.js';

let testDisableWebgl = null;

const EMPTY_GLYPH = Object.freeze({
  texturePage: 0,
  texturePosition: { x: 0, y: 0 },
  texturePositionClipSpace: { x: 0, y: 0 },
  offset: { x: 0, y: 0 },
  size: { x: 0, y: 0 },
  sizeClipSpace: { x: 0, y: 0 },
});

const patchedPrototypes = new WeakSet();
const hookedAtlases = new WeakSet();
const hookedAddons = new WeakSet();

/**
 * 供测试或能耗消融实验动态配置是否禁用 WebGL（Phase 2 单因素对比）。
 * @param {boolean|null} disabled
 */
export function setDisableWebglForTests(disabled) {
  testDisableWebgl = typeof disabled === 'boolean' ? disabled : null;
}

/**
 * 判断当前是否显式关闭 WebGL 渲染器（回退至 DOM 渲染器）。
 * 生产代码仅接受显式测试重载与环境变量，不暴露未授权 window 全局诊断后门。
 */
export function isWebglDisabled() {
  if (typeof testDisableWebgl === 'boolean') return testDisableWebgl;
  if (typeof import.meta !== 'undefined' && import.meta.env) {
    if (import.meta.env.VITE_DISABLE_WEBGL === '1' || import.meta.env.VITE_DISABLE_WEBGL === 'true') {
      return true;
    }
  }
  return false;
}

/**
 * 显式将淘汰或销毁的 Canvas 宽高置零并从 DOM 移除，促使 WebKit 立即回收底层 IOSurface 与 2D/WebGL Backing Store。
 * @param {HTMLCanvasElement|object|null|undefined} canvas
 */
export function releaseCanvasMemory(canvas) {
  if (!canvas) return;
  try {
    canvas.width = 0;
    canvas.height = 0;
    canvas.remove?.();
  } catch {}
}

/**
 * 退役指定的 TextureAtlas：
 * 1. 阻断异步 _doWarmUp (IdleTaskQueue) 继续向已退役图集的 0×0 Canvas 光栅化写入；
 * 2. 将离屏 _tmpCanvas 及所有 AtlasPage canvas 宽高显式置零（0×0）。
 * @param {object|null|undefined} atlas
 * @param {Array<object>|null} [snapshotPages]
 * @param {Array<object>|null} [snapshotActivePages]
 */
export function retireTextureAtlas(atlas, snapshotPages = null, snapshotActivePages = null) {
  if (!atlas) return;
  atlas._isRetired = true;
  atlas._didWarmUp = true;
  try {
    atlas.warmUp = () => {};
    atlas._doWarmUp = () => {};
    atlas._drawToCache = () => EMPTY_GLYPH;
  } catch {}
  if (atlas._cacheMap) {
    try {
      atlas._cacheMap.clear?.();
      atlas._cacheMap.get = () => EMPTY_GLYPH;
      atlas._cacheMap.set = () => {};
    } catch {}
  }
  if (atlas._cacheMapCombined) {
    try {
      atlas._cacheMapCombined.clear?.();
      atlas._cacheMapCombined.get = () => EMPTY_GLYPH;
      atlas._cacheMapCombined.set = () => {};
    } catch {}
  }
  if (atlas._tmpCanvas) {
    releaseCanvasMemory(atlas._tmpCanvas);
  }
  const pages = snapshotPages
    || (Array.isArray(atlas.pages) ? [...atlas.pages] : (Array.isArray(atlas._pages) ? [...atlas._pages] : []));
  for (const page of pages) {
    if (page?.canvas) releaseCanvasMemory(page.canvas);
  }
  const activePages = snapshotActivePages
    || (Array.isArray(atlas._activePages) ? [...atlas._activePages] : []);
  for (const page of activePages) {
    if (page?.canvas) releaseCanvasMemory(page.canvas);
  }
  if (Array.isArray(atlas._activePages)) {
    atlas._activePages.length = 0;
  }
}

function silenceLayerInstanceAndPrototype(layer) {
  if (!layer) return;
  let proto = Object.getPrototypeOf(layer);
  while (proto && proto !== Object.prototype) {
    if (
      Object.prototype.hasOwnProperty.call(proto, '_refreshCharAtlas')
      && typeof proto._fillBottomLineAtCells === 'function'
    ) {
      try {
        proto._refreshCharAtlas = () => {};
      } catch {}
      break;
    }
    proto = Object.getPrototypeOf(proto);
  }
  try {
    layer._refreshCharAtlas = () => {};
    layer._charAtlas = undefined;
  } catch {}
}

/**
 * 在 WebglAddon 激活前挂载构造期守卫：
 * 当 BaseRenderLayer / LinkRenderLayer 在构造期调用 this._register(...) 时（早于 WebglRenderer.handleResize），
 * 立即静默其 _refreshCharAtlas，使首次创建、resize 与主题切换均不再申请冗余的 2048 图集。
 * @param {Function} Addon
 */
function installRenderLayerAtlasGuard(Addon) {
  if (typeof Addon !== 'function' || !Addon.prototype) return;
  const disposableProto = Object.getPrototypeOf(Addon.prototype);
  if (!disposableProto || typeof disposableProto._register !== 'function' || patchedPrototypes.has(disposableProto)) {
    return;
  }
  patchedPrototypes.add(disposableProto);
  const origRegister = disposableProto._register;
  disposableProto._register = function (disposable) {
    if (
      this
      && typeof this._refreshCharAtlas === 'function'
      && typeof this._fillBottomLineAtCells === 'function'
    ) {
      silenceLayerInstanceAndPrototype(this);
    }
    return origRegister.call(this, disposable);
  };
}

/**
 * 阻断 LinkRenderLayer 冗余的 2048 图集获取，消除与 WebglRenderer 设备最大尺寸图集（如 16384）在 CharAtlasCache 中的互踢颠簸（MVP M1）。
 * LinkRenderLayer 仅用于绘制超链接下划线（纯色矩形），不渲染字形，无需独立 TextureAtlas。
 * 若层上已持有非主渲染器共享的孤儿图集，立即将其退役并归零 Canvas。
 * @param {object|null} addon
 */
export function silenceRenderLayerAtlas(addon) {
  const sharedAtlas = addon?._renderer?._charAtlas;
  const layers = addon?._renderer?._renderLayers;
  if (!Array.isArray(layers)) return;
  for (const layer of layers) {
    if (!layer) continue;
    const orphanAtlas = layer._charAtlas;
    silenceLayerInstanceAndPrototype(layer);
    if (orphanAtlas && orphanAtlas !== sharedAtlas) {
      retireTextureAtlas(orphanAtlas);
    }
  }
}

/**
 * 为 TextureAtlas 实例与原型挂载淘汰页归零与 dispose 退役钩子（MVP M1）：
 * 1. 当 _mergePages / _evictAllPages 触发 onRemoveTextureAtlasCanvas 时，立即将淘汰旧页的 canvas.width/height 置 0；
 * 2. 当 TextureAtlas 被 dispose 时，立即阻断异步 _doWarmUp 绘制并将 _tmpCanvas 与全部 pages[].canvas 置 0。
 * @param {object|null|undefined} atlas
 */
export function hookTextureAtlas(atlas) {
  if (!atlas || typeof atlas !== 'object') return;
  const proto = Object.getPrototypeOf(atlas);
  if (proto && proto !== Object.prototype && !patchedPrototypes.has(proto)) {
    patchedPrototypes.add(proto);
    if (typeof proto._drawToCache === 'function') {
      const origDrawToCache = proto._drawToCache;
      proto._drawToCache = function (...args) {
        if (this._isRetired || this._onAddTextureAtlasCanvas?._disposed) {
          return EMPTY_GLYPH;
        }
        return origDrawToCache.apply(this, args);
      };
    }
    if (typeof proto.dispose === 'function') {
      const origDispose = proto.dispose;
      proto.dispose = function (...args) {
        this._isRetired = true;
        const pages = Array.isArray(this.pages) ? [...this.pages] : (Array.isArray(this._pages) ? [...this._pages] : []);
        const activePages = Array.isArray(this._activePages) ? [...this._activePages] : [];
        try {
          return origDispose.apply(this, args);
        } finally {
          retireTextureAtlas(this, pages, activePages);
        }
      };
    }
  }

  if (hookedAtlases.has(atlas)) return;
  hookedAtlases.add(atlas);

  if (typeof atlas.onRemoveTextureAtlasCanvas === 'function') {
    try {
      atlas.onRemoveTextureAtlasCanvas((canvas) => {
        releaseCanvasMemory(canvas);
      });
    } catch {}
  } else if (atlas._onRemoveTextureAtlasCanvas && typeof atlas._onRemoveTextureAtlasCanvas.event === 'function') {
    try {
      atlas._onRemoveTextureAtlasCanvas.event((canvas) => {
        releaseCanvasMemory(canvas);
      });
    } catch {}
  }

  if (Object.prototype.hasOwnProperty.call(atlas, 'dispose') && typeof atlas.dispose === 'function') {
    const origInstanceDispose = atlas.dispose;
    atlas.dispose = function (...args) {
      this._isRetired = true;
      const pages = Array.isArray(this.pages) ? [...this.pages] : (Array.isArray(this._pages) ? [...this._pages] : []);
      const activePages = Array.isArray(this._activePages) ? [...this._activePages] : [];
      try {
        return origInstanceDispose.apply(this, args);
      } finally {
        retireTextureAtlas(this, pages, activePages);
      }
    };
  }
}

/**
 * 为已激活的 WebglAddon 挂载完整图集卫生保障（MVP M1）：
 * 1. 静默 LinkRenderLayer 的 2048 冲突图集申请；
 * 2. 监听 onRemoveTextureAtlasCanvas，将 _mergePages / _evictAllPages 淘汰的旧 AtlasPage Canvas 显式置零；
 * 3. 拦截 WebglRenderer._refreshCharAtlas，确保后续主题/字号/DPR 切换产生的新 TextureAtlas 同样受控；
 * 4. 在终端最终销毁调用 addon.dispose() 时，归零主画布、图层画布及已无持有者的图集画布。
 * @param {object|null} addon
 */
export function installAtlasMemoryHygiene(addon) {
  if (!addon || typeof addon !== 'object') return;
  silenceRenderLayerAtlas(addon);
  const renderer = addon._renderer;
  if (renderer?._charAtlas) {
    hookTextureAtlas(renderer._charAtlas);
  }
  if (renderer) {
    const rendererProto = Object.getPrototypeOf(renderer);
    if (rendererProto && rendererProto !== Object.prototype && !patchedPrototypes.has(rendererProto)) {
      if (typeof rendererProto._refreshCharAtlas === 'function') {
        patchedPrototypes.add(rendererProto);
        const origRefresh = rendererProto._refreshCharAtlas;
        rendererProto._refreshCharAtlas = function (...args) {
          const res = origRefresh.apply(this, args);
          if (this._charAtlas) hookTextureAtlas(this._charAtlas);
          return res;
        };
      }
    }
  }

  if (hookedAddons.has(addon)) return;
  hookedAddons.add(addon);

  if (typeof addon.onRemoveTextureAtlasCanvas === 'function') {
    try {
      addon.onRemoveTextureAtlasCanvas((canvas) => {
        releaseCanvasMemory(canvas);
      });
    } catch {}
  }

  if (typeof addon.dispose === 'function') {
    const origAddonDispose = addon.dispose;
    addon.dispose = function (...args) {
      const curRenderer = this._renderer;
      const mainCanvas = curRenderer?._canvas;
      const layers = Array.isArray(curRenderer?._renderLayers) ? [...curRenderer._renderLayers] : [];
      const atlas = curRenderer?._charAtlas;
      try {
        return origAddonDispose.apply(this, args);
      } finally {
        if (mainCanvas) releaseCanvasMemory(mainCanvas);
        for (const layer of layers) {
          if (layer?._canvas) releaseCanvasMemory(layer._canvas);
          if (layer) layer._charAtlas = undefined;
        }
        if (atlas && (atlas._isRetired || atlas._onAddTextureAtlasCanvas?._disposed)) {
          retireTextureAtlas(atlas);
        }
      }
    };
  }
}

/**
 * @param {{ loadAddon: Function }} term xterm instance
 * @param {() => Promise<{WebglAddon: new () => { dispose?: Function, onContextLoss?: Function }}>} [importer]
 * @param {Object} [options]
 * @param {boolean} [options.disableWebgl=false] 显式消融禁用开关
 * @returns {Promise<object|null>}
 */
export async function attachWebglRenderer(term, importer = defaultImporter, { disableWebgl = false } = {}) {
  if (!term || typeof term.loadAddon !== 'function') return null;
  // Windows WebView2 下禁用 WebGL，使用原生 DirectWrite DOM 渲染器，彻底消除 GPU 进程 1GB+ 纹理显存膨胀（Issue #198）
  if (nativeCapabilities.platform === 'windows') {
    return null;
  }
  // Phase 2 消融通道：支持显式参数、环境变量或全局配置禁用 WebGL，供真实 macOS 交付包进行 WebGL vs DOM 能耗与吞吐单因素对比
  if (disableWebgl || isWebglDisabled()) {
    return null;
  }
  try {
    const mod = await importer();
    const Addon = mod && mod.WebglAddon;
    if (typeof Addon !== 'function') return null;
    installRenderLayerAtlasGuard(Addon);
    const addon = new Addon();
    if (typeof addon.onContextLoss === 'function') {
      addon.onContextLoss(() => {
        try { addon.dispose(); } catch { /* keep DOM cells already on screen */ }
      });
    }
    term.loadAddon(addon);
    installAtlasMemoryHygiene(addon);
    if (!webglSurfaceOk(term)) {
      try { addon.dispose(); } catch { /* stay on DOM */ }
      return null;
    }
    return addon;
  } catch {
    return null;
  }
}

/** loadAddon 没抛但 canvas 0×0 / 不在 DOM，算渲染失败，必须回退。 */
export function webglSurfaceOk(term) {
  const el = term && term.element;
  if (!el) return false;
  const canvas = el.querySelector('.xterm-screen canvas');
  if (!canvas) return false;
  const r = canvas.getBoundingClientRect();
  return r.width >= 2 && r.height >= 2;
}

function defaultImporter() {
  return import('@xterm/addon-webgl');
}
