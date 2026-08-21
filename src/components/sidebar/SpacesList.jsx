// Spaces 列表（UI-SPEC §5.2）。虚拟行 All Spaces / 收藏 置顶，其后是真实 workspace 行。
import { FolderIcon, GridIcon, StarIcon, CheckIcon } from '../../lib/icons.jsx';

/** 聚合状态点：idle / unknown 不渲染，保持行干净 */
function SpaceState({ state }) {
  if (state === 'done') {
    return (
      <span className="spaces-row-state">
        <CheckIcon size={12} stroke="var(--green-deep)" strokeWidth={2.2} />
      </span>
    );
  }
  if (state === 'working' || state === 'blocked') {
    return <span className={`spaces-row-state spaces-dot is-${state}`} />;
  }
  return null;
}

function SpaceRow({ icon, name, count, selected, badge, badgeLocal, state, onClick, onContextMenu }) {
  return (
    <div
      className={`spaces-row${selected ? ' is-selected' : ''}`}
      onClick={onClick}
      onContextMenu={onContextMenu}
    >
      {icon}
      <span className="spaces-row-name">{name}</span>
      <SpaceState state={state} />
      {badge ? (
        <span className={`spaces-badge${badgeLocal ? ' is-local' : ''}`}>{badge}</span>
      ) : null}
      <span className="spaces-row-count">{count}</span>
    </div>
  );
}

/**
 * @param {Object} props
 * @param {Array}  props.spaces
 * @param {number} props.allCount
 * @param {number} props.favCount
 * @param {string} props.selected                       'all' | 'fav' | Space.key
 * @param {(key:string) => void} props.onSelect
 * @param {(e:MouseEvent, key:string) => void} props.onContextMenu
 * @param {boolean} props.multiDevice
 */
export default function SpacesList({
  spaces,
  allCount,
  favCount,
  selected,
  onSelect,
  onContextMenu,
  multiDevice,
}) {
  return (
    <div className="spaces-list">
      <SpaceRow
        icon={<GridIcon size={15} stroke="var(--icon-strong)" />}
        name="All Spaces"
        count={allCount}
        selected={selected === 'all'}
        onClick={() => onSelect('all')}
        onContextMenu={(e) => e.preventDefault()}
      />
      <SpaceRow
        icon={<StarIcon size={15} fill="var(--amber)" />}
        name="收藏"
        count={favCount}
        selected={selected === 'fav'}
        onClick={() => onSelect('fav')}
        onContextMenu={(e) => e.preventDefault()}
      />
      {spaces.map((sp) => (
        <SpaceRow
          key={sp.key}
          icon={<FolderIcon size={15} stroke="var(--icon)" />}
          name={sp.name}
          count={sp.count}
          state={sp.state}
          selected={selected === sp.key}
          badge={multiDevice ? sp.deviceName : null}
          badgeLocal={sp.deviceLocal}
          onClick={() => onSelect(sp.key)}
          onContextMenu={(e) => onContextMenu(e, sp.key)}
        />
      ))}
    </div>
  );
}
