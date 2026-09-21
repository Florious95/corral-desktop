// Spaces 列表（UI-SPEC §5.2）。虚拟行 All Spaces / 收藏 置顶，其后是真实 workspace 行。
import { FolderIcon, GridIcon, StarIcon, PlusIcon } from '../../lib/icons.jsx';
import { isSameSpaceKey } from '../../lib/wslPath.js';

function SpaceRow({
  icon,
  name,
  count,
  workingCount = 0,
  selected,
  badge,
  badgeLocal,
  onClick,
  onContextMenu,
  onNewAgent,
}) {
  const isWorking = (workingCount ?? 0) > 0;

  return (
    <div
      className={`spaces-row${selected ? ' is-selected' : ''}`}
      onClick={onClick}
      onContextMenu={onContextMenu}
    >
      {icon}
      <span className="spaces-row-name">{name}</span>
      {onNewAgent ? (
        <button
          type="button"
          className="chr-btn-reset spaces-row-add"
          aria-label={`在 ${name} 中新建 Agent`}
          title="新建 Agent"
          onClick={(e) => { e.stopPropagation(); onNewAgent(); }}
        >
          <PlusIcon size={13} strokeWidth={2} />
        </button>
      ) : null}
      {badge ? (
        <span className={`spaces-badge${badgeLocal ? ' is-local' : ''}`}>{badge}</span>
      ) : null}
      <div className="spaces-row-counts">
        <span
          className={`spaces-count-working${isWorking ? ' is-working is-active' : ' is-idle is-zero'}`}
          title={`工作中: ${workingCount ?? 0}`}
        >
          {workingCount ?? 0}
        </span>
        <span className="spaces-row-count spaces-count-total" title={`总数: ${count}`}>
          {count}
        </span>
      </div>
    </div>
  );
}

/**
 * @param {Object} props
 * @param {Array}  props.spaces
 * @param {number} props.allCount
 * @param {number} [props.allWorkingCount]
 * @param {number} props.favCount
 * @param {number} [props.favWorkingCount]
 * @param {string} props.selected                       'all' | 'fav' | Space.key
 * @param {(key:string) => void} props.onSelect
 * @param {(e:MouseEvent, key:string) => void} props.onContextMenu
 * @param {(spaceKey:string) => void} [props.onNewAgent]
 * @param {boolean} props.multiDevice
 */
export default function SpacesList({
  spaces,
  allCount,
  allWorkingCount = 0,
  favCount,
  favWorkingCount = 0,
  selected,
  onSelect,
  onContextMenu,
  onNewAgent,
  multiDevice,
}) {
  return (
    <div className="spaces-list">
      <SpaceRow
        icon={<GridIcon size={15} stroke="var(--icon-strong)" />}
        name="All Spaces"
        count={allCount}
        workingCount={allWorkingCount}
        selected={selected === 'all'}
        onClick={() => onSelect('all')}
        onContextMenu={(e) => e.preventDefault()}
      />
      <SpaceRow
        icon={<StarIcon size={15} fill="var(--amber)" />}
        name="收藏"
        count={favCount}
        workingCount={favWorkingCount}
        selected={selected === 'fav'}
        onClick={() => onSelect('fav')}
        onContextMenu={(e) => e.preventDefault()}
      />
      {spaces.map((sp) => {
        const workingCount = sp.workingCount ?? (sp.sessions?.filter((s) => s.state === 'working' || s.status === 'working').length || 0);
        return (
          <SpaceRow
            key={sp.key}
            icon={<FolderIcon size={15} stroke="var(--icon)" />}
            name={sp.name}
            count={sp.count}
            workingCount={workingCount}
            selected={isSameSpaceKey(selected, sp.key)}
            badge={multiDevice ? sp.deviceName : null}
            badgeLocal={sp.deviceLocal}
            onClick={() => onSelect(sp.key)}
            onContextMenu={(e) => onContextMenu(e, sp.key)}
            onNewAgent={onNewAgent ? () => onNewAgent(sp.key) : undefined}
          />
        );
      })}
    </div>
  );
}
