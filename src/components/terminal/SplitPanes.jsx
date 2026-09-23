import React, { useState, useEffect, useLayoutEffect, useRef, useMemo } from 'react';
import './terminal.css';
import { XIcon } from '../../lib/icons.jsx';
import { project, migrateLegacyPanes, getLeaves } from '../../lib/workspaceLayout.js';
import { nativeCapabilities } from '../../core/nativeCapabilities.js';

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
 * @param {string|null} [props.previewUid]            虚空预览槽会话 uid
 * @param {Map<string, Object>} [props.agentByKey]    会话数据映射表
 * @param {(agent: Object) => JSX.Element} props.renderPane 渲染终端内容
 * @param {(uid: string) => void} [props.onFocusPane] 聚焦窗格
 * @param {(e: React.MouseEvent, uid: string) => void} [props.onPaneMenu] 右键菜单
 * @param {(uid: string) => void} [props.onClosePane] 关闭此分屏
 * @param {Array} [props.panes]                       旧接口兼容备用
 */
export default function SplitPanes({
  root = null,
  tabs = [],
  activeUid = null,
  previewUid = null,
  agentByKey = new Map(),
  renderPane,
  onFocusPane,
  onPaneMenu,
  onClosePane,
  panes = [],
  stageRef: externalStageRef,
}) {
  const localStageRef = useRef(null);
  const stageRef = externalStageRef || localStageRef;
  const [rect, setRect] = useState(() => ({ x: 0, y: 0, w: 0, h: 0 }));
  const resizeSettled = useRef(false);

  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;

    const updateRect = () => {
      const w = el.clientWidth || el.offsetWidth || 0;
      const h = el.clientHeight || el.offsetHeight || 0;
      setRect((prev) => (prev.w === w && prev.h === h ? prev : { x: 0, y: 0, w, h }));
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
  }, []);

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

  // 纯几何投影计算可见叶子的坐标
  const layout = useMemo(() => project(effectiveRoot, effectiveRect, 1), [effectiveRoot, effectiveRect]);
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

  const isEmpty = visibleUids.length === 0;

  return (
    <div
      className="splitpanes terminal-stage"
      ref={stageRef}
      data-stage="terminal-stage"
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
              height: `${currentRect.h}px`,
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
    </div>
  );
}

export { SplitPanes as TerminalStage };
