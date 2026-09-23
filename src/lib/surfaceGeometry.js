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
      phase: 'arm',
      viewportCSS: { width: 0, height: 0 },
      devicePixelRatio: 1,
      dragRects: [],
      exclusionRects: [],
      chromeRect: { x: 0, y: 0, width: 0, height: 0 },
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
      if (rect) {
        // 对于顶栏交互按钮（如折叠按钮、新建按钮、红绿灯留白），将排除保护区域纵向扩展至顶栏全高（0..38px）并水平扩展4px安全边距
        // 彻底杜绝鼠标点击或双击边缘误触底层 DragSurfaceView 触发窗口拖拽或双击缩放窗口尺寸
        if (typeof el.matches === 'function' && el.matches('.tb-sidebar-toggle, .tb-tab-add, .tb-traffic-lights')) {
          rect.y = 0;
          rect.height = 38;
          rect.x = Math.max(0, rect.x - 4);
          rect.width = rect.width + 8;
        }
        exclusionRects.push(rect);
      }
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
  let isDisposed = false;
  let timer = null;
  let lastGeomJson = '';
  let inFlight = false;
  let scheduledAgain = false;
  let currentDisarmSeq = 0;
  let disarmed = false;

  const disarmImmediate = () => {
    if (isDisposed) return;
    currentDisarmSeq++;
    // OPEN-2: 清空去重缓存，确保 disarm 后相同几何可以重新触发 arm
    lastGeomJson = '';
    // resize and ResizeObserver may describe the same gesture many times.
    // One disarm suffices until another arm is sent (including an in-flight arm).
    if (disarmed) return;
    disarmed = true;
    // OPEN-2: 布局变动前立即向 Native 下发 disarm，报废旧的拖拽区域
    try {
      const p = onUpdate({ phase: 'disarm' });
      if (p && typeof p.catch === 'function') {
        p.catch((error) => {
          // A stale generation means native already invalidated this map.
          // Wait for its settled state instead of retrying on every resize.
          if (error?.code !== 'stale_geometry') disarmed = false;
        });
      }
    } catch (_) {
      disarmed = false;
    }
  };

  const report = async () => {
    if (isDisposed || !container || inFlight) {
      if (inFlight && !isDisposed) scheduledAgain = true;
      return;
    }
    const geom = collectSurfaceGeometry(container);
    const json = JSON.stringify(geom);
    if (json === lastGeomJson) return; // 几何未变化跳过

    inFlight = true;
    disarmed = false;
    const runDisarmSeq = currentDisarmSeq;
    try {
      await onUpdate(geom);
      // 关键：仅在成功上报 ACK 且在途期间未发生过 disarm 时才记录去重缓存
      if (!isDisposed && currentDisarmSeq === runDisarmSeq) {
        lastGeomJson = json;
      }
    } catch (_) {
      // 上报失败不记录去重缓存，允许后续重试上报
    } finally {
      inFlight = false;
      if (scheduledAgain && !isDisposed) {
        scheduledAgain = false;
        schedule();
      }
    }
  };

  const schedule = () => {
    if (isDisposed) return;
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      if (!isDisposed) report();
    }, debounceMs);
  };

  const onLayoutChange = () => {
    if (isDisposed) return;
    // OPEN-2: 先立即 disarm 报废旧区域，再开启 120ms 防抖定时器定案 arm
    disarmImmediate();
    schedule();
  };

  let ro = null;
  const observeTarget = container?.body || (container?.documentElement ? container.documentElement : container);
  if (typeof ResizeObserver !== 'undefined' && observeTarget && typeof observeTarget === 'object') {
    try {
      ro = new ResizeObserver(() => onLayoutChange());
      ro.observe(observeTarget);
    } catch {
      // 容错忽略
    }
  }

  let lastViewportWidth = typeof window !== 'undefined' ? Math.round(window.innerWidth || 0) : -1;
  let lastViewportHeight = typeof window !== 'undefined' ? Math.round(window.innerHeight || 0) : -1;
  let lastNativeGeometry = '';

  const onWinResize = () => {
    if (isDisposed) return;
    if (typeof window !== 'undefined') {
      const w = Math.round(window.innerWidth || 0);
      const h = Math.round(window.innerHeight || 0);
      if (w === lastViewportWidth && h === lastViewportHeight) return;
      lastViewportWidth = w;
      lastViewportHeight = h;
    }
    onLayoutChange();
  };

  const onWindowState = (e) => {
    if (isDisposed) return;
    // Native has already invalidated its hit map. Rearm even for same-size
    // generation/scale changes, without echoing another disarm back to native.
    const payload = e?.detail;
    const vp = payload?.viewportCSS;
    if (vp && typeof vp.width === 'number' && typeof vp.height === 'number') {
      const w = Math.round(vp.width);
      const h = Math.round(vp.height);
      const geometry = JSON.stringify([payload.geometryGeneration, w, h, payload.devicePixelRatio]);
      if (geometry !== lastNativeGeometry) {
        lastNativeGeometry = geometry;
        lastViewportWidth = w;
        lastViewportHeight = h;
        currentDisarmSeq++;
        lastGeomJson = '';
        schedule();
      }
    }
  };

  if (typeof window !== 'undefined' && typeof window.addEventListener === 'function') {
    window.addEventListener('resize', onWinResize);
    window.addEventListener('agentmirror:window-state-updated', onWindowState);
  }

  // 挂载后首次调度一次
  schedule();

  return {
    triggerImmediately() {
      if (isDisposed) return;
      if (timer) clearTimeout(timer);
      report();
    },
    schedule,
    disarm: disarmImmediate,
    dispose() {
      // OPEN-3: 销毁前先发出最后一次 disarm，确保原生外壳清理在途点击区
      disarmed = false;
      disarmImmediate();
      isDisposed = true;
      lastGeomJson = '';
      if (timer) {
        clearTimeout(timer);
        timer = null;
      }
      inFlight = false;
      scheduledAgain = false;
      if (ro) {
        ro.disconnect();
        ro = null;
      }
      if (typeof window !== 'undefined' && typeof window.removeEventListener === 'function') {
        window.removeEventListener('resize', onWinResize);
        window.removeEventListener('agentmirror:window-state-updated', onWindowState);
      }
    },
  };
}
