/**
 * Tab 拖拽调序与四向边缘分屏引擎（UI-SPEC §4.1.1 & §6.1，2026-09-15 顾问报告 §4, §5）
 *
 * 核心指标：【拖拽体验流畅不卡顿】
 * 1. 手势状态机：pointerdown/move/up + setPointerCapture，长按阈值 180ms，容差 6px；
 * 2. 零强制重排（Zero Forced Reflow）：pointerdown 预缓存坐标；pointermove 仅更新点并由单 rAF 调度，严禁在 move 中读取 DOM 布局；
 * 3. 几何判定与 Dropzone：落点在 Tab 栏触发平滑横向调序；落点在会话区触发 25% 四向边缘纯数学吸附，带 3px 滞回防抖；
 * 4. GPU 加速预览：DragOverlay 与 Ghost 使用 translate3d + scale + opacity，悬浮期间绝不修改真实 Split Tree 或终端；
 * 5. 原子 Drop 提交：仅在 pointerup 瞬间原子提交树拓扑变更；终端实例保持平铺绝对定位保活（零 Unmount）。
 */

import { project } from './workspaceLayout.js';

export const HOLD_DELAY_MS = 180;
export const TOLERANCE_PX = 6;
export const HYSTERESIS_PX = 3;
export const MIN_PANE_W = 120;
export const MIN_PANE_H = 60;
export const OVERLAY_BASE_SIZE = 100; // 100x100 基础尺寸供 scale GPU 合成

/**
 * 纯几何边缘判定（九宫格 25% 边缘吸附 + 3px 滞回防抖）
 *
 * @param {{ x: number, y: number, w: number, h: number }} rect 视口绝对像素矩形
 * @param {number} x clientX
 * @param {number} y clientY
 * @param {'left'|'right'|'top'|'bottom'|null} [prevEdge=null] 上一帧命中的边
 * @param {number} [hysteresisPx=3] 滞回阈值（px）
 * @returns {'left'|'right'|'top'|'bottom'|null}
 */
export function edgeAt(rect, x, y, prevEdge = null, hysteresisPx = HYSTERESIS_PX) {
  if (!rect || rect.w <= 0 || rect.h <= 0 ||
      x < rect.x || y < rect.y ||
      x >= rect.x + rect.w || y >= rect.y + rect.h) {
    return null;
  }

  const u = (x - rect.x) / rect.w;
  const v = (y - rect.y) / rect.h;

  // 边缘 25% 切线判定
  const distances = [
    ['left', u],
    ['right', 1 - u],
    ['top', v],
    ['bottom', 1 - v],
  ];

  let best = null;
  for (const [edge, d] of distances) {
    if (d <= 0.25 && (!best || d < best.d)) {
      best = { edge, d };
    }
  }

  if (!best) return null; // 中心 50%x50% 无 drop 区域

  // 滞回防抖：同目标内新边比旧边更近至少 hysteresisPx 才切换，避免对角线抖动
  if (prevEdge && prevEdge !== best.edge) {
    const pxOf = (e) => {
      switch (e) {
        case 'left': return x - rect.x;
        case 'right': return rect.x + rect.w - x;
        case 'top': return y - rect.y;
        case 'bottom': return rect.y + rect.h - y;
        default: return Infinity;
      }
    };
    const prevPx = pxOf(prevEdge);
    const bestPx = pxOf(best.edge);
    if (bestPx > prevPx - hysteresisPx) {
      return prevEdge;
    }
  }

  return best.edge;
}

/**
 * 根据边缘计算分屏预览矩形（半区投影）
 *
 * @param {{ x: number, y: number, w: number, h: number }} rect
 * @param {'left'|'right'|'top'|'bottom'} edge
 * @returns {{ x: number, y: number, w: number, h: number }}
 */
export function computePreviewRect(rect, edge) {
  if (!rect || !edge) return { x: 0, y: 0, w: 0, h: 0 };
  const halfW = Math.floor(rect.w * 0.5);
  const halfH = Math.floor(rect.h * 0.5);

  switch (edge) {
    case 'left':
      return { x: rect.x, y: rect.y, w: halfW, h: rect.h };
    case 'right':
      return { x: rect.x + (rect.w - halfW), y: rect.y, w: halfW, h: rect.h };
    case 'top':
      return { x: rect.x, y: rect.y, w: rect.w, h: halfH };
    case 'bottom':
      return { x: rect.x, y: rect.y + (rect.h - halfH), w: rect.w, h: halfH };
    default:
      return rect;
  }
}

/**
 * 纯数学主区窗格命中检测
 *
 * @param {Object} params
 * @param {number} params.x clientX
 * @param {number} params.y clientY
 * @param {string} params.sourceUid 正在拖拽的会话 uid
 * @param {{ x: number, y: number, w: number, h: number }} params.stageRect 舞台视口矩形
 * @param {Array<{ uid: string, rect: { x: number, y: number, w: number, h: number } }>} params.leafRects 叶子视口矩形
 * @param {{ targetUid: string, edge: string }|null} [params.prevTarget=null] 上一帧命中
 * @returns {{ type: 'edge', targetUid: string, edge: string, previewRect: Object } | { type: 'center', targetUid: string } | null}
 */
export function hitTestLeafPanes({ x, y, sourceUid, stageRect, leafRects, prevTarget = null }) {
  if (!stageRect ||
      x < stageRect.x || y < stageRect.y ||
      x >= stageRect.x + stageRect.w || y >= stageRect.y + stageRect.h) {
    return null;
  }

  for (const leaf of leafRects) {
    const { uid, rect } = leaf;
    if (x >= rect.x && y >= rect.y && x < rect.x + rect.w && y < rect.y + rect.h) {
      // 自身拖向自身：拒绝
      if (uid === sourceUid) {
        return { type: 'center', targetUid: uid };
      }

      const prevEdge = (prevTarget && prevTarget.targetUid === uid) ? prevTarget.edge : null;
      const edge = edgeAt(rect, x, y, prevEdge);

      if (edge) {
        // 最小可用宽高门禁保护
        if ((edge === 'left' || edge === 'right') && rect.w * 0.5 < MIN_PANE_W) {
          return { type: 'center', targetUid: uid };
        }
        if ((edge === 'top' || edge === 'bottom') && rect.h * 0.5 < MIN_PANE_H) {
          return { type: 'center', targetUid: uid };
        }

        const previewRect = computePreviewRect(rect, edge);
        return {
          type: 'edge',
          targetUid: uid,
          edge,
          previewRect,
        };
      }

      return { type: 'center', targetUid: uid };
    }
  }

  return null;
}

/**
 * 纯数学 Tab 栏命中与重排位置计算
 *
 * @param {Object} params
 * @param {number} params.x clientX
 * @param {number} params.y clientY
 * @param {string} params.sourceUid
 * @param {{ x: number, y: number, w: number, h: number }} params.tabBarRect
 * @param {Array<{ uid: string, index: number, pinned: boolean, rect: { x: number, y: number, w: number, h: number } }>} params.tabRects
 * @returns {{ type: 'tabbar', fromIndex: number, toIndex: number } | null}
 */
export function hitTestTabBar({ x, y, sourceUid, tabBarRect, tabRects }) {
  if (!tabBarRect || tabRects.length === 0) return null;
  // 上下容差宽松 10px，便于在 Tab 栏附近平滑横移
  if (x < tabBarRect.x || x > tabBarRect.x + tabBarRect.w ||
      y < tabBarRect.y - 10 || y > tabBarRect.y + tabBarRect.h + 10) {
    return null;
  }

  const sourceTab = tabRects.find((t) => t.uid === sourceUid);
  if (!sourceTab) return null;

  // 只能在同组（pinned 组内或 unpinned 组内）重排
  const sameGroup = tabRects.filter((t) => t.pinned === sourceTab.pinned);
  if (sameGroup.length <= 1) {
    return { type: 'tabbar', fromIndex: sourceTab.index, toIndex: sourceTab.index };
  }

  let targetTab = sameGroup[0];
  for (const t of sameGroup) {
    const midX = t.rect.x + t.rect.w * 0.5;
    if (x >= t.rect.x) {
      targetTab = t;
    }
  }

  // 找出最近的插槽索引
  let toIndex = targetTab.index;
  const targetMid = targetTab.rect.x + targetTab.rect.w * 0.5;
  if (x > targetMid && sourceTab.index > targetTab.index) {
    // 往右插
  } else if (x > targetMid && sourceTab.index < targetTab.index) {
    toIndex = targetTab.index;
  }

  return {
    type: 'tabbar',
    fromIndex: sourceTab.index,
    toIndex,
  };
}

/**
 * 创建高性能手势拖拽控制器
 * 严格遵照 Zero Forced Reflow：热路径严禁读取 DOM 布局，全部由单 rAF 消费最新点位驱动 GPU 预览。
 */
export class TabDragController {
  constructor({
    getStageEl,
    getTabBarEl,
    getTabs,
    getRoot,
    onDropSplit,
    onReorderTabs,
    onStateChange,
  }) {
    this.getStageEl = getStageEl;
    this.getTabBarEl = getTabBarEl;
    this.getTabs = getTabs;
    this.getRoot = getRoot;
    this.onDropSplit = onDropSplit;
    this.onReorderTabs = onReorderTabs;
    this.onStateChange = onStateChange || (() => {});

    // 状态机: 'idle' | 'pendingHold' | 'dragging'
    this.state = 'idle';
    this.pointerId = null;
    this.captureEl = null;
    this.sourceUid = null;
    this.sourceTitle = '';
    this.startX = 0;
    this.startY = 0;
    this.lastX = 0;
    this.lastY = 0;
    this.holdTimer = null;
    this.rafId = null;
    this.rafPending = false;

    // 预缓存几何快照（只在 pointerdown 或 hold 触发瞬间读取一次）
    this.cachedStageRect = null;
    this.cachedTabBarRect = null;
    this.cachedTabRects = [];
    this.cachedLeafRects = [];

    // 当前预览命中
    this.lastHit = null;

    // DOM 引用（overlay 与 ghost）
    this.overlayEl = null;
    this.ghostEl = null;

    this._onPointerMove = this._onPointerMove.bind(this);
    this._onPointerUp = this._onPointerUp.bind(this);
    this._onPointerCancel = this._onPointerCancel.bind(this);
    this._onKeyDown = this._onKeyDown.bind(this);
    this._onWindowBlur = this._onWindowBlur.bind(this);
  }

  /**
   * 挂载全局预览 DOM 元素
   */
  mountOverlays(overlayEl, ghostEl) {
    this.overlayEl = overlayEl;
    this.ghostEl = ghostEl;
  }

  /**
   * PointerDown 入口：由 Tab 项在 pointerdown 时调用
   */
  start(e, tab, title = '') {
    // 仅响应左键主按键
    if (e.button !== 0) return;
    // 排除关闭按钮点击
    if (e.target.closest && e.target.closest('.tb-tab-close')) return;

    this.cancel();

    this.pointerId = e.pointerId;
    this.sourceUid = tab.uid;
    this.sourceTitle = title || tab.uid;
    this.startX = e.clientX;
    this.startY = e.clientY;
    this.lastX = e.clientX;
    this.lastY = e.clientY;
    this.state = 'pendingHold';
    this.captureEl = e.currentTarget;

    // 绑定捕获以保证来源元素位移时不丢帧
    if (this.captureEl && typeof this.captureEl.setPointerCapture === 'function') {
      try { this.captureEl.setPointerCapture(this.pointerId); } catch {}
    }

    // 预缓存几何快照（在此只读阶段一次性读取，后续连续拖拽 0 读取）
    this._cacheGeometry();

    // 启动 180ms 长按检测定时器
    this.holdTimer = setTimeout(() => {
      if (this.state === 'pendingHold') {
        this.state = 'dragging';
        this.onStateChange('dragging', { uid: this.sourceUid });
        this._showGhost();
        this._scheduleRaf();
      }
    }, HOLD_DELAY_MS);

    const win = typeof window !== 'undefined' ? window : null;
    if (win) {
      win.addEventListener('pointermove', this._onPointerMove, { passive: true });
      win.addEventListener('pointerup', this._onPointerUp);
      win.addEventListener('pointercancel', this._onPointerCancel);
      win.addEventListener('keydown', this._onKeyDown);
      win.addEventListener('blur', this._onWindowBlur);
    }
  }

  _cacheGeometry() {
    const stageEl = this.getStageEl ? this.getStageEl() : null;
    const tabBarEl = this.getTabBarEl ? this.getTabBarEl() : null;

    if (stageEl) {
      const r = stageEl.getBoundingClientRect();
      this.cachedStageRect = { x: r.left, y: r.top, w: r.width, h: r.height };

      // 结合纯函数 project 计算叶子矩形，不逐个读取 DOM
      const root = this.getRoot ? this.getRoot() : null;
      if (root) {
        const localMap = project(root, { x: 0, y: 0, w: r.width, h: r.height }, 1);
        this.cachedLeafRects = Object.entries(localMap).map(([uid, lr]) => ({
          uid,
          rect: {
            x: r.left + lr.x,
            y: r.top + lr.y,
            w: lr.w,
            h: lr.h,
          },
        }));
      } else {
        this.cachedLeafRects = [];
      }
    } else {
      this.cachedStageRect = null;
      this.cachedLeafRects = [];
    }

    if (tabBarEl) {
      const r = tabBarEl.getBoundingClientRect();
      this.cachedTabBarRect = { x: r.left, y: r.top, w: r.width, h: r.height };
      const tabEls = Array.from(tabBarEl.querySelectorAll('.tb-tab[data-tab-uid]'));
      this.cachedTabRects = tabEls.map((el, i) => {
        const tr = el.getBoundingClientRect();
        return {
          uid: el.getAttribute('data-tab-uid'),
          index: i,
          pinned: el.getAttribute('data-pinned') === 'true',
          rect: { x: tr.left, y: tr.top, w: tr.width, h: tr.height },
          el,
        };
      });
    } else {
      this.cachedTabBarRect = null;
      this.cachedTabRects = [];
    }
  }

  _onPointerMove(e) {
    if (e.pointerId !== this.pointerId) return;

    this.lastX = e.clientX;
    this.lastY = e.clientY;

    if (this.state === 'pendingHold') {
      const dist = Math.hypot(this.lastX - this.startX, this.lastY - this.startY);
      if (dist > TOLERANCE_PX) {
        // 长按前超容差移动取消本次拖拽候选
        this.cancel();
        return;
      }
    } else if (this.state === 'dragging') {
      this._scheduleRaf();
    }
  }

  _scheduleRaf() {
    if (this.rafPending) return;
    const raf = typeof requestAnimationFrame === 'function' ? requestAnimationFrame : ((cb) => setTimeout(cb, 16));
    this.rafPending = true;
    this.rafId = raf(() => {
      this.rafPending = false;
      this._processFrame();
    });
  }

  /**
   * 单一 rAF 帧调度：纯数学几何判定 + GPU transform/opacity 预览
   */
  _processFrame() {
    if (this.state !== 'dragging') return;

    const x = this.lastX;
    const y = this.lastY;

    // 1. 更新 Ghost 坐标（硬件加速 translate3d）
    if (this.ghostEl) {
      this.ghostEl.style.transform = `translate3d(${x + 12}px, ${y + 12}px, 0)`;
      this.ghostEl.style.opacity = '1';
    }

    // 2. 判定是否落在 TabBar 内（平滑调序预览）
    const tabHit = hitTestTabBar({
      x,
      y,
      sourceUid: this.sourceUid,
      tabBarRect: this.cachedTabBarRect,
      tabRects: this.cachedTabRects,
    });

    if (tabHit) {
      this._hideOverlay();
      this.lastHit = { ...tabHit, sourceUid: this.sourceUid };
      this._updateTabReorderPreview(tabHit.fromIndex, tabHit.toIndex);
      return;
    }

    // 清理 Tab 栏可能应用的临时 transform
    this._resetTabTransforms();

    // 3. 判定是否落在主区 TerminalStage 内（四向边缘分屏吸附）
    const paneHit = hitTestLeafPanes({
      x,
      y,
      sourceUid: this.sourceUid,
      stageRect: this.cachedStageRect,
      leafRects: this.cachedLeafRects,
      prevTarget: this.lastHit?.type === 'edge' ? this.lastHit : null,
    });

    if (paneHit && paneHit.type === 'edge') {
      this.lastHit = { ...paneHit, sourceUid: this.sourceUid };
      this._showOverlay(paneHit.previewRect);
      return;
    }

    // 其余区域（中心区域或窗口外）：隐藏 Dropzone
    this.lastHit = null;
    this._hideOverlay();
  }

  _updateTabReorderPreview(fromIndex, toIndex) {
    if (!this.cachedTabRects || this.cachedTabRects.length === 0) return;
    const sourceTab = this.cachedTabRects.find((t) => t.uid === this.sourceUid);
    if (!sourceTab) return;

    const shift = sourceTab.rect.w + 4;

    for (const t of this.cachedTabRects) {
      if (t.uid === this.sourceUid) continue;
      if (t.pinned !== sourceTab.pinned) {
        if (t.el) t.el.style.transform = '';
        continue;
      }

      let tx = 0;
      if (fromIndex < toIndex) {
        if (t.index > fromIndex && t.index <= toIndex) {
          tx = -shift;
        }
      } else if (fromIndex > toIndex) {
        if (t.index >= toIndex && t.index < fromIndex) {
          tx = shift;
        }
      }

      if (t.el) {
        t.el.style.transform = tx ? `translate3d(${tx}px, 0, 0)` : '';
        t.el.style.transition = 'transform 0.15s ease';
      }
    }
  }

  _resetTabTransforms() {
    if (!this.cachedTabRects) return;
    for (const t of this.cachedTabRects) {
      if (t.el) {
        t.el.style.transform = '';
        t.el.style.transition = '';
      }
    }
  }

  _showOverlay(rect) {
    if (!this.overlayEl || !rect) return;
    const scaleX = rect.w / OVERLAY_BASE_SIZE;
    const scaleY = rect.h / OVERLAY_BASE_SIZE;
    this.overlayEl.style.transform = `translate3d(${rect.x}px, ${rect.y}px, 0) scale(${scaleX}, ${scaleY})`;
    this.overlayEl.style.opacity = '1';
    this.overlayEl.style.visibility = 'visible';
  }

  _hideOverlay() {
    if (!this.overlayEl) return;
    this.overlayEl.style.opacity = '0';
    this.overlayEl.style.visibility = 'hidden';
  }

  _showGhost() {
    if (!this.ghostEl) return;
    this.ghostEl.textContent = this.sourceTitle;
    this.ghostEl.style.transform = `translate3d(${this.lastX + 12}px, ${this.lastY + 12}px, 0)`;
    this.ghostEl.style.opacity = '1';
    this.ghostEl.style.visibility = 'visible';
  }

  _hideGhost() {
    if (!this.ghostEl) return;
    this.ghostEl.style.opacity = '0';
    this.ghostEl.style.visibility = 'hidden';
  }

  _onPointerUp(e) {
    if (e.pointerId !== this.pointerId) return;

    // 取消待消费的 rAF，以松手瞬间点位执行纯数学最终结算
    if (this.rafId) {
      const craf = typeof cancelAnimationFrame === 'function' ? cancelAnimationFrame : clearTimeout;
      craf(this.rafId);
      this.rafPending = false;
    }

    const wasDragging = this.state === 'dragging';
    const x = e.clientX;
    const y = e.clientY;

    if (wasDragging) {
      // 1. 同步进行最终纯几何判定
      const tabHit = hitTestTabBar({
        x,
        y,
        sourceUid: this.sourceUid,
        tabBarRect: this.cachedTabBarRect,
        tabRects: this.cachedTabRects,
      });

      if (tabHit && tabHit.fromIndex !== tabHit.toIndex) {
        this.onReorderTabs && this.onReorderTabs(tabHit.fromIndex, tabHit.toIndex);
      } else {
        const paneHit = hitTestLeafPanes({
          x,
          y,
          sourceUid: this.sourceUid,
          stageRect: this.cachedStageRect,
          leafRects: this.cachedLeafRects,
          prevTarget: this.lastHit?.type === 'edge' ? this.lastHit : null,
        });

        if (paneHit && paneHit.type === 'edge') {
          this.onDropSplit && this.onDropSplit(this.sourceUid, paneHit.targetUid, paneHit.edge);
        }
      }
    }

    this.cancel();
  }

  _onPointerCancel(e) {
    if (e.pointerId === this.pointerId) {
      this.cancel();
    }
  }

  _onKeyDown(e) {
    if (e.key === 'Escape') {
      this.cancel();
    }
  }

  _onWindowBlur() {
    this.cancel();
  }

  cancel() {
    if (this.holdTimer) {
      clearTimeout(this.holdTimer);
      this.holdTimer = null;
    }
    if (this.rafId) {
      const craf = typeof cancelAnimationFrame === 'function' ? cancelAnimationFrame : clearTimeout;
      craf(this.rafId);
      this.rafId = null;
      this.rafPending = false;
    }

    if (this.captureEl && typeof this.captureEl.releasePointerCapture === 'function' && this.pointerId !== null) {
      try { this.captureEl.releasePointerCapture(this.pointerId); } catch {}
    }

    this._resetTabTransforms();
    this._hideOverlay();
    this._hideGhost();

    const wasDragging = this.state === 'dragging';
    this.state = 'idle';
    this.pointerId = null;
    this.captureEl = null;
    this.sourceUid = null;
    this.sourceTitle = '';
    this.lastHit = null;

    const win = typeof window !== 'undefined' ? window : null;
    if (win) {
      win.removeEventListener('pointermove', this._onPointerMove);
      win.removeEventListener('pointerup', this._onPointerUp);
      win.removeEventListener('pointercancel', this._onPointerCancel);
      win.removeEventListener('keydown', this._onKeyDown);
      win.removeEventListener('blur', this._onWindowBlur);
    }

    if (wasDragging) {
      this.onStateChange('idle', null);
    }
  }

  dispose() {
    this.cancel();
    this.overlayEl = null;
    this.ghostEl = null;
  }
}
