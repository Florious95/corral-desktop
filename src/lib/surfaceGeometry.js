/**
 * 桌面端窗口拖拽几何收集与防抖上报（UI-SPEC & Swift Native Shell 契约）
 *
 * 收集顶部可拖拽区域与交互排除区域，通过 nativeCapabilities.surface.update 上报至 Swift 原生外壳。
 * 遵循 120ms debounce 节流，杜绝不必要的频繁跨进程 IPC。
 */

import { nativeCapabilities } from '../core/nativeCapabilities.js';

export const SURFACE_DEBOUNCE_MS = 120;

function elementToRect(el) {
  if (!el || typeof el.getBoundingClientRect !== 'function') return null;
  const r = el.getBoundingClientRect();
  if (r.width <= 0 || r.height <= 0) return null;
  return {
    x: Math.round(r.left),
    y: Math.round(r.top),
    width: Math.round(r.width),
    height: Math.round(r.height),
  };
}

/**
 * 收集当前 DOM 结构中顶栏的可拖拽区域与排除交互区域
 * @param {Document|HTMLElement} [container=document]
 * @returns {{ viewportCSS: { width: number, height: number }, dragRects: Array<{x:number, y:number, width:number, height:number}>, exclusionRects: Array<{x:number, y:number, width:number, height:number}> }}
 */
export function collectSurfaceGeometry(container = typeof document !== 'undefined' ? document : null) {
  if (typeof window === 'undefined' || !container) {
    return {
      viewportCSS: { width: 0, height: 0 },
      dragRects: [],
      exclusionRects: [],
    };
  }

  const viewportCSS = {
    width: window.innerWidth || 0,
    height: window.innerHeight || 0,
  };

  // 1. 寻找顶栏可拖拽区域（.tb、.tb-session-header 或带 data-window-drag 的元素）
  const dragElements = container.querySelectorAll
    ? container.querySelectorAll('.tb, .tb-session-header, [data-tauri-drag-region="deep"], [data-window-drag="true"]')
    : [];

  const dragRects = [];
  dragElements.forEach((el) => {
    const rect = elementToRect(el);
    if (rect) dragRects.push(rect);
  });

  // 2. 寻找顶栏内部必须排除的交互区域（红绿灯占位、折叠按钮、Tab 标签、新建按钮、所有交互输入/按钮等）
  const exclusionElements = container.querySelectorAll
    ? container.querySelectorAll('.tb-traffic-lights, .tb-sidebar-toggle, .tb-tab, .tb-tab-add, button, input, select, [data-tauri-drag-region="false"], [data-no-drag="true"]')
    : [];

  const exclusionRects = [];
  exclusionElements.forEach((el) => {
    // 确保仅收集位于顶栏内的交互元素
    if (el.closest && el.closest('.tb, .tb-session-header, [data-tauri-drag-region="deep"], [data-window-drag="true"]')) {
      const rect = elementToRect(el);
      if (rect) exclusionRects.push(rect);
    }
  });

  let maxDragY = 38;
  dragRects.forEach((r) => {
    if (r.y + r.height > maxDragY) {
      maxDragY = r.y + r.height;
    }
  });

  const chromeRect = {
    x: 0,
    y: 0,
    width: viewportCSS.width,
    height: Math.min(viewportCSS.height, maxDragY),
  };

  return {
    phase: 'arm',
    viewportCSS,
    devicePixelRatio: typeof window !== 'undefined' ? window.devicePixelRatio || 1 : 1,
    dragRects,
    exclusionRects,
    chromeRect,
  };
}

/**
 * 创建 Surface 几何监听器，监听顶栏与视口尺寸变动，以 120ms 防抖上报几何
 */
export function createSurfaceGeometryWatcher({
  container = typeof document !== 'undefined' ? document : null,
  debounceMs = SURFACE_DEBOUNCE_MS,
  onUpdate = (geom) => nativeCapabilities.surface.update(geom),
} = {}) {
  let timer = null;
  let lastGeomJson = '';
  let inFlight = false;
  let scheduledAgain = false;

  const report = async () => {
    if (!container || inFlight) {
      if (inFlight) scheduledAgain = true;
      return;
    }
    const geom = collectSurfaceGeometry(container);
    const json = JSON.stringify(geom);
    if (json === lastGeomJson) return; // 几何未变化跳过

    inFlight = true;
    try {
      await onUpdate(geom);
      // 关键：仅在成功上报 ACK 后才记录 lastGeomJson 去重缓存
      lastGeomJson = json;
    } catch (_) {
      // 上报失败不记录去重缓存，允许后续重试上报
    } finally {
      inFlight = false;
      if (scheduledAgain) {
        scheduledAgain = false;
        schedule();
      }
    }
  };

  const schedule = () => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      report();
    }, debounceMs);
  };

  let ro = null;
  const observeTarget = container?.body || (container?.documentElement ? container.documentElement : container);
  if (typeof ResizeObserver !== 'undefined' && observeTarget && typeof observeTarget === 'object') {
    try {
      ro = new ResizeObserver(() => schedule());
      ro.observe(observeTarget);
    } catch {
      // 容错忽略
    }
  }

  const onWinResize = () => schedule();
  const onWindowState = () => {
    lastGeomJson = '';
    schedule();
  };

  if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
    window.addEventListener('resize', onWinResize);
    window.addEventListener('agentmirror:window-state-updated', onWindowState);
  }

  // 挂载后首次调度一次
  schedule();

  return {
    triggerImmediately() {
      if (timer) clearTimeout(timer);
      report();
    },
    schedule,
    dispose() {
      if (timer) clearTimeout(timer);
      if (ro) ro.disconnect();
      if (typeof window !== 'undefined' && typeof window.removeEventListener === 'function') {
        window.removeEventListener('resize', onWinResize);
        window.removeEventListener('agentmirror:window-state-updated', onWindowState);
      }
    },
  };
}
