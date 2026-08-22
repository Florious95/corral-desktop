/*
 * Optional WebGL renderer. customGlyphs 用几何画框线/块元素，避开字形宽度+亚像素取整。
 * 任何失败都返回 null，调用方继续用 DOM renderer（今天的行为）。
 */

/**
 * @param {{ loadAddon: Function }} term xterm instance
 * @param {() => Promise<{WebglAddon: new () => { dispose?: Function, onContextLoss?: Function }}>} [importer]
 * @returns {Promise<object|null>}
 */
export async function attachWebglRenderer(term, importer = defaultImporter) {
  if (!term || typeof term.loadAddon !== 'function') return null;
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
