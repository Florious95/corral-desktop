import { SidebarIcon } from '../../lib/icons.jsx';

/**
 * 左侧列 Header（UI-SPEC §4.1，2026-09-16 用户最新裁定）
 *
 * 布局：
 * [原生红绿灯安全留白 80px] [侧栏折叠按钮] [拖窗空白区 flex:1]
 * 位于左侧列（侧边栏）顶部，与右侧会话区以垂直分隔线完全隔离；垂直居中对齐 macOS 原生红绿灯。
 *
 * 拖窗架构：采用唯一原生通路 data-tauri-drag-region="deep"，交互按钮声明 data-tauri-drag-region="false"，
 * 底层由 Tauri 官方 drag.js 与 ACL core:window:allow-start-dragging 原生调度（调用 startDragging）。
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
      data-tauri-drag-region="deep"
    >
      <div className="tb-traffic-lights" aria-hidden="true" />
      <div className="tb-drag" />
      {children}
      <button
        type="button"
        className="tb-btn tb-sidebar-toggle"
        data-tauri-drag-region="false"
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
