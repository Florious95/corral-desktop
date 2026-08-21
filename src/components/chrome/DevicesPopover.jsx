import { CheckIcon, LayersIcon, MonitorIcon, PlusIcon } from '../../lib/icons.jsx';
import './chrome.css';

/** 勾选标记：全选 → 对勾；部分 → 短横；未选 → 空框。 */
function Mark({ state }) {
  if (state === 'all') return <CheckIcon size={15} stroke="var(--text)" strokeWidth={2.2} />;
  return (
    <span className="dp-box">{state === 'some' && <span className="dp-dash" />}</span>
  );
}

/**
 * 左下角设备弹层（UI-SPEC §4.2）。定位基准 = App 根元素（需 position:relative）。
 * @param {Object} props
 * @param {Array<{id:string,name:string,url:string,sub?:string,online:boolean,checked:boolean}>} props.devices
 * @param {(id:string, next:boolean) => void} props.onToggle
 * @param {(next:boolean) => void} props.onToggleAll
 * @param {() => void} props.onAddDevice
 * @param {() => void} props.onClose
 */
export default function DevicesPopover({ devices, onToggle, onToggleAll, onAddDevice, onClose }) {
  const onlineCount = devices.filter((d) => d.online).length;
  const checkedCount = devices.filter((d) => d.checked).length;
  const allOn = devices.length > 0 && checkedCount === devices.length;
  const allMark = allOn ? 'all' : checkedCount > 0 ? 'some' : 'none';

  const close = (e) => {
    e.preventDefault();
    onClose();
  };

  return (
    <>
      <div className="dp-overlay" onClick={close} onContextMenu={close} />
      <div className="dp" role="dialog" aria-label="设备">
        <div className="dp-title">Devices</div>

        <button
          type="button"
          className="chr-btn-reset dp-row"
          aria-checked={allOn}
          role="checkbox"
          onClick={() => onToggleAll(!allOn)}
        >
          <LayersIcon size={16} stroke="var(--icon-strong)" strokeWidth={1.8} />
          <div className="dp-main">
            <div className="dp-name">
              <span>All Devices</span>
            </div>
            <div className="dp-sub">
              {devices.length} devices · {onlineCount} connected
            </div>
          </div>
          <Mark state={allMark} />
        </button>

        {devices.map((d) => (
          <button
            key={d.id}
            type="button"
            className="chr-btn-reset dp-row"
            role="checkbox"
            aria-checked={!!d.checked}
            onClick={() => onToggle(d.id, !d.checked)}
          >
            <MonitorIcon size={16} stroke="var(--icon-strong)" strokeWidth={1.8} />
            <div className="dp-main">
              <div className="dp-name">
                <span>{d.name}</span>
                <span className={'dp-dot ' + (d.online ? 'dp-dot-on' : 'dp-dot-off')} />
              </div>
              <div className="dp-sub">{d.sub || d.url}</div>
            </div>
            <Mark state={d.checked ? 'all' : 'none'} />
          </button>
        ))}

        <button type="button" className="chr-btn-reset dp-add" onClick={onAddDevice}>
          <PlusIcon size={14} strokeWidth={1.8} />
          Add Device…
        </button>
      </div>
    </>
  );
}
