import React, { useMemo, useState, useRef, useEffect, useLayoutEffect, useCallback } from 'react';
import ProviderIcon from '../sidebar/ProviderIcon.jsx';
import { XIcon, PlusIcon } from '../../lib/icons.jsx';
import { getLeaves, isBlankTab } from '../../lib/workspaceLayout.js';

const useIsomorphicLayoutEffect =
  typeof window !== 'undefined' ? useLayoutEffect : useEffect;

/**
 * 计算标签页对应的实时运行状态（支持多分屏与单会话秒级联动）
 */
function getTabStatus(tab, leaves, agentsByUid, agent) {
  const status = agent?.state || agent?.status || 'unknown';
  const uids = leaves.length > 0 ? leaves : (tab.activeUid ? [tab.activeUid] : (tab.uid ? [tab.uid] : []));
  if (uids.length > 0) {
    const hasWorking = uids.some((u) => {
      const a = agentsByUid.get(u);
      return a?.state === 'working' || a?.status === 'working';
    });
    if (hasWorking) return 'working';
    const hasIdle = uids.some((u) => {
      const a = agentsByUid.get(u);
      return a?.state === 'idle' || a?.status === 'idle';
    });
    if (hasIdle) return 'idle';
  }
  if (status === 'working' || status === 'idle') return status;
  return 'unknown';
}

/**
 * 会话状态指示灯
 *
 * 状态规格（顾问报告 §0 & §4.1.1）：
 * - working: 绿灯微动（CSS 缓动 pulse，尊重 prefers-reduced-motion）
 * - idle: 绿灯静止
 * - unknown / 离线: 灰空心圆圈
 */
function StatusLamp({ status = 'unknown' }) {
  const norm = status === 'working' ? 'working' : (status === 'idle' ? 'idle' : 'unknown');
  return <span className={`tb-tab-lamp is-${norm}`} aria-label={`状态: ${norm}`} />;
}

/**
 * 全局会话选项卡栏（TabBar）
 *
 * @param {Object} props
 * @param {Array<{ uid: string, pinned: boolean }>} props.tabs
 * @param {string|null} props.activeUid
 * @param {string[]} [props.visibleUids]
 * @param {Map<string, Object>} props.agentsByUid
 * @param {(uid: string) => void} props.onSelectTab
 * @param {(uid: string) => void} props.onCloseTab
 * @param {(e: React.MouseEvent, tab: { uid: string, pinned: boolean }) => void} props.onContextMenu
 */
export default function TabBar({
  tabs = [],
  activeTabId = null,
  activeUid = null,
  visibleUids = [],
  draggingUid = null,
  agentsByUid = new Map(),
  onSelectTab,
  onCloseTab,
  onCreateTab,
  onRenameTab,
  onContextMenu,
  onPointerDown,
}) {
  const [editingTabKey, setEditingTabKey] = useState(null);
  const [editingText, setEditingText] = useState('');

  const handleTabDoubleClick = useCallback((e, tabKey, currentTitle) => {
    e.preventDefault();
    e.stopPropagation();
    setEditingTabKey(tabKey);
    setEditingText(currentTitle || '');
  }, []);

  const handleCommitRename = useCallback((tabKey) => {
    const trimmed = editingText.trim();
    setEditingTabKey(null);
    if (trimmed && onRenameTab) {
      onRenameTab(tabKey, trimmed, true);
    }
  }, [editingText, onRenameTab]);

  const handleInputKeyDown = useCallback((e, tabKey) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
      handleCommitRename(tabKey);
    } else if (e.key === 'Escape' || e.key === 'Esc') {
      e.preventDefault();
      e.stopPropagation();
      setEditingTabKey(null);
      setEditingText('');
    }
  }, [handleCommitRename]);
  const { pinnedTabs, regularTabs } = useMemo(() => {
    const pinned = [];
    const regular = [];
    for (const t of tabs) {
      if (t.pinned) pinned.push(t);
      else regular.push(t);
    }
    return { pinnedTabs: pinned, regularTabs: regular };
  }, [tabs]);

  // Chrome 式 TabBar 宽度锁定机制：
  // 当点击关闭某个 Tab 时，若鼠标仍处于 TabBar 区域内，锁定当前每个 regular tab 的宽度，
  // 避免剩余 tab 宽度瞬间放大/回退导致后续 tab 的关闭按钮从鼠标光标下移开；
  // 鼠标离开 TabBar 区域后（mouseleave），解除锁定并平滑自适应重新分配。
  const [lockedTabWidth, setLockedTabWidth] = useState(null);
  const isPointerInsideRef = useRef(false);
  const scrollContainerRef = useRef(null);
  const regularTabRefs = useRef(new Map());

  // Rare UI 弹性胶囊状态：保存当前激活项的 { left, width, scaleX, opacity }
  const [capsuleStyle, setCapsuleStyle] = useState({ left: 0, width: 100, scaleX: 1, opacity: 0 });

  // 记录每个 regular tab 的当前真实测量宽度
  const measureCurrentTabWidth = useCallback((targetKey) => {
    if (targetKey && regularTabRefs.current.has(targetKey)) {
      const el = regularTabRefs.current.get(targetKey);
      if (el) {
        const w = el.getBoundingClientRect().width;
        if (w > 0) return Math.round(w * 10) / 10;
      }
    }
    if (scrollContainerRef.current) {
      const tabEl = scrollContainerRef.current.querySelector('.tb-tab:not(.tb-tab-pinned)');
      if (tabEl) {
        const w = tabEl.getBoundingClientRect().width;
        if (w > 0) return Math.round(w * 10) / 10;
      }
    }
    return null;
  }, []);

  // 当点击关闭按钮时，立即在同步执行栈中捕获并锁定当前宽度
  const handleCloseTabWithLock = useCallback((e, tabKey) => {
    e.stopPropagation();
    if (isPointerInsideRef.current && regularTabs.length > 1) {
      const currentWidth = lockedTabWidth !== null ? lockedTabWidth : measureCurrentTabWidth(tabKey);
      if (currentWidth && currentWidth > 0) {
        setLockedTabWidth(currentWidth);
        // 同步直接写到容器 DOM style 上，彻底消除 React 渲染批处理到 commit 之间的瞬态窗口！
        if (scrollContainerRef.current) {
          scrollContainerRef.current.setAttribute('data-locked', 'true');
          scrollContainerRef.current.style.setProperty('--tb-tab-width', `${currentWidth}px`);
        }
      }
    }
    if (onCloseTab) {
      onCloseTab(tabKey);
    }
  }, [onCloseTab, regularTabs.length, lockedTabWidth, measureCurrentTabWidth]);

  // 鼠标进入 TabBar 区域
  const handleMouseEnterTabBar = useCallback(() => {
    isPointerInsideRef.current = true;
  }, []);

  // 鼠标离开 TabBar 区域：平滑解除宽度锁定
  const handleMouseLeaveTabBar = useCallback(() => {
    isPointerInsideRef.current = false;
    setLockedTabWidth(null);
    if (scrollContainerRef.current) {
      scrollContainerRef.current.removeAttribute('data-locked');
      scrollContainerRef.current.style.removeProperty('--tb-tab-width');
    }
  }, []);

  // 如果剩余 regularTabs 减少到 <= 1，自动清空锁死
  useEffect(() => {
    if (regularTabs.length <= 1 && lockedTabWidth !== null) {
      setLockedTabWidth(null);
    }
  }, [regularTabs.length, lockedTabWidth]);

  // 更新 Rare UI 弹性胶囊位置
  useIsomorphicLayoutEffect(() => {
    if (!scrollContainerRef.current) return;
    const activeKey = activeTabId || activeUid;
    if (!activeKey) {
      setCapsuleStyle((prev) => (prev.opacity === 0 ? prev : { ...prev, opacity: 0 }));
      return;
    }

    // 查找当前激活的 DOM 元素（优先在 regularTabs 中）
    const targetEl = regularTabRefs.current.get(activeKey);
    if (!targetEl || !scrollContainerRef.current) {
      setCapsuleStyle((prev) => (prev.opacity === 0 ? prev : { ...prev, opacity: 0 }));
      return;
    }

    const containerRect = scrollContainerRef.current.getBoundingClientRect();
    const targetRect = targetEl.getBoundingClientRect();

    const scrollLeft = scrollContainerRef.current.scrollLeft || 0;
    const left = targetRect.left - containerRect.left + scrollLeft;
    const width = targetRect.width;

    if (width > 0) {
      setCapsuleStyle({
        left: Math.round(left),
        width: Math.round(width),
        scaleX: 1,
        opacity: 1,
      });
    }
  }, [activeTabId, activeUid, regularTabs, lockedTabWidth]);

  if (tabs.length === 0) return null;

  return (
    <nav
      className="tb-tabbar"
      data-locked-width={lockedTabWidth !== null ? lockedTabWidth : undefined}
      aria-label="会话标签页"
      onMouseEnter={handleMouseEnterTabBar}
      onMouseLeave={handleMouseLeaveTabBar}
    >
      {pinnedTabs.length > 0 && (
        <div className="tb-tabs-pinned">
          {pinnedTabs.map((tab, idx) => {
            const tabKey = tab.id || tab.uid;
            const isActive = activeTabId ? tabKey === activeTabId : (tabKey === activeUid || tab.uid === activeUid);
            const leaves = (tab.root && typeof tab.root === 'object') ? getLeaves(tab.root) : (tab.activeUid ? [tab.activeUid] : (tab.uid ? [tab.uid] : []));
            const effectiveActiveUid = (leaves.length > 0 && tab.activeUid && leaves.includes(tab.activeUid))
              ? tab.activeUid
              : (leaves[0] || tab.activeUid || tab.uid);
            const agent = effectiveActiveUid ? agentsByUid.get(effectiveActiveUid) : agentsByUid.get(tab.uid);
            const activeTitle = agent ? agent.title : (effectiveActiveUid || tab.uid);
            const title = tab.name || (leaves.length > 1 ? `${activeTitle} (${leaves.length})` : activeTitle);
            const subtitle = agent ? `${title} (${agent.deviceName})` : title;
            const isVisible = visibleUids.includes(tabKey) || (tab.activeUid && visibleUids.includes(tab.activeUid));
            const isDragging = tabKey === draggingUid || tab.uid === draggingUid;
            const status = agent?.state || agent?.status || 'unknown';
            const finalStatus = getTabStatus(tab, leaves, agentsByUid, agent);

            return (
              <div
                key={tabKey}
                data-tab-uid={tabKey}
                data-pinned="true"
                data-tauri-drag-region="false"
                className={`tb-tab tb-tab-pinned${isActive ? ' is-active' : ''}${isVisible ? ' is-visible' : ''}${isDragging ? ' is-dragging-source' : ''}`}
                title={subtitle}
                aria-label={subtitle}
                role="tab"
                aria-selected={isActive}
                onClick={() => onSelectTab && onSelectTab(tabKey)}
                onContextMenu={(e) => onContextMenu && onContextMenu(e, tab)}
                onPointerDown={(e) => onPointerDown && onPointerDown(e, tab, title)}
              >
                {agent?.provider ? (
                  <ProviderIcon provider={agent.provider} size={15} />
                ) : (
                  <span className="tb-tab-initial">{String(title || 'W').slice(0, 1).toUpperCase()}</span>
                )}
                <StatusLamp status={finalStatus} />
              </div>
            );
          })}
        </div>
      )}

      <div
        ref={scrollContainerRef}
        className="tb-tabs-scroll"
        data-has-capsule={capsuleStyle.opacity > 0 ? 'true' : undefined}
        data-locked={lockedTabWidth !== null ? 'true' : undefined}
        style={lockedTabWidth !== null ? { '--tb-tab-width': `${lockedTabWidth}px` } : undefined}
      >
        {/* Rare UI 弹性物理胶囊背景指示器（纯 Compositor transform 加速） */}
        <span
          className="tb-tab-capsule"
          aria-hidden="true"
          style={{
            transform: `translate3d(${capsuleStyle.left}px, 0, 0) scaleX(${capsuleStyle.scaleX})`,
            width: `${capsuleStyle.width || 100}px`,
            opacity: capsuleStyle.opacity,
          }}
        />

        {regularTabs.map((tab, idx) => {
          const tabKey = tab.id || tab.uid;
          const isActive = activeTabId ? tabKey === activeTabId : (tabKey === activeUid || tab.uid === activeUid);
          const leaves = (tab.root && typeof tab.root === 'object') ? getLeaves(tab.root) : (tab.activeUid ? [tab.activeUid] : (tab.uid ? [tab.uid] : []));
          const effectiveActiveUid = (leaves.length > 0 && tab.activeUid && leaves.includes(tab.activeUid))
            ? tab.activeUid
            : (leaves[0] || tab.activeUid || tab.uid);
          const agent = effectiveActiveUid ? agentsByUid.get(effectiveActiveUid) : agentsByUid.get(tab.uid);
          const activeTitle = agent ? agent.title : (effectiveActiveUid || tab.uid);

          const isBlank = isBlankTab(tab);
          let title;
          if (tab.name) {
            title = tab.name;
          } else if (isBlank) {
            title = '新工作台';
          } else if (tab.activeUid || agent) {
            title = leaves.length > 1 ? `${activeTitle} (${leaves.length})` : activeTitle;
          } else if (tab.uid && !tab.uid.startsWith('tab-')) {
            title = tab.uid;
          } else {
            title = `工作区 ${idx + 1}`;
          }

          const subtitle = agent ? `${title} (${agent.deviceName})` : title;
          const isVisible = visibleUids.includes(tabKey) || (tab.activeUid && visibleUids.includes(tab.activeUid));
          const isDragging = tabKey === draggingUid || tab.uid === draggingUid;
          const status = agent?.state || agent?.status || 'unknown';
          const finalStatus = isBlank ? 'unknown' : getTabStatus(tab, leaves, agentsByUid, agent);

          return (
            <div
              key={tabKey}
              ref={(el) => {
                if (el) regularTabRefs.current.set(tabKey, el);
                else regularTabRefs.current.delete(tabKey);
              }}
              data-tab-uid={tabKey}
              data-pinned="false"
              data-blank={isBlank ? 'true' : undefined}
              data-title-locked={tab.isCustomTitle ? 'true' : undefined}
              data-tauri-drag-region="false"
              className={`tb-tab${isBlank ? ' is-blank' : ''}${isActive ? ' is-active' : ''}${isVisible ? ' is-visible' : ''}${isDragging ? ' is-dragging-source' : ''}`}
              title={subtitle}
              role="tab"
              aria-selected={isActive}
              onClick={() => onSelectTab && onSelectTab(tabKey)}
              onDoubleClick={(e) => handleTabDoubleClick(e, tabKey, title)}
              onContextMenu={(e) => onContextMenu && onContextMenu(e, tab)}
              onPointerDown={(e) => onPointerDown && onPointerDown(e, tab, title)}
            >
              <StatusLamp status={finalStatus} />
              {editingTabKey === tabKey ? (
                <input
                  className="chr-tab-title-input tb-tab-title-input"
                  type="text"
                  autoFocus
                  value={editingText}
                  data-tauri-drag-region="false"
                  onClick={(e) => e.stopPropagation()}
                  onPointerDown={(e) => e.stopPropagation()}
                  onDoubleClick={(e) => e.stopPropagation()}
                  onChange={(e) => setEditingText(e.target.value)}
                  onKeyDown={(e) => handleInputKeyDown(e, tabKey)}
                  onBlur={() => handleCommitRename(tabKey)}
                />
              ) : (
                <span className="tb-tab-name">{title}</span>
              )}
              <button
                type="button"
                className="tb-tab-close"
                data-tauri-drag-region="false"
                title="关闭此标签页"
                aria-label={`关闭 ${title}`}
                onClick={(e) => handleCloseTabWithLock(e, tabKey)}
              >
                <XIcon size={11} strokeWidth={2.2} />
              </button>
            </div>
          );
        })}
      </div>

      <button
        type="button"
        className="tb-btn tb-tab-add"
        data-tauri-drag-region="false"
        title="新建工作台标签页 (Cmd+T)"
        aria-label="新建工作台标签页"
        onClick={onCreateTab}
      >
        <PlusIcon size={14} strokeWidth={2} />
      </button>
    </nav>
  );
}
