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
  const { getCurrentWindow } = await import('@tauri-apps/api/window');
  const w = getCurrentWindow();
  return {
    close: () => w.close(),
    minimize: () => w.minimize(),
    isFullscreen: () => w.isFullscreen(),
    setFullscreen: (v) => w.setFullscreen(v),
  };
}

let appWindowInstance = null;
if (typeof window !== 'undefined') {
  import('@tauri-apps/api/window')
    .then((m) => {
      try { appWindowInstance = m.getCurrentWindow(); } catch {}
    })
    .catch(() => {});
}

export function triggerWindowDrag(e) {
  if (e.button !== 0) return;
  // 排除按钮、输入框、Tab 标签页、关闭按钮、新建按钮等可交互元素
  if (e.target && typeof e.target.closest === 'function') {
    if (e.target.closest('button, input, select, textarea, [role="tab"], .tb-tab, .tb-tab-close, .tb-tab-add, .tb-btn, [data-no-drag]')) {
      return;
    }
  }
  try {
    if (appWindowInstance && typeof appWindowInstance.startDragging === 'function') {
      appWindowInstance.startDragging();
    } else {
      import('@tauri-apps/api/window')
        .then((m) => {
          try {
            appWindowInstance = m.getCurrentWindow();
            appWindowInstance.startDragging();
          } catch {}
        })
        .catch(() => {});
    }
  } catch {}
}
