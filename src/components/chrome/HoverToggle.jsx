import { useEffect, useState } from 'react';
import { SidebarIcon } from '../../lib/icons.jsx';
import './chrome.css';

/**
 * 折叠态折叠钮。DOM 从交通灯集群右侧开始（left:86px），不吃灯的点击。
 * 鼠标在左上角热区才显示。全屏 y 上限 80，窗口模式 48（第 3 格）。
 */
export default function HoverToggle({ onToggle, pressed, fullscreen = false }) {
  const [hot, setHot] = useState(false);
  useEffect(() => {
    const onMove = (e) => {
      const fs = fullscreen || !!(document.querySelector('.app-root')?.classList.contains('is-fullscreen'));
      const yMax = fs ? 80 : 48;
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
