import { SidebarIcon } from '../../lib/icons.jsx';
import './chrome.css';

/**
 * 窗口标题栏（UI-SPEC §4.1）。整条可拖动，可点击子元素不带 data-tauri-drag-region。
 * @param {Object}     props
 * @param {boolean}    props.sidebarCollapsed
 * @param {() => void} props.onToggleSidebar
 * @param {number}     [props.paneCount]   当前分裂列数，>1 时显示徽章
 */
export default function TitleBar({ sidebarCollapsed, onToggleSidebar, paneCount = 0 }) {
  return (
    <div className="tb" data-tauri-drag-region>
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
      <span className="tb-brand">AgentMirror</span>
      {paneCount > 1 && <span className="tb-badge">分裂展示 · {paneCount} 列</span>}
      <div className="tb-drag" data-tauri-drag-region />
    </div>
  );
}
