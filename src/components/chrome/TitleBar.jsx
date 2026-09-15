import { SidebarIcon } from '../../lib/icons.jsx';
import { triggerWindowDrag } from '../../lib/windowChrome.js';

/**
 * 左侧列 Header（UI-SPEC §4.1，2026-09-16 用户最新裁定）
 *
 * 布局：
 * [原生红绿灯安全留白 80px] [侧栏折叠按钮] [拖窗空白区 flex:1]
 * 位于左侧列（侧边栏）顶部，与右侧会话区以垂直分隔线完全隔离；垂直居中对齐 macOS 原生红绿灯。
 *
 * @param {Object} props
 * @param {boolean} [props.sidebarCollapsed]
 * @param {() => void} [props.onToggleSidebar]
 * @param {boolean} [props.fullscreen]
 * @param {React.ReactNode} [props.children] 为侧栏顶部自定义插槽预留
 */
export default function TitleBar({
  sidebarCollapsed = false,
  onToggleSidebar,
  fullscreen = false,
  children = null,
}) {
  return (
    <header
      className={`tb tb-sidebar-header${fullscreen ? ' is-fullscreen' : ''}`}
      data-tauri-drag-region
      onPointerDown={triggerWindowDrag}
    >
      <div className="tb-traffic-lights" aria-hidden="true" data-tauri-drag-region />
      {/* 顶部长按拖窗统一收敛至 triggerWindowDrag（底层调用 startDragging，严禁在此内联重复派发） */}
      <div
        className="tb-drag"
        data-tauri-drag-region
        onPointerDown={triggerWindowDrag}
      />
      {children}
      <button
        type="button"
        className="tb-btn tb-sidebar-toggle"
        title={sidebarCollapsed ? '展开侧栏' : '折叠侧栏'}
        aria-label={sidebarCollapsed ? '展开侧栏' : '折叠侧栏'}
        aria-pressed={!!sidebarCollapsed}
        onClick={onToggleSidebar}
      >
        <SidebarIcon size={16} strokeWidth={1.8} />
      </button>
    </header>
  );
}
