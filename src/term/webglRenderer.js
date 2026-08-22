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
    return addon;
  } catch {
    return null;
  }
}

function defaultImporter() {
  return import('@xterm/addon-webgl');
}
