import { useLayoutEffect, useRef, useState } from 'react';
import './chrome.css';

/**
 * 通用右键菜单（UI-SPEC §4.5）。坐标已由 App 的 openMenu() 粗夹取，这里再按真实尺寸兜一次底。
 * @param {Object}  props
 * @param {boolean} props.open
 * @param {number}  props.x
 * @param {number}  props.y
 * @param {Array<{key:string,label:string,icon?:JSX.Element,color?:string,
 *                disabled?:boolean,separator?:boolean,onClick:()=>void}>} props.items
 * @param {() => void} props.onClose
 */
export default function ContextMenu({ open, x, y, items, onClose }) {
  const ref = useRef(null);
  const [pos, setPos] = useState({ x, y });

  // useLayoutEffect 在绘制前跑，量到真实尺寸后修正位置不会闪。
  useLayoutEffect(() => {
    if (!open || !ref.current) return;
    const r = ref.current.getBoundingClientRect();
    setPos({
      x: Math.max(8, Math.min(x, window.innerWidth - r.width - 8)),
      y: Math.max(8, Math.min(y, window.innerHeight - r.height - 8)),
    });
  }, [open, x, y]);

  if (!open) return null;

  const close = (e) => {
    e.preventDefault();
    onClose();
  };

  return (
    <>
      <div className="cm-overlay" onClick={close} onContextMenu={close} />
      <div ref={ref} className="cm" role="menu" style={{ left: pos.x, top: pos.y }}>
        {items.map((it) => (
          <button
            key={it.key}
            type="button"
            role="menuitem"
            className={'chr-btn-reset cm-item' + (it.separator ? ' cm-sep' : '')}
            style={{ color: it.disabled ? 'var(--text-faint)' : it.color || 'var(--text)' }}
            onClick={() => {
              if (!it.disabled) it.onClick();
              onClose();
            }}
          >
            {it.icon}
            {it.label}
          </button>
        ))}
      </div>
    </>
  );
}
