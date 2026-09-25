/*
 * Optional WebGL renderer. customGlyphs 用几何画框线/块元素，避开字形宽度+亚像素取整。
 * 任何失败都返回 null，调用方继续用 DOM renderer（今天的行为）。
 */

import { nativeCapabilities } from '../core/nativeCapabilities.js';

let testDisableWebgl = null;

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
 * 阻断 LinkRenderLayer 冗余的 2048 图集获取，消除与 WebglRenderer 16384 图集的配置冲突颠簸（Issue #316）。
 * LinkRenderLayer 仅用于绘制超链接下划线（纯色矩形），不渲染字形，无需独立 TextureAtlas。
 * 消除此冲突后，所有具有相同字体与字号的终端实例均可在 CharAtlasCache 中 100% 共享单一图集。
 * @param {object|null} addon
 */
export function silenceRenderLayerAtlas(addon) {
  const layers = addon?._renderer?._renderLayers;
  if (!Array.isArray(layers)) return;
  for (const layer of layers) {
    if (layer && typeof layer._refreshCharAtlas === 'function') {
      layer._refreshCharAtlas = () => {};
    }
    if (layer && layer._charAtlas) {
      layer._charAtlas = undefined;
    }
  }
}

/**
 * 彻底释放 WebGL 渲染器、画布尺寸与底层显存（Issue #316）。
 * 1. 显式调用 WEBGL_lose_context.loseContext() 释放 WebKit / Metal / IOSurface 显存；
 * 2. 正常调用 addon.dispose() 销毁 WebGL 渲染管线；
 * 3. 将主 Canvas 及各 RenderLayer Canvas 宽高归零（0×0），通知底层图形驱动回收 backing store；
 * 4. 若关联的 TextureAtlas 已经无其他终端持有（已 dispose），将其离屏 canvas 宽高归零。
 * @param {object|null} addon
 */
export function disposeWebglAddon(addon) {
  if (!addon) return;
  const renderer = addon._renderer;
  const gl = renderer?._gl;
  const mainCanvas = renderer?._canvas;
  const layers = Array.isArray(renderer?._renderLayers) ? renderer._renderLayers : [];
  const atlas = renderer?._charAtlas;

  // 1. 显式触发 WebGL Context 丢失，促使 WebKit 归还底层 IOSurface 与 GPU 显存
  try {
    const loseExt = gl?.getExtension?.('WEBGL_lose_context');
    loseExt?.loseContext?.();
  } catch {}

  // 2. 调用 addon.dispose()
  try {
    addon.dispose?.();
  } catch {}

  // 3. 将 Canvas 元素尺寸强制归零（0×0），促使操作系统回收 backing store
  if (mainCanvas) {
    try {
      mainCanvas.width = 0;
      mainCanvas.height = 0;
    } catch {}
  }
  for (const layer of layers) {
    if (layer?._canvas) {
      try {
        layer._canvas.width = 0;
        layer._canvas.height = 0;
      } catch {}
    }
    layer._charAtlas = undefined;
  }

  // 4. 若当前终端是该 TextureAtlas 的唯一持有者（被 removeTerminalFromCache 触发 dispose），归零离屏 canvas
  if (atlas && atlas._onAddTextureAtlasCanvas?._disposed) {
    if (atlas._tmpCanvas) {
      try {
        atlas._tmpCanvas.width = 0;
        atlas._tmpCanvas.height = 0;
      } catch {}
    }
    if (Array.isArray(atlas.pages)) {
      for (const page of atlas.pages) {
        if (page?.canvas) {
          try {
            page.canvas.width = 0;
            page.canvas.height = 0;
          } catch {}
        }
      }
    }
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
    const addon = new Addon();
    if (typeof addon.onContextLoss === 'function') {
      addon.onContextLoss(() => {
        try { disposeWebglAddon(addon); } catch { /* keep DOM cells already on screen */ }
      });
    }
    term.loadAddon(addon);
    if (!webglSurfaceOk(term)) {
      try { disposeWebglAddon(addon); } catch { /* stay on DOM */ }
      return null;
    }
    silenceRenderLayerAtlas(addon);
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
  if (r.width >= 2 && r.height >= 2) return true;
  if ((canvas.width || 0) >= 2 && (canvas.height || 0) >= 2) return true;
  return false;
}

function defaultImporter() {
  return import('@xterm/addon-webgl');
}
