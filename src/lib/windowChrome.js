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

// 记录上一次拖窗触发时间戳，防 100ms 内微任务/事件冒泡重复触发
let lastDragTimestamp = 0;

export function resetDragThrottleForTest() {
  lastDragTimestamp = 0;
}

/**
 * 窗口拖动唯一真相源入口（UI-SPEC §4.1 / 测试席 exactly-once 契约）
 *
 * 核心契约：
 * 1. 严格过滤非主键左键（button !== 0）；
 * 2. 严格排除可交互控件（button, input, select, textarea, [role="tab"], .tb-tab, .tb-tab-close 等）；
 * 3. 严格防重复派发（e._amDragHandled 守卫 + e.stopPropagation() + 100ms 去抖时间窗）；
 * 4. 无论由 pointerdown 还是 mousedown 触发，单次物理按下保证 exactly-once 派发 startDragging()。
 */
export function triggerWindowDrag(e) {
  if (!e || e.button !== 0) return false;
  if (e._amDragHandled) return false;

  // 100ms 内同一物理手势不重复触发
  const now = Date.now();
  if (now - lastDragTimestamp < 100) {
    if (typeof e.stopPropagation === 'function') e.stopPropagation();
    return false;
  }

  // 排除按钮、输入框、Tab 标签页、关闭按钮、新建按钮等可交互元素
  if (e.target && typeof e.target.closest === 'function') {
    if (e.target.closest('button, input, select, textarea, [role="tab"], .tb-tab, .tb-tab-close, .tb-tab-add, .tb-btn, [data-no-drag]')) {
      return false;
    }
  }

  // 标记事件已被消费并阻止冒泡至父层容器
  e._amDragHandled = true;
  lastDragTimestamp = now;
  if (typeof e.stopPropagation === 'function') {
    e.stopPropagation();
  }

  try {
    if (appWindowInstance && typeof appWindowInstance.startDragging === 'function') {
      appWindowInstance.startDragging();
      return true;
    }
    // 兜底尚未异步加载完成的情况
    import('@tauri-apps/api/window')
      .then((m) => {
        try {
          appWindowInstance = m.getCurrentWindow();
          if (appWindowInstance && typeof appWindowInstance.startDragging === 'function') {
            appWindowInstance.startDragging();
          }
        } catch {}
      })
      .catch(() => {});
    return true;
  } catch {
    return false;
  }
}
