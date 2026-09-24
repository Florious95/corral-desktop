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
        try { addon.dispose(); } catch { /* keep DOM cells already on screen */ }
      });
    }
    term.loadAddon(addon);
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
