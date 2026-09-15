import React, { useMemo } from 'react';
import ProviderIcon from '../sidebar/ProviderIcon.jsx';
import { XIcon } from '../../lib/icons.jsx';

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
  activeUid = null,
  visibleUids = [],
  draggingUid = null,
  agentsByUid = new Map(),
  onSelectTab,
  onCloseTab,
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
          {pinnedTabs.map((tab) => {
            const agent = agentsByUid.get(tab.uid);
            const title = agent ? agent.title : tab.uid;
            const subtitle = agent ? `${agent.title} (${agent.deviceName})` : tab.uid;
            const isActive = tab.uid === activeUid;
            const isVisible = visibleUids.includes(tab.uid);
            const isDragging = tab.uid === draggingUid;
            const status = agent?.state || agent?.status || 'unknown';

            return (
              <div
                key={tab.uid}
                data-tab-uid={tab.uid}
                data-pinned="true"
                className={`tb-tab tb-tab-pinned${isActive ? ' is-active' : ''}${isVisible ? ' is-visible' : ''}${isDragging ? ' is-dragging-source' : ''}`}
                title={subtitle}
                aria-label={subtitle}
                role="tab"
                aria-selected={isActive}
                onClick={() => onSelectTab && onSelectTab(tab.uid)}
                onContextMenu={(e) => onContextMenu && onContextMenu(e, tab)}
                onPointerDown={(e) => onPointerDown && onPointerDown(e, tab, title)}
              >
                {agent?.provider ? (
                  <ProviderIcon provider={agent.provider} size={15} />
                ) : (
                  <span className="tb-tab-initial">{title.slice(0, 1).toUpperCase()}</span>
                )}
                <StatusLamp status={status} />
              </div>
            );
          })}
        </div>
      )}

      <div className="tb-tabs-scroll">
        {regularTabs.map((tab) => {
          const agent = agentsByUid.get(tab.uid);
          const title = agent ? agent.title : tab.uid;
          const subtitle = agent ? `${agent.title} (${agent.deviceName})` : tab.uid;
          const isActive = tab.uid === activeUid;
          const isVisible = visibleUids.includes(tab.uid);
          const isDragging = tab.uid === draggingUid;
          const status = agent?.state || agent?.status || 'unknown';

          return (
            <div
              key={tab.uid}
              data-tab-uid={tab.uid}
              data-pinned="false"
              className={`tb-tab${isActive ? ' is-active' : ''}${isVisible ? ' is-visible' : ''}${isDragging ? ' is-dragging-source' : ''}`}
              title={subtitle}
              role="tab"
              aria-selected={isActive}
              onClick={() => onSelectTab && onSelectTab(tab.uid)}
              onContextMenu={(e) => onContextMenu && onContextMenu(e, tab)}
              onPointerDown={(e) => onPointerDown && onPointerDown(e, tab, title)}
            >
              <StatusLamp status={status} />
              <span className="tb-tab-name">{title}</span>
              <button
                type="button"
                className="tb-tab-close"
                title="关闭此标签页"
                aria-label={`关闭 ${title}`}
                onClick={(e) => {
                  e.stopPropagation();
                  onCloseTab && onCloseTab(tab.uid);
                }}
              >
                <XIcon size={11} strokeWidth={2.2} />
              </button>
            </div>
          );
        })}
      </div>
    </nav>
  );
}
