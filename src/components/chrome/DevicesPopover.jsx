import { useState, useRef, useEffect } from 'react';
import { CheckIcon, LayersIcon, MonitorIcon, PlusIcon, QrIcon, EditIcon, TrashIcon } from '../../lib/icons.jsx';
import './chrome.css';

/** 勾选标记：全选 → 对勾；部分 → 短横；未选 → 空框。 */
function Mark({ state }) {
  if (state === 'all') return <CheckIcon size={15} stroke="var(--text)" strokeWidth={2.2} />;
  return (
    <span className="dp-box">{state === 'some' && <span className="dp-dash" />}</span>
  );
}

/** 单个设备节点行（支持修改名称与删除节点，Issue #313） */
function DeviceItem({
  device: d,
  onToggle,
  onRename,
  onRemove,
}) {
  const [editing, setEditing] = useState(false);
  const [draftName, setDraftName] = useState(d.name || '');
  const [confirmDelete, setConfirmDelete] = useState(false);
  const inputRef = useRef(null);

  useEffect(() => {
    if (editing) {
      setDraftName(d.name || '');
      inputRef.current?.focus();
      inputRef.current?.select();
    }
  }, [editing, d.name]);

  const handleStartRename = (e) => {
    e.stopPropagation();
    setConfirmDelete(false);
    setEditing(true);
  };

  const handleSaveRename = (e) => {
    e && e.stopPropagation();
    const trimmed = draftName.trim();
    if (trimmed && trimmed !== d.name && onRename) {
      onRename(d.id, trimmed);
    }
    setEditing(false);
  };

  const handleCancelRename = (e) => {
    e && e.stopPropagation();
    setDraftName(d.name || '');
    setEditing(false);
  };

  const handleKeyDown = (e) => {
    if (e.key === 'Enter') {
      e.preventDefault();
      handleSaveRename(e);
    } else if (e.key === 'Escape') {
      e.preventDefault();
      handleCancelRename(e);
    }
  };

  const handleDeleteClick = (e) => {
    e.stopPropagation();
    setEditing(false);
    setConfirmDelete(true);
  };

  const handleConfirmDelete = (e) => {
    e.stopPropagation();
    setConfirmDelete(false);
    if (onRemove) onRemove(d.id);
  };

  const handleCancelDelete = (e) => {
    e.stopPropagation();
    setConfirmDelete(false);
  };

  return (
    <div
      className="dp-row"
      role="checkbox"
      aria-checked={!!d.checked}
      onClick={() => onToggle(d.id, !d.checked)}
    >
      <MonitorIcon size={16} stroke="var(--icon-strong)" strokeWidth={1.8} />
      <div className="dp-main">
        <div className="dp-name">
          {editing ? (
            <input
              ref={inputRef}
              type="text"
              className="dp-rename-input"
              value={draftName}
              autoComplete="off"
              autoCorrect="off"
              autoCapitalize="off"
              spellCheck="false"
              onClick={(e) => e.stopPropagation()}
              onChange={(e) => setDraftName(e.target.value)}
              onKeyDown={handleKeyDown}
              onBlur={handleSaveRename}
            />
          ) : (
            <>
              <span className="dp-name-text" title={d.name}>{d.name}</span>
              <span className={'dp-dot ' + (d.online ? 'dp-dot-on' : 'dp-dot-off')} />
            </>
          )}
        </div>
        <div className="dp-sub">{d.sub || d.url}</div>
        {d.lastError ? <div className="dp-err">{d.lastError}</div> : null}
      </div>

      <div className="dp-actions" onClick={(e) => e.stopPropagation()}>
        {confirmDelete ? (
          <div className="dp-delete-confirm">
            <button
              type="button"
              className="chr-btn-reset dp-confirm-btn dp-confirm-yes"
              title="确认删除该设备"
              onClick={handleConfirmDelete}
            >
              删除
            </button>
            <button
              type="button"
              className="chr-btn-reset dp-confirm-btn dp-confirm-no"
              title="取消"
              onClick={handleCancelDelete}
            >
              取消
            </button>
          </div>
        ) : (
          <>
            <button
              type="button"
              className="chr-btn-reset dp-action-btn"
              title="修改设备名称"
              aria-label={`修改设备 ${d.name} 名称`}
              onClick={handleStartRename}
            >
              <EditIcon size={13} strokeWidth={1.9} />
            </button>
            <button
              type="button"
              className="chr-btn-reset dp-action-btn is-delete"
              title="删除设备"
              aria-label={`删除设备 ${d.name}`}
              onClick={handleDeleteClick}
            >
              <TrashIcon size={13} strokeWidth={1.9} />
            </button>
          </>
        )}
      </div>

      <Mark state={d.checked ? 'all' : 'none'} />
    </div>
  );
}

/**
 * 左下角设备弹层（UI-SPEC §4.2）。定位基准 = App 根元素（需 position:relative）。
 * @param {Object} props
 * @param {Array<{id:string,name:string,url:string,sub?:string,online:boolean,checked:boolean,lastError?:string|null}>} props.devices
 * @param {(id:string, next:boolean) => void} props.onToggle
 * @param {(next:boolean) => void} props.onToggleAll
 * @param {(id:string, newName:string) => void} [props.onRenameDevice]
 * @param {(id:string) => void} [props.onRemoveDevice]
 * @param {() => void} props.onAddDevice
 * @param {() => void} props.onPairMobile
 * @param {() => void} props.onClose
 */
export default function DevicesPopover({
  devices,
  onToggle,
  onToggleAll,
  onRenameDevice,
  onRemoveDevice,
  onAddDevice,
  onPairMobile,
  onClose,
}) {
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
          <DeviceItem
            key={d.id}
            device={d}
            onToggle={onToggle}
            onRename={onRenameDevice}
            onRemove={onRemoveDevice}
          />
        ))}

        <button type="button" className="chr-btn-reset dp-add dp-pair" onClick={onPairMobile}>
          <QrIcon size={16} stroke="var(--icon-strong)" strokeWidth={1.8} />
          <span>配对移动端…</span>
        </button>

        <button type="button" className="chr-btn-reset dp-add" onClick={onAddDevice}>
          <PlusIcon size={16} stroke="var(--icon-strong)" strokeWidth={1.8} />
          <span>Add Device…</span>
        </button>
      </div>
    </>
  );
}
