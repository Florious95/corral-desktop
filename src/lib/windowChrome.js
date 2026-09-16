import { nativeCapabilities } from '../core/nativeCapabilities.js';

/**
 * Hover stadium chrome (user-confirmed mockup 2026-08-22).
 * Hide delay matches mockup.html (160ms), not instant mouseleave.
 */

export const PILL_HIDE_MS = 160;
/** Mockup / UI-SPEC: menu 30pt (NSScreen main) + overlay 32px. */
export const FULLSCREEN_CHROME_INSET = 62;
export const PILL_HOT = { left: 0, width: 210, height: 56 };

export function pillHotTop(fullscreen) {
  return fullscreen ? FULLSCREEN_CHROME_INSET : 0;
}

export function createPillReveal({ hideMs = PILL_HIDE_MS, onChange } = {}) {
  let over = false;
  let hideTimer = null;
  let revealed = false;

  const setRevealed = (next) => {
    if (revealed === next) return;
    revealed = next;
    onChange?.(revealed);
  };

  return {
    get revealed() { return revealed; },
    enter() {
      clearTimeout(hideTimer);
      hideTimer = null;
      over = true;
      setRevealed(true);
    },
    leave() {
      over = false;
      clearTimeout(hideTimer);
      hideTimer = setTimeout(() => {
        hideTimer = null;
        if (!over) setRevealed(false);
      }, hideMs);
    },
    dispose() {
      clearTimeout(hideTimer);
    },
  };
}

export async function runWindowChrome(kind, api) {
  if (!api) throw new Error('no window api');
  if (kind === 'close') return api.close();
  if (kind === 'min') return api.minimize();
  if (kind === 'zoom') {
    const fs = await api.isFullscreen();
    return api.setFullscreen(!fs);
  }
  throw new Error('unknown chrome action');
}

export async function desktopWindowApi() {
  return {
    close: () => nativeCapabilities.window.close(),
    minimize: () => nativeCapabilities.window.minimize(),
    isFullscreen: () => nativeCapabilities.window.isFullscreen(),
    setFullscreen: (v) => nativeCapabilities.window.setFullscreen(v),
    startDragging: () => nativeCapabilities.window.startDragging(),
  };
}
