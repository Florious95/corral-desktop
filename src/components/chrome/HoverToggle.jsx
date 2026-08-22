import { useEffect, useState } from 'react';
import { SidebarIcon } from '../../lib/icons.jsx';
import './chrome.css';

/**
 * 折叠态折叠钮。DOM 从交通灯集群右侧开始（left:86px），不吃灯的点击。
 * 鼠标在左上角热区（含灯）时才显示按钮，这样灯和钮能同时看见。
 */
export default function HoverToggle({ onToggle, pressed, fullscreen = false }) {
  const [hot, setHot] = useState(false);
  useEffect(() => {
    const yMax = fullscreen ? 80 : 48;
    const onMove = (e) => {
      setHot(e.clientX <= 140 && e.clientY <= yMax);
    };
    const onLeave = () => setHot(false);
    window.addEventListener('mousemove', onMove);
    document.addEventListener('mouseleave', onLeave);
    return () => {
      window.removeEventListener('mousemove', onMove);
      document.removeEventListener('mouseleave', onLeave);
    };
  }, [fullscreen]);
  return (
    <div className={`hover-chrome${hot ? ' is-hot' : ''}`}>
      <button
        type="button"
        className="chr-btn-reset tb-toggle hover-chrome-btn"
        title="折叠/展开侧栏"
        aria-label="折叠/展开侧栏"
        aria-pressed={pressed}
        onClick={onToggle}
      >
        <SidebarIcon size={16} strokeWidth={1.8} />
      </button>
    </div>
  );
}
