import { XIcon } from '../../lib/icons.jsx';
import './terminal.css';

/**
 * 分裂列容器：flex 均分，每列一个 (deviceId, ref)。列宽不可拖拽（UI-SPEC §10）。
 *
 * @param {Object} props
 * @param {Array}  props.panes                            按左→右顺序的 Agent[]
 * @param {(key:string) => void} props.onClosePane
 * @param {(e:MouseEvent, key:string) => void} props.onPaneMenu
 * @param {(agent:Object) => JSX.Element} props.renderPane 由 App 注入，通常返回 <TerminalPane/>
 * @param {string} [props.focusedKey]
 * @param {(key:string) => void} [props.onFocusPane]
 */
export default function SplitPanes({ panes = [], onClosePane, onPaneMenu, renderPane, focusedKey, onFocusPane }) {
  if (panes.length === 0) {
    return (
      <div className="splitpanes-empty">
        <div>
          <div>从左侧选择一个 Agent</div>
          <span className="splitpanes-empty-sub">右键可分裂展示、收藏或关闭</span>
        </div>
      </div>
    );
  }

  return (
    <div className="splitpanes">
      {panes.map((agent) => (
        <div
          key={agent.key}
          className={`splitpanes-col${focusedKey === agent.key ? ' is-focused' : ''}`}
          onMouseDown={() => onFocusPane && onFocusPane(agent.key)}
          onContextMenu={(e) => onPaneMenu && onPaneMenu(e, agent.key)}
        >
          <button
            type="button"
            className="splitpanes-close"
            title="关闭此列"
            aria-label="关闭此列"
            onClick={(e) => { e.stopPropagation(); onClosePane && onClosePane(agent.key); }}
          >
            <XIcon size={12} strokeWidth={2} />
          </button>
          {renderPane ? renderPane(agent) : null}
        </div>
      ))}
    </div>
  );
}
