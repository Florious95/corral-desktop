import React, { useState, useEffect, useLayoutEffect, useRef, useMemo, useCallback } from 'react';
import './terminal.css';
import { XIcon } from '../../lib/icons.jsx';
import {
  projectLayout,
  updateNodeRatio,
  migrateLegacyPanes,
  getLeaves,
  computeSplitRatioFromCoord,
  computeSplitRatioFromDelta,
  SPLIT_GAP_PX,
  MIN_PANE_W,
  MIN_PANE_H,
} from '../../lib/workspaceLayout.js';
import { nativeCapabilities } from '../../core/nativeCapabilities.js';

export { SPLIT_GAP_PX, MIN_PANE_W, MIN_PANE_H };

/**
 * 同父平铺常驻分屏舞台（TerminalStage / SplitPanes，UI-SPEC §6.1，2026-09-15 裁定）
 *
 * 核心杀手锏：
 * 所有的 TerminalPane 作为同一 DOM 父容器下的直接子组件，通过 absolute 定位投影；
 * 无论怎么分屏切分、前后台切换，React Key 与组件层级永远不变，彻底杜绝 Unmount、零 xterm 重建、零闪屏！
 *
 * @param {Object} props
 * @param {Object|null} [props.root]                  二叉分屏树 root
 * @param {Array<{uid: string, pinned: boolean}>} [props.tabs] 全局 Tab 列表
 * @param {string|null} [props.activeUid]             当前焦点会话 uid
 * @param {string|null} [props.activeTabId]           当前选中的工作台 Tab id
 * @param {string|null} [props.previewUid]            虚空预览槽会话 uid
 * @param {Map<string, Object>} [props.agentByKey]    会话数据映射表
 * @param {(agent: Object, dims?: { containerWidth: number, containerHeight: number }) => JSX.Element} props.renderPane 渲染终端内容
 * @param {(uid: string) => void} [props.onFocusPane] 聚焦窗格
 * @param {(e: React.MouseEvent, uid: string) => void} [props.onPaneMenu] 右键菜单
 * @param {(uid: string) => void} [props.onClosePane] 关闭此分屏
 * @param {({ tabId: string, path: string, ratio: number }) => void} [props.onSplitResize] 比例调整回调
 * @param {Array} [props.panes]                       旧接口兼容备用
 */
export default function SplitPanes({
  root = null,
  tabs = [],
  activeUid = null,
  activeTabId = null,
  previewUid = null,
  agentByKey = new Map(),
  renderPane,
  onFocusPane,
  onPaneMenu,
  onClosePane,
  onSplitResize,
  panes = [],
  stageRef: externalStageRef,
}) {
  const localStageRef = useRef(null);
  const stageRef = externalStageRef || localStageRef;
  const [rect, setRect] = useState(() => ({ x: 0, y: 0, w: 0, h: 0 }));
  const resizeSettled = useRef(false);

  // 局部 60fps 拖拽暂态树与手柄交互状态 (Issue #272)
  const [localPreviewRoot, setLocalPreviewRoot] = useState(null);
  const [activeResizerPath, setActiveResizerPath] = useState(null);
  const resizerDragRef = useRef(null);

  // 终止并清理当前拖拽手柄状态（供取消、失焦、Resize、Escape 或跨 Tab 切出时安全复位）
  const cancelDrag = useCallback(() => {
    const drag = resizerDragRef.current;
    if (!drag) return;
    if (drag.rafId) cancelAnimationFrame(drag.rafId);
    try {
      drag.targetElement?.releasePointerCapture(drag.pointerId);
    } catch {}
    resizerDragRef.current = null;
    setActiveResizerPath(null);
    setLocalPreviewRoot(null);
  }, []);

  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;

    const updateRect = () => {
      const w = el.clientWidth || el.offsetWidth || 0;
      const h = el.clientHeight || el.offsetHeight || 0;
      setRect((prev) => {
        if (prev.w === w && prev.h === h) return prev;
        if (resizerDragRef.current) {
          cancelDrag();
        }
        return { x: 0, y: 0, w, h };
      });
    };

    updateRect();
    const handleResizeSettled = () => {
      resizeSettled.current = true;
      // Commit the measured stage and its child rectangles together before
      // fitting terminals. A native end notification can precede React's RO commit.
      setRect({ x: 0, y: 0, w: el.clientWidth, h: el.clientHeight });
    };
    window.addEventListener('agentmirror:window-resize-settled', handleResizeSettled);
    if (typeof ResizeObserver !== 'undefined') {
      const ro = new ResizeObserver(updateRect);
      ro.observe(el);
      return () => {
        ro.disconnect();
        window.removeEventListener('agentmirror:window-resize-settled', handleResizeSettled);
      };
    }
    window.addEventListener('resize', updateRect);
    return () => {
      window.removeEventListener('resize', updateRect);
      window.removeEventListener('agentmirror:window-resize-settled', handleResizeSettled);
    };
  }, [cancelDrag]);

  // 兼容旧接口：若未传 root，则通过 legacy panes 数组迁移构建
  const effectiveRoot = useMemo(() => {
    if (root) return root;
    if (panes && panes.length > 0) {
      return migrateLegacyPanes(panes.map((p) => p.key), activeUid).root;
    }
    return null;
  }, [root, panes, activeUid]);

  // 在实际 DOM 尚未测量（如 Node/无头测试环境中 clientWidth 为 0）时，提供合理的投影基准尺寸
  const effectiveRect = useMemo(() => {
    return (rect.w > 0 && rect.h > 0) ? rect : { x: 0, y: 0, w: 1000, h: 600 };
  }, [rect]);

  // 纯几何投影计算可见叶子的坐标与分割手柄（统一 6px 间隙，Issue #271 / #272）
  const isDraggingStale = Boolean(
    resizerDragRef.current && (
      (resizerDragRef.current.startTabId && activeTabId && resizerDragRef.current.startTabId !== activeTabId) ||
      (resizerDragRef.current.startRoot && effectiveRoot && resizerDragRef.current.startRoot !== effectiveRoot) ||
      (resizerDragRef.current.startPreviewUid !== previewUid)
    )
  );
  const currentTree = (localPreviewRoot && !isDraggingStale) ? localPreviewRoot : effectiveRoot;
  const { panes: layout, resizers } = useMemo(
    () => projectLayout(currentTree, effectiveRect, SPLIT_GAP_PX),
    [currentTree, effectiveRect]
  );
  const visibleUids = useMemo(() => Object.keys(layout), [layout]);

  // A committed split tree is final. Viewport changes retain their observer
  // debounce, but a completed drop need not wait for another quiet period.
  const previousRoot = useRef(effectiveRoot);
  useLayoutEffect(() => {
    const committed = previousRoot.current !== effectiveRoot || resizeSettled.current;
    previousRoot.current = effectiveRoot;
    resizeSettled.current = false;
    if (committed && nativeCapabilities.platform === 'macos') {
      stageRef.current?.dispatchEvent(new Event('terminal:layout-settled'));
    }
  }, [effectiveRoot, rect]);

  // 常驻宿主集合：访问过的 Tab 保持在常驻列表中，关闭时才真正清理卸载
  const [residentUids, setResidentUids] = useState([]);
  const lastRects = useRef(new Map());

  useEffect(() => {
    const validUids = new Set(
      (tabs && tabs.length > 0)
        ? tabs.flatMap((t) => {
            if (t.root) return getLeaves(t.root);
            if (t.activeUid) return [t.activeUid];
            return [t.uid];
          })
        : (panes && panes.length > 0 ? panes.map((p) => p.key) : visibleUids)
    );
    // previewUid lives outside workspace.tabs until it is committed to a tab.
    // Keep it resident so the first click can mount its TerminalPane immediately.
    if (previewUid) validUids.add(previewUid);

    setResidentUids((prev) => {
      const filtered = prev.filter((uid) => validUids.has(uid));
      const existing = new Set(filtered);
      const toAdd = visibleUids.filter((uid) => !existing.has(uid) && validUids.has(uid));
      if (toAdd.length === 0 && filtered.length === prev.length) {
        return prev;
      }
      return [...filtered, ...toAdd];
    });
  }, [tabs, panes, previewUid, visibleUids]);

  // 记录每个可见窗格的最新非零矩形（供移入后台时保持尺寸，避免坍缩为 0 或 display:none）
  for (const uid of visibleUids) {
    if (layout[uid]) {
      lastRects.current.set(uid, layout[uid]);
    }
  }

  // 外部 root / Tab / preview 发生突变时，即刻清理活动拖拽手势与本地预览（消除过期残留）
  useEffect(() => {
    const drag = resizerDragRef.current;
    if (!drag) return;
    const currentActiveId = activeTabId || tabs.find((t) => t.root === effectiveRoot)?.id;
    if (
      (drag.startTabId && currentActiveId && drag.startTabId !== currentActiveId) ||
      (drag.startRoot && effectiveRoot && drag.startRoot !== effectiveRoot) ||
      (drag.startPreviewUid !== previewUid)
    ) {
      cancelDrag();
    }
  }, [effectiveRoot, activeTabId, previewUid, tabs, cancelDrag]);

  // 全局按键 / 窗口失焦 / 窗口 Resize 即时取消手势与复原
  useEffect(() => {
    const handleKeyDown = (e) => {
      if (e.key === 'Escape' && resizerDragRef.current) {
        e.preventDefault();
        e.stopPropagation();
        cancelDrag();
      }
    };
    const handleBlur = () => {
      if (resizerDragRef.current) {
        cancelDrag();
      }
    };
    const handleWindowResize = () => {
      if (resizerDragRef.current) {
        cancelDrag();
      }
    };

    window.addEventListener('keydown', handleKeyDown, true);
    window.addEventListener('blur', handleBlur);
    window.addEventListener('resize', handleWindowResize);
    return () => {
      window.removeEventListener('keydown', handleKeyDown, true);
      window.removeEventListener('blur', handleBlur);
      window.removeEventListener('resize', handleWindowResize);
    };
  }, [cancelDrag]);

  // 手柄拖拽交互处理（轴向真实对齐、消除吸中、零强制重排、递归叶窗格保护，Issue #271 / #272 R4 终审）
  const handleResizerPointerDown = useCallback((e, resizer) => {
    if (e.button !== 0) return;
    e.preventDefault();
    e.stopPropagation();
    try {
      e.currentTarget.setPointerCapture(e.pointerId);
    } catch {}

    const isX = resizer.axis === 'x';
    const startX = e.clientX;
    const startY = e.clientY;
    const startCoord = isX ? startX : startY;
    const startFirstPx = isX
      ? (resizer.rect.x - resizer.parentRect.x)
      : (resizer.rect.y - resizer.parentRect.y);

    const stageEl = stageRef.current;
    const stageRect = stageEl
      ? stageEl.getBoundingClientRect()
      : { left: 0, top: 0, width: effectiveRect.w, height: effectiveRect.h };

    const startTabId = activeTabId || tabs.find((t) => t.root === effectiveRoot)?.id || 'tab-1';

    resizerDragRef.current = {
      pointerId: e.pointerId,
      isX,
      startX,
      startY,
      startCoord,
      startFirstPx,
      stageLeft: stageRect.left,
      stageTop: stageRect.top,
      startTabId,
      startRoot: effectiveRoot,
      startPreviewUid: previewUid,
      resizer,
      startRatio: resizer.ratio,
      currentRatio: resizer.ratio,
      currentFirstPx: startFirstPx,
      baseRoot: effectiveRoot,
      targetElement: e.currentTarget,
      rafId: null,
    };
    setActiveResizerPath(resizer.path);
  }, [effectiveRoot, activeTabId, previewUid, tabs]);

  const handleResizerPointerMove = useCallback((e) => {
    const drag = resizerDragRef.current;
    if (!drag || drag.pointerId !== e.pointerId) return;
    e.preventDefault();
    e.stopPropagation();

    // 跨 Tab 身份栅栏与外部 root 漂移校验
    const currentActiveId = activeTabId || tabs.find((t) => t.root === effectiveRoot)?.id;
    if (drag.startTabId && currentActiveId && drag.startTabId !== currentActiveId) {
      cancelDrag();
      return;
    }
    if (drag.startRoot && effectiveRoot && drag.startRoot !== effectiveRoot) {
      cancelDrag();
      return;
    }

    const currentCoord = drag.isX ? e.clientX : e.clientY;
    const { ratio, firstPx, changed } = computeSplitRatioFromDelta(
      drag.resizer,
      currentCoord,
      drag.startCoord,
      drag.startFirstPx,
      drag.startRatio,
      SPLIT_GAP_PX
    );

    // 轴向整数像素尺寸相对于当前预览未变化时，无视觉变更，绝不调度 rAF；
    // 若移回按下时的初始坐标（firstPx === startFirstPx），即时将预览恢复更新回起点状态（Issue #272 R5 闭环）
    if (firstPx === drag.currentFirstPx) return;
    drag.currentRatio = ratio;
    drag.currentFirstPx = firstPx;

    if (drag.rafId) cancelAnimationFrame(drag.rafId);
    drag.rafId = requestAnimationFrame(() => {
      if (!resizerDragRef.current) return;
      const parts = drag.resizer.path.startsWith('root.')
        ? drag.resizer.path.slice(5).split('.')
        : drag.resizer.path === 'root'
        ? []
        : drag.resizer.path.split('.');
      const updated = (firstPx === drag.startFirstPx)
        ? drag.baseRoot
        : updateNodeRatio(drag.baseRoot, parts, ratio);
      setLocalPreviewRoot(updated);
    });
  }, [activeTabId, tabs, effectiveRoot, cancelDrag]);

  const handleResizerPointerUp = useCallback((e) => {
    const drag = resizerDragRef.current;
    if (!drag || drag.pointerId !== e.pointerId) return;
    e.preventDefault();
    e.stopPropagation();

    try {
      e.currentTarget.releasePointerCapture(e.pointerId);
    } catch {}

    if (drag.rafId) cancelAnimationFrame(drag.rafId);

    const { resizer, startRatio, startTabId, startRoot } = drag;

    // 1. 跨 Tab 身份栅栏与根树漂移校验
    const currentActiveId = activeTabId || tabs.find((t) => t.root === effectiveRoot)?.id;
    if (startTabId && currentActiveId && startTabId !== currentActiveId) {
      cancelDrag();
      return;
    }
    if (startRoot && effectiveRoot && startRoot !== effectiveRoot) {
      cancelDrag();
      return;
    }

    // 2. pointerup 松手终态坐标参与最后一次整数尺寸计算
    const isX = drag.isX;
    const clientCoord = isX ? e.clientX : e.clientY;
    const { ratio: finalRatio, changed } = (typeof clientCoord === 'number' && !Number.isNaN(clientCoord))
      ? computeSplitRatioFromDelta(
          drag.resizer,
          clientCoord,
          drag.startCoord,
          drag.startFirstPx,
          drag.startRatio,
          SPLIT_GAP_PX
        )
      : { ratio: drag.currentRatio, changed: drag.currentRatio !== startRatio };

    resizerDragRef.current = null;
    setActiveResizerPath(null);
    setLocalPreviewRoot(null);

    // 3. 只有整数像素尺寸产生真实变化（changed === true 且 finalRatio !== startRatio）才提交持久化
    if (changed && finalRatio !== startRatio && onSplitResize) {
      onSplitResize({
        tabId: startTabId,
        path: resizer.path,
        ratio: finalRatio,
        startRoot,
      });
    }
  }, [effectiveRoot, onSplitResize, activeTabId, tabs, cancelDrag]);

  const handleResizerPointerCancel = useCallback((e) => {
    cancelDrag();
  }, [cancelDrag]);

  const isEmpty = visibleUids.length === 0;

  return (
    <div
      className="splitpanes terminal-stage"
      ref={stageRef}
      data-stage="terminal-stage"
      data-platform={nativeCapabilities.platform}
      data-multi-pane={visibleUids.length > 1 ? 'true' : undefined}
    >
      {isEmpty && (
        <div className="splitpanes-empty">
          <div>
            <div>从左侧选择一个 Agent</div>
            <span className="splitpanes-empty-sub">点击打开、或右键在右侧分屏展示</span>
          </div>
        </div>
      )}

      {residentUids.map((uid) => {
        const isVisible = layout[uid] !== undefined;
        const currentRect = isVisible
          ? layout[uid]
          : (lastRects.current.get(uid) || { x: 0, y: 0, w: effectiveRect.w, h: effectiveRect.h });
        // CSS follows the viewport before ResizeObserver/React commits its new
        // projection. Keep the outer bottom edge anchored during that interval.
        const anchorBottom = isVisible && nativeCapabilities.platform === 'macos'
          && currentRect.y + currentRect.h === effectiveRect.h;
        const isActive = uid === activeUid;
        const agent = agentByKey?.get?.(uid) || (panes && panes.find((p) => p.key === uid)) || {
          key: uid,
          ref: uid.includes('::') ? uid.split('::')[1] : uid,
          title: uid,
        };

        return (
          <div
            key={uid}
            data-pane-uid={uid}
            className={`pane-host${isVisible ? '' : ' is-hidden'}${isActive ? ' is-active' : ''}`}
            style={{
              position: 'absolute',
              left: `${currentRect.x}px`,
              top: `${currentRect.y}px`,
              width: `${currentRect.w}px`,
              height: anchorBottom ? undefined : `${currentRect.h}px`,
              bottom: anchorBottom ? 0 : undefined,
              visibility: isVisible ? 'visible' : 'hidden',
              pointerEvents: isVisible ? 'auto' : 'none',
            }}
            inert={!isVisible}
            aria-hidden={!isVisible ? 'true' : undefined}
            onMouseDown={(e) => {
              if (e.target?.closest?.('.pane-close-btn, [data-no-focus="true"]')) {
                return;
              }
              if (uid !== previewUid && onFocusPane) {
                onFocusPane(uid);
              }
            }}
            onContextMenu={(e) => onPaneMenu && onPaneMenu(e, uid)}
          >
            {renderPane ? renderPane(agent, { containerWidth: currentRect.w, containerHeight: currentRect.h }) : null}
            {isVisible && visibleUids.length > 1 && onClosePane && (
              <button
                type="button"
                className="pane-close-btn"
                title="关闭此分屏"
                aria-label="关闭此分屏"
                onClick={(e) => {
                  e.stopPropagation();
                  onClosePane(uid);
                }}
              >
                <XIcon size={12} strokeWidth={2.2} />
              </button>
            )}
          </div>
        );
      })}

      {visibleUids.length > 1 && resizers.map((r) => (
        <div
          key={r.path}
          className={`split-resizer${(activeResizerPath === r.path && !isDraggingStale) ? ' is-dragging' : ''}`}
          data-axis={r.axis}
          data-resizer-path={r.path}
          role="separator"
          aria-orientation={r.axis === 'x' ? 'vertical' : 'horizontal'}
          aria-valuenow={Math.round(r.ratio * 100)}
          aria-valuemin={10}
          aria-valuemax={90}
          aria-label={`调节分屏比例 (${r.axis === 'x' ? '左右' : '上下'})`}
          tabIndex={-1}
          style={{
            position: 'absolute',
            left: `${r.rect.x}px`,
            top: `${r.rect.y}px`,
            width: `${r.rect.w}px`,
            height: `${r.rect.h}px`,
          }}
          onPointerDown={(e) => handleResizerPointerDown(e, r)}
          onPointerMove={handleResizerPointerMove}
          onPointerUp={handleResizerPointerUp}
          onPointerCancel={handleResizerPointerCancel}
          onLostPointerCapture={handleResizerPointerCancel}
        />
      ))}
    </div>
  );
}

export { SplitPanes as TerminalStage };
