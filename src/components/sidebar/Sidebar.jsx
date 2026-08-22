// 侧栏容器（UI-SPEC §5.1）。宽度折叠动画在外层，内层固定 280px 保证折叠时内容不重排。
import SpacesList from './SpacesList.jsx';
import AgentsList from './AgentsList.jsx';
import { SearchIcon, ChevronDown, LayersIcon, GearIcon } from '../../lib/icons.jsx';
import './sidebar.css';

function GroupHeader({ open, onToggle, children }) {
  return (
    <span className="sidebar-group-btn" onClick={onToggle}>
      <span className="sidebar-chevron" style={{ transform: `rotate(${open ? 0 : -90}deg)` }}>
        <ChevronDown size={11} strokeWidth={2.2} />
      </span>
      <span className="sidebar-group-label">{children}</span>
    </span>
  );
}

/**
 * @param {Object} props
 * @param {boolean} props.collapsed
 * @param {boolean} props.spacesOpen
 * @param {() => void} props.onToggleSpaces
 * @param {boolean} props.agentsOpen
 * @param {() => void} props.onToggleAgents
 * @param {string}  props.selected                     'all' | 'fav' | Space.key
 * @param {(key:string) => void} props.onSelect
 * @param {Array} props.spaces
 * @param {Array} props.agents                         已按 selected 过滤后的可见集合
 * @param {string[]} props.openKeys                    当前在分裂列里的 Agent.key
 * @param {Object<string,boolean>} [props.closing]     正在播关闭动画的 Agent.key
 * @param {(e:MouseEvent, spaceKey:string) => void} props.onSpaceMenu
 * @param {(e:MouseEvent, agentKey:string) => void} props.onAgentMenu
 * @param {(key:string) => void} props.onOpenAgent
 * @param {string} props.deviceLabel                   §7.2 规则算好的底部文案
 * @param {boolean} props.anyDeviceOnline
 * @param {() => void} props.onToggleDevices
 * @param {boolean} props.multiDevice                  勾选设备 > 1（决定是否显示徽章）
 * @param {number} [props.allCount]                    All Spaces 计数，缺省由 spaces 求和
 * @param {number} [props.favCount]                    收藏计数，缺省由可见 agents 求和
 */
export default function Sidebar({
  collapsed,
  spacesOpen,
  onToggleSpaces,
  agentsOpen,
  onToggleAgents,
  selected,
  onSelect,
  spaces,
  agents,
  openKeys,
  closing,
  onSpaceMenu,
  onAgentMenu,
  onOpenAgent,
  deviceLabel,
  anyDeviceOnline,
  onToggleDevices,
  multiDevice,
  allCount,
  favCount,
}) {
  const spaceName = spaces.find((s) => s.key === selected)?.name;
  const agentsTitle =
    selected === 'fav' ? '收藏的 Agents' : spaceName ? `${spaceName} 的 Agents` : 'Agents';

  return (
    <aside className="sidebar" style={{ width: collapsed ? 0 : 280 }}>
      <div className="sidebar-inner">
        <div className="sidebar-search">
          <SearchIcon size={15} stroke="var(--icon-titlebar)" />
          <span className="sidebar-search-label">Search</span>
        </div>

        <div className="sidebar-group-head sidebar-group-head-spaces">
          <GroupHeader open={spacesOpen} onToggle={onToggleSpaces}>
            Spaces
          </GroupHeader>
        </div>
        {spacesOpen ? (
          <SpacesList
            spaces={spaces}
            allCount={allCount ?? spaces.reduce((n, s) => n + (s.count ?? 0), 0)}
            favCount={favCount ?? agents.filter((a) => a.fav).length}
            selected={selected}
            onSelect={onSelect}
            onContextMenu={onSpaceMenu}
            multiDevice={multiDevice}
          />
        ) : null}

        <div className="sidebar-group-head sidebar-group-head-agents">
          <GroupHeader open={agentsOpen} onToggle={onToggleAgents}>
            {agentsTitle}
          </GroupHeader>
        </div>
        {agentsOpen ? (
          <AgentsList
            agents={agents}
            openKeys={openKeys}
            closing={closing}
            onOpen={onOpenAgent}
            onContextMenu={onAgentMenu}
            multiDevice={multiDevice}
          />
        ) : (
          <div className="agents-host" />
        )}

        <div className="sidebar-devices" onClick={onToggleDevices}>
          <LayersIcon size={15} stroke="var(--icon-strong)" />
          <span className="sidebar-devices-label">{deviceLabel}</span>
          <span className={`sidebar-devices-dot${anyDeviceOnline ? ' is-online' : ''}`} />
          <span className="sidebar-devices-gear">
            <GearIcon size={15} stroke="var(--icon)" />
          </span>
        </div>
      </div>
    </aside>
  );
}
