import { SidebarIcon } from '../../lib/icons.jsx';
import './chrome.css';

/**
 * 窗口标题栏（UI-SPEC §4.1）。只占左侧栏宽度；拖拽区不覆盖终端。
 * @param {Object}     props
 * @param {boolean}    props.sidebarCollapsed
 * @param {() => void} props.onToggleSidebar
 */
export default function TitleBar({ sidebarCollapsed, onToggleSidebar }) {
  return (
    <div className="tb" data-tauri-drag-region>
      <div className="tb-drag" data-tauri-drag-region />
      <button
        type="button"
        className="chr-btn-reset tb-toggle"
        title="折叠/展开侧栏"
        aria-label="折叠/展开侧栏"
        aria-pressed={sidebarCollapsed}
        onClick={onToggleSidebar}
      >
        <SidebarIcon size={16} strokeWidth={1.8} />
      </button>
    </div>
  );
}
