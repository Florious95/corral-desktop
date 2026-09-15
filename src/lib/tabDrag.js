/**
 * Tab 拖拽调序与四向边缘分屏引擎（UI-SPEC §4.1.1 & §6.1，2026-09-15 顾问终审加固版）
 *
 * 核心指标：【拖拽体验流畅不卡顿】
 * 1. 手势状态机：Pointer Events + setPointerCapture，长按阈值 180ms，容差 6px；
 * 2. 零强制重排（Zero Forced Reflow）：pointerdown 预缓存坐标；pointermove 仅更新点并由单 rAF 调度，严禁在 move 中读取 DOM 布局；
 * 3. 几何判定与 Dropzone：落点在 Tab 栏触发平滑横向调序；落点在会话区触发 25% 四向边缘纯数学吸附，带 3px 滞回防抖；
 * 4. GPU 加速预览：DragOverlay 与 Ghost 使用 translate3d + scale + opacity，悬浮期间绝不修改真实 Split Tree 或终端；
 * 5. 原子 Drop 提交：仅在 pointerup 瞬间原子提交树拓扑变更；终端实例保持平铺绝对定位保活（零 Unmount）。
 */

import { project, findLeaf, dropNode, getLeaves } from './workspaceLayout.js';

export const HOLD_DELAY_MS = 180;
export const TOLERANCE_PX = 6;
export const HYSTERESIS_PX = 3;
export const MIN_PANE_W = 120;
export const MIN_PANE_H = 60;
export const OVERLAY_BASE_SIZE = 100; // 100x100 基础尺寸供 scale GPU 合成

/**
 * 纯几何边缘判定（九宫格 25% 边缘吸附 + 极长/极宽矩形归一化滞回防抖）
 *
 * 顾问加固 F5：旧边超出 25% 切线立即丢弃，方向比较统一在归一化度量中进行。
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

  const distMap = {
    left: u,
    right: 1 - u,
    top: v,
    bottom: 1 - v,
  };

  // 1. 严格筛选处于 25% 边缘带内的候选
  const candidates = [];
  const order = ['left', 'right', 'top', 'bottom'];
  for (const edge of order) {
    const d = distMap[edge];
    if (d <= 0.25) {
      candidates.push({ edge, d });
    }
  }

  // 若无任何边在 25% 范围内（即中心 50%×50% 区域），绝不保留旧边，直接返回 null
  if (candidates.length === 0) return null;

  candidates.sort((a, b) => a.d - b.d);
  const best = candidates[0];

  // 2. 滞回防抖处理：
  // 必须满足：prevEdge 必须依然处于候选列表中（仍在 25% 边缘内）！
  if (prevEdge && prevEdge !== best.edge) {
    const prevCandidate = candidates.find((c) => c.edge === prevEdge);
    if (prevCandidate) {
      const axisLen = (prevEdge === 'left' || prevEdge === 'right') ? rect.w : rect.h;
      const prevNormThreshold = prevCandidate.d - (hysteresisPx / axisLen);
      if (best.d >= prevNormThreshold) {
        return prevEdge;
      }
    }
  }

  return best.edge;
}

/**
 * 根据边缘计算分屏预览矩形（半区投影）
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
 * 纯数学主区窗格命中检测与候选树预览对齐
 *
 * 顾问加固 F4 / R3：命中 target/edge 后，统一在 dropNode -> project 生成候选树后，校验候选树中每一个叶子的最终尺寸（w >= 120 且 h >= 60），
 * 既杜绝误拒合法分屏（如 401px 舞台 A|B 移 A 到 B 右缘生成各 200px 的合法布局），又准确拦截过小窗格。
 */
export function hitTestLeafPanes({ x, y, sourceUid, stageRect, leafRects, root = null, prevTarget = null }) {
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
        // 顾问加固 R3：基于 dropNode 真实候选拓扑计算预览矩形并统一执行尺寸门禁
        const effectiveRoot = root || (leafRects && leafRects.length === 2 ? {
          kind: 'split',
          axis: leafRects[0].rect.y === leafRects[1].rect.y ? 'x' : 'y',
          ratio: 0.5,
          first: { kind: 'leaf', uid: leafRects[0].uid },
          second: { kind: 'leaf', uid: leafRects[1].uid },
        } : null);

        let previewRect = null;
        if (effectiveRoot) {
          const candidateTree = dropNode(effectiveRoot, sourceUid, uid, edge);
          if (candidateTree) {
            const projected = project(candidateTree, stageRect, 1);
            previewRect = projected[sourceUid] || null;

            // 统一在真实候选树校验每一个叶子的最终尺寸（w >= 120 且 h >= 60），并确保无遗漏
            const leaves = getLeaves(candidateTree);
            const allLeavesPresent = leaves.every((leafUid) => !!projected[leafUid]);
            const allValid = allLeavesPresent && Object.values(projected).every(
              (p) => p.w >= MIN_PANE_W && p.h >= MIN_PANE_H
            );
            if (!allValid) {
              return { type: 'center', targetUid: uid };
            }
          }
        } else {
          // 仅在完全没有拓扑树可用时（纯矩形隔离测试夹具），退化使用当前矩形折半推算
          if ((edge === 'left' || edge === 'right') && rect.w * 0.5 < MIN_PANE_W) {
            return { type: 'center', targetUid: uid };
          }
          if ((edge === 'top' || edge === 'bottom') && rect.h * 0.5 < MIN_PANE_H) {
            return { type: 'center', targetUid: uid };
          }
          previewRect = computePreviewRect(rect, edge);
        }

        if (!previewRect) {
          previewRect = computePreviewRect(rect, edge);
        }

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
 */
export function hitTestTabBar({ x, y, sourceUid, tabBarRect, tabRects }) {
  if (!tabBarRect || tabRects.length === 0) return null;
  if (x < tabBarRect.x || x > tabBarRect.x + tabBarRect.w ||
      y < tabBarRect.y - 10 || y > tabBarRect.y + tabBarRect.h + 10) {
    return null;
  }

  const sourceTab = tabRects.find((t) => t.uid === sourceUid);
  if (!sourceTab) return null;

  const sameGroup = tabRects.filter((t) => t.pinned === sourceTab.pinned);
  if (sameGroup.length <= 1) {
    return { type: 'tabbar', fromIndex: sourceTab.index, toIndex: sourceTab.index };
  }

  let targetTab = sameGroup[0];
  for (const t of sameGroup) {
    if (x >= t.rect.x) {
      targetTab = t;
    }
  }

  const toIndex = targetTab.index;

  return {
    type: 'tabbar',
    fromIndex: sourceTab.index,
    toIndex,
  };
}

/**
 * 创建高性能手势拖拽控制器
 */
export class TabDragController {
  constructor({
    getStageEl,
    getTabBarEl,
    getTabs,
    getRoot,
    getRevision,
    onDropSplit,
    onReorderTabs,
    onStateChange,
  }) {
    this.getStageEl = getStageEl;
    this.getTabBarEl = getTabBarEl;
    this.getTabs = getTabs;
    this.getRoot = getRoot;
    this.getRevision = getRevision;
    this.onDropSplit = onDropSplit;
    this.onReorderTabs = onReorderTabs;
    this.onStateChange = onStateChange || (() => {});

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
    this.suppressClickUntil = 0;
    this.startRevision = 0;

    this.cachedStageRect = null;
    this.cachedTabBarRect = null;
    this.cachedTabRects = [];
    this.cachedLeafRects = [];
    this.lastHit = null;

    this.startTabs = [];
    this.startRoot = null;
    this.resizeObserver = null;

    this.overlayEl = null;
    this.ghostEl = null;

    this._onPointerMove = this._onPointerMove.bind(this);
    this._onPointerUp = this._onPointerUp.bind(this);
    this._onPointerCancel = this._onPointerCancel.bind(this);
    this._onKeyDown = this._onKeyDown.bind(this);
    this._onWindowBlur = this._onWindowBlur.bind(this);
    this._onWindowResize = this._onWindowResize.bind(this);
    this._onScroll = this._onScroll.bind(this);
    this._onLostPointerCapture = this._onLostPointerCapture.bind(this);
    this._onVisibilityChange = this._onVisibilityChange.bind(this);
    this._onContextMenu = this._onContextMenu.bind(this);
  }

  mountOverlays(overlayEl, ghostEl) {
    this.overlayEl = overlayEl;
    this.ghostEl = ghostEl;
  }

  start(e, tab, title = '') {
    if (e.button !== 0) return;
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
    this.startRevision = this.getRevision ? this.getRevision() : 0;
    this.startTabs = this.getTabs ? this.getTabs() : [];
    this.startRoot = this.getRoot ? this.getRoot() : null;

    if (this.captureEl && typeof this.captureEl.setPointerCapture === 'function') {
      try { this.captureEl.setPointerCapture(this.pointerId); } catch {}
    }

    this._cacheGeometry();

    if (typeof ResizeObserver !== 'undefined') {
      try {
        this.resizeObserver = new ResizeObserver((entries) => {
          if (this.state === 'idle') return;
          for (const entry of entries) {
            const cr = entry.contentRect;
            if (this.cachedStageRect && (Math.abs(cr.width - this.cachedStageRect.w) > 1 || Math.abs(cr.height - this.cachedStageRect.h) > 1)) {
              this.cancel('container-resize');
              return;
            }
          }
        });
        const stageEl = this.getStageEl ? this.getStageEl() : null;
        if (stageEl && typeof stageEl.nodeType === 'number') {
          this.resizeObserver.observe(stageEl);
        }
        const tabBarEl = this.getTabBarEl ? this.getTabBarEl() : null;
        if (tabBarEl && typeof tabBarEl.nodeType === 'number') {
          this.resizeObserver.observe(tabBarEl);
        }
      } catch {}
    }

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
      win.addEventListener('resize', this._onWindowResize);
      win.addEventListener('scroll', this._onScroll, { capture: true, passive: true });
      win.addEventListener('visibilitychange', this._onVisibilityChange);
      win.addEventListener('contextmenu', this._onContextMenu);
      win.addEventListener('lostpointercapture', this._onLostPointerCapture);
    }
    if (this.captureEl && typeof this.captureEl.addEventListener === 'function') {
      this.captureEl.addEventListener('lostpointercapture', this._onLostPointerCapture);
    }
  }

  _cacheGeometry() {
    const stageEl = this.getStageEl ? this.getStageEl() : null;
    const tabBarEl = this.getTabBarEl ? this.getTabBarEl() : null;

    if (stageEl) {
      const r = stageEl.getBoundingClientRect();
      this.cachedStageRect = { x: r.left, y: r.top, w: r.width, h: r.height };

      const root = this.getRoot ? this.getRoot() : null;
      if (root) {
        // 物理碰撞检测：严格使用当前真实物理 root 的各个叶子矩形（真实屏幕 DOM 位置）进行悬停命中
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
        this.cancel('tolerance-exceeded');
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

  _checkContainerResize() {
    if (this.resizeObserver) return;
    const stageEl = this.getStageEl ? this.getStageEl() : null;
    if (stageEl && typeof stageEl.getBoundingClientRect === 'function') {
      const sr = stageEl.getBoundingClientRect();
      if (this.cachedStageRect && (Math.abs(sr.width - this.cachedStageRect.w) > 1 || Math.abs(sr.height - this.cachedStageRect.h) > 1)) {
        this.cancel('container-resize');
      }
    }
  }

  _processFrame() {
    if (this.state !== 'dragging') return;

    this._checkContainerResize();
    if (this.state !== 'dragging') return;

    const x = this.lastX;
    const y = this.lastY;

    if (this.ghostEl) {
      this.ghostEl.style.transform = `translate3d(${x + 12}px, ${y + 12}px, 0)`;
      this.ghostEl.style.opacity = '1';
    }

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

    this._resetTabTransforms();

    const root = this.getRoot ? this.getRoot() : null;
    const paneHit = hitTestLeafPanes({
      x,
      y,
      sourceUid: this.sourceUid,
      stageRect: this.cachedStageRect,
      leafRects: this.cachedLeafRects,
      root,
      prevTarget: this.lastHit?.type === 'edge' ? this.lastHit : null,
    });

    if (paneHit && paneHit.type === 'edge') {
      this.lastHit = { ...paneHit, sourceUid: this.sourceUid };
      this._showOverlay(paneHit.previewRect);
      return;
    }

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

    if (this.rafId) {
      const craf = typeof cancelAnimationFrame === 'function' ? cancelAnimationFrame : clearTimeout;
      craf(this.rafId);
      this.rafPending = false;
    }

    // 顾问加固 R1：独立短按释放分支（未超容差且未超时），绝对不写 suppressClickUntil
    if (this.state === 'pendingHold') {
      this._endShortClick();
      return;
    }

    const wasDragging = this.state === 'dragging';
    const x = e.clientX;
    const y = e.clientY;

    if (wasDragging) {
      this.suppressClickUntil = Date.now() + 250;

      const currentRev = this.getRevision ? this.getRevision() : 0;
      if (currentRev !== this.startRevision) {
        this.cancel('stale-revision');
        return;
      }

      const currentTabs = this.getTabs ? this.getTabs() : [];
      if (!currentTabs.some((t) => t.uid === this.sourceUid)) {
        this.cancel('source-closed');
        return;
      }

      const tabHit = hitTestTabBar({
        x,
        y,
        sourceUid: this.sourceUid,
        tabBarRect: this.cachedTabBarRect,
        tabRects: this.cachedTabRects,
      });

      if (tabHit && tabHit.fromIndex !== tabHit.toIndex) {
        this.onReorderTabs && this.onReorderTabs(
          tabHit.fromIndex,
          tabHit.toIndex,
          { revision: this.startRevision, sourceUid: this.sourceUid, tabs: this.startTabs },
          this.sourceUid,
          this.startTabs
        );
      } else {
        const root = this.getRoot ? this.getRoot() : null;
        const paneHit = hitTestLeafPanes({
          x,
          y,
          sourceUid: this.sourceUid,
          stageRect: this.cachedStageRect,
          leafRects: this.cachedLeafRects,
          root,
          prevTarget: this.lastHit?.type === 'edge' ? this.lastHit : null,
        });

        if (paneHit && paneHit.type === 'edge') {
          if (root && findLeaf(root, paneHit.targetUid)) {
            this.onDropSplit && this.onDropSplit(
              this.sourceUid,
              paneHit.targetUid,
              paneHit.edge,
              { revision: this.startRevision, sourceUid: this.sourceUid, root: this.startRoot },
              this.startRoot
            );
          }
        }
      }
    }

    this.cancel();
  }

  _endShortClick() {
    if (this.holdTimer) {
      clearTimeout(this.holdTimer);
      this.holdTimer = null;
    }

    this.state = 'idle';

    const captureEl = this.captureEl;
    const pid = this.pointerId;
    this.pointerId = null;
    this.captureEl = null;

    if (captureEl && typeof captureEl.releasePointerCapture === 'function' && pid !== null) {
      try { captureEl.releasePointerCapture(pid); } catch {}
    }

    this._cleanupListeners(captureEl);
    this._resetTabTransforms();
    this._hideOverlay();
    this._hideGhost();

    this.sourceUid = null;
    this.sourceTitle = '';
    this.lastHit = null;

    this.cachedStageRect = null;
    this.cachedTabBarRect = null;
    this.cachedTabRects = [];
    this.cachedLeafRects = [];
    // 注意：绝对不设置 suppressClickUntil，放行原生 click 秒级切换 Tab！
  }

  _onLostPointerCapture(e) {
    if (this.state === 'idle') return;
    if (e.pointerId === this.pointerId || this.state === 'dragging') {
      this.cancel('lostpointercapture');
    }
  }

  _onWindowResize() {
    if (this.state === 'dragging' || this.state === 'pendingHold') {
      this.cancel('window-resize');
    }
  }

  _onScroll() {
    if (this.state === 'dragging' || this.state === 'pendingHold') {
      this.cancel('scroll');
    }
  }

  _onPointerCancel(e) {
    if (e.pointerId === this.pointerId) {
      this.cancel('pointercancel');
    }
  }

  _onKeyDown(e) {
    if (e.key === 'Escape') {
      this.cancel('escape');
    }
  }

  _onWindowBlur() {
    this.cancel('blur');
  }

  _onVisibilityChange() {
    if (this.state === 'dragging' || this.state === 'pendingHold') {
      this.cancel('visibilitychange');
    }
  }

  _onContextMenu() {
    if (this.state === 'dragging' || this.state === 'pendingHold') {
      this.cancel('contextmenu');
    }
  }

  _cleanupListeners(captureEl) {
    if (this.resizeObserver) {
      try { this.resizeObserver.disconnect(); } catch {}
      this.resizeObserver = null;
    }

    const win = typeof window !== 'undefined' ? window : null;
    if (win) {
      win.removeEventListener('pointermove', this._onPointerMove);
      win.removeEventListener('pointerup', this._onPointerUp);
      win.removeEventListener('pointercancel', this._onPointerCancel);
      win.removeEventListener('keydown', this._onKeyDown);
      win.removeEventListener('blur', this._onWindowBlur);
      win.removeEventListener('resize', this._onWindowResize);
      win.removeEventListener('scroll', this._onScroll, { capture: true });
      win.removeEventListener('visibilitychange', this._onVisibilityChange);
      win.removeEventListener('contextmenu', this._onContextMenu);
      win.removeEventListener('lostpointercapture', this._onLostPointerCapture);
    }
    if (captureEl && typeof captureEl.removeEventListener === 'function') {
      try { captureEl.removeEventListener('lostpointercapture', this._onLostPointerCapture); } catch {}
    }
  }

  cancel(reason) {
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

    const wasDragging = this.state === 'dragging';
    // 顾问加固 R1：仅真实拖拽中或超容差移动，才抑制随后的合成 click
    if (wasDragging || reason === 'tolerance-exceeded') {
      this.suppressClickUntil = Math.max(this.suppressClickUntil, Date.now() + 250);
    }

    this.state = 'idle';

    const captureEl = this.captureEl;
    const pid = this.pointerId;
    this.pointerId = null;
    this.captureEl = null;

    if (captureEl && typeof captureEl.releasePointerCapture === 'function' && pid !== null) {
      try { captureEl.releasePointerCapture(pid); } catch {}
    }

    this._cleanupListeners(captureEl);
    this._resetTabTransforms();
    this._hideOverlay();
    this._hideGhost();

    this.sourceUid = null;
    this.sourceTitle = '';
    this.lastHit = null;

    this.cachedStageRect = null;
    this.cachedTabBarRect = null;
    this.cachedTabRects = [];
    this.cachedLeafRects = [];

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
