import { SidebarIcon } from '../../lib/icons.jsx';
import './chrome.css';

/**
 * 折叠态：左上角热区。默认不画按钮；hover/focus 才出现。
 * 热区避开交通灯（padding-left 78px），不盖 drag-region 到终端正文。
 */
export default function HoverToggle({ onToggle, pressed }) {
  return (
    <div className="hover-chrome">
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
