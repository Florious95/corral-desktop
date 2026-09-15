import { SidebarIcon } from '../../lib/icons.jsx';

/**
 * 全宽一体化常驻 Header（UI-SPEC §4.1，2026-09-15 裁定）
 *
 * 布局：
 * [原生红绿灯安全留白 80px] [侧栏折叠按钮] [子组件/Tabs插槽] [拖窗空白区 flex:1]
 *
 * @param {Object} props
 * @param {boolean} [props.sidebarCollapsed]
 * @param {() => void} [props.onToggleSidebar]
 * @param {boolean} [props.fullscreen]
 * @param {React.ReactNode} [props.children] 为后续 TabBar 预留
 */
export default function TitleBar({
  sidebarCollapsed = false,
  onToggleSidebar,
  fullscreen = false,
  children = null,
}) {
  return (
    <header className={`tb${fullscreen ? ' is-fullscreen' : ''}`}>
      <div className="tb-traffic-lights" aria-hidden="true" />
      <button
        type="button"
        className="tb-btn tb-sidebar-toggle"
        title="折叠/展开侧栏"
        aria-label="折叠/展开侧栏"
        aria-pressed={!!sidebarCollapsed}
        onClick={onToggleSidebar}
      >
        <SidebarIcon size={16} strokeWidth={1.8} />
      </button>
      {children}
      <div className="tb-drag" data-tauri-drag-region />
    </header>
  );
}
