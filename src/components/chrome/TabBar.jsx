import React, { useMemo } from 'react';
import ProviderIcon from '../sidebar/ProviderIcon.jsx';
import { XIcon, PlusIcon } from '../../lib/icons.jsx';
import { getLeaves, isBlankTab } from '../../lib/workspaceLayout.js';

/**
 * 计算标签页对应的实时运行状态（支持多分屏与单会话秒级联动）
 */
function getTabStatus(tab, leaves, agentsByUid, agent, globalSessionStatus = null) {
  const gsAgent = agent?.key ? globalSessionStatus?.get(agent.key) : null;
  const status = agent?.state || agent?.status || gsAgent?.status || gsAgent?.state || 'unknown';
  const uids = leaves.length > 0 ? leaves : (tab.activeUid ? [tab.activeUid] : (tab.uid ? [tab.uid] : []));
  if (uids.length > 0) {
    const hasWorking = uids.some((u) => {
      const a = agentsByUid.get(u);
      const gs = globalSessionStatus?.get(u);
      return a?.state === 'working' || a?.status === 'working' || gs?.status === 'working' || gs?.state === 'working';
    });
    if (hasWorking) return 'working';
    const hasIdle = uids.some((u) => {
      const a = agentsByUid.get(u);
      const gs = globalSessionStatus?.get(u);
      return a?.state === 'idle' || a?.status === 'idle' || gs?.status === 'idle' || gs?.state === 'idle';
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
  globalSessionStatus = null,
  onSelectTab,
  onCloseTab,
  onCreateTab,
  onContextMenu,
  onPointerDown,
}) {
  const { pinnedTabs, regularTabs } = useMemo(() => {
    const pinned = [];
    const regular = [];
    for (const t of tabs) {
      if (t.pinned) pinned.push(t);
      else regular.push(t);
    }
    return { pinnedTabs: pinned, regularTabs: regular };
  }, [tabs]);

  if (tabs.length === 0) return null;

  return (
    <nav className="tb-tabbar" aria-label="会话标签页">
      {pinnedTabs.length > 0 && (
        <div className="tb-tabs-pinned">
          {pinnedTabs.map((tab, idx) => {
            const tabKey = tab.id || tab.uid;
            const isActive = activeTabId ? tabKey === activeTabId : (tabKey === activeUid || tab.uid === activeUid);
            const agent = tab.activeUid ? agentsByUid.get(tab.activeUid) : agentsByUid.get(tab.uid);
            const activeTitle = agent ? agent.title : (tab.activeUid || tab.uid);
            const leaves = (tab.root && typeof tab.root === 'object') ? getLeaves(tab.root) : (tab.activeUid ? [tab.activeUid] : (tab.uid ? [tab.uid] : []));
            const title = tab.name || (leaves.length > 1 ? `${activeTitle} (${leaves.length})` : activeTitle);
            const subtitle = agent ? `${title} (${agent.deviceName})` : title;
            const isVisible = visibleUids.includes(tabKey) || (tab.activeUid && visibleUids.includes(tab.activeUid));
            const isDragging = tabKey === draggingUid || tab.uid === draggingUid;
            const status = agent?.state || agent?.status || 'unknown';
            const finalStatus = getTabStatus(tab, leaves, agentsByUid, agent, globalSessionStatus);

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

      <div className="tb-tabs-scroll">
        {regularTabs.map((tab, idx) => {
          const tabKey = tab.id || tab.uid;
          const isActive = activeTabId ? tabKey === activeTabId : (tabKey === activeUid || tab.uid === activeUid);
          const agent = tab.activeUid ? agentsByUid.get(tab.activeUid) : agentsByUid.get(tab.uid);
          const activeTitle = agent ? agent.title : (tab.activeUid || tab.uid);
          const leaves = (tab.root && typeof tab.root === 'object') ? getLeaves(tab.root) : (tab.activeUid ? [tab.activeUid] : (tab.uid ? [tab.uid] : []));

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
          const finalStatus = isBlank ? 'unknown' : getTabStatus(tab, leaves, agentsByUid, agent, globalSessionStatus);

          return (
            <div
              key={tabKey}
              data-tab-uid={tabKey}
              data-pinned="false"
              data-blank={isBlank ? 'true' : undefined}
              data-tauri-drag-region="false"
              className={`tb-tab${isBlank ? ' is-blank' : ''}${isActive ? ' is-active' : ''}${isVisible ? ' is-visible' : ''}${isDragging ? ' is-dragging-source' : ''}`}
              title={subtitle}
              role="tab"
              aria-selected={isActive}
              onClick={() => onSelectTab && onSelectTab(tabKey)}
              onContextMenu={(e) => onContextMenu && onContextMenu(e, tab)}
              onPointerDown={(e) => onPointerDown && onPointerDown(e, tab, title)}
            >
              <StatusLamp status={finalStatus} />
              <span className="tb-tab-name">{title}</span>
              <button
                type="button"
                className="tb-tab-close"
                data-tauri-drag-region="false"
                title="关闭此标签页"
                aria-label={`关闭 ${title}`}
                onClick={(e) => {
                  e.stopPropagation();
                  onCloseTab && onCloseTab(tabKey);
                }}
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
