import { useEffect, useState } from 'react';
import ProviderIcon from '../sidebar/ProviderIcon.jsx';
import './chrome.css';

const PROVIDERS = [
  ['claude-code', 'Claude Code'],
  ['codex', 'Codex'],
  ['grok', 'Grok'],
  ['opencode', 'OpenCode'],
  ['cursor', 'Cursor'],
  ['zai', 'Z Code'],
  ['kimi', 'Kimi Code'],
];

/**
 * 新建 Agent 对话框（UI-SPEC §4.4）。
 * 协议 v1 无远程创建能力：onCreate 由 App 实现为「关闭 + toast」，本组件不发任何帧。
 * @param {Object}  props
 * @param {boolean} props.open
 * @param {string}  props.spaceName
 * @param {(v:{name:string,provider:string,bypass:boolean}) => void} props.onCreate
 * @param {() => void} props.onCancel
 */
export default function NewAgentDialog({ open, spaceName, onCreate, onCancel }) {
  const [name, setName] = useState('');
  const [provider, setProvider] = useState('claude-code');
  const [bypass, setBypass] = useState(false);

  useEffect(() => {
    if (!open) return;
    setName('');
    setProvider('claude-code');
    setBypass(false);
  }, [open]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e) => {
      if (e.key === 'Escape') onCancel();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, onCancel]);

  if (!open) return null;

  return (
    <>
      <div className="chr-scrim" onClick={onCancel} />
      <div className="chr-dialog-pos">
        <form
          className="chr-dialog"
          role="dialog"
          aria-modal="true"
          aria-label="新建 Agent"
          onSubmit={(e) => {
            e.preventDefault();
            onCreate({ name: name.trim(), provider, bypass });
          }}
        >
          <div className="chr-dialog-title">新建 Agent</div>
          <div className="chr-dialog-sub">在「{spaceName}」中创建</div>

          <input
            className="chr-input"
            autoFocus
            value={name}
            placeholder="任务名称（可留空）"
            onChange={(e) => setName(e.target.value)}
          />

          <div className="nad-sec">选择厂家</div>
          <div className="nad-grid">
            {PROVIDERS.map(([key, label]) => (
              <button
                key={key}
                type="button"
                className="chr-btn-reset nad-tile"
                aria-pressed={provider === key}
                onClick={() => setProvider(key)}
              >
                <ProviderIcon provider={key} size={20} active />
                <span className="nad-tile-name">{label}</span>
              </button>
            ))}
          </div>

          <div className="nad-bypass">
            <div className="nad-bypass-main">
              <div className="nad-bypass-title">Bypass permissions</div>
              <div className="nad-bypass-desc">允许 Agent 不经确认执行 shell 命令</div>
            </div>
            <button
              type="button"
              className="chr-btn-reset nad-switch"
              role="switch"
              aria-checked={bypass}
              aria-label="Bypass permissions"
              onClick={() => setBypass((v) => !v)}
            >
              <span className="nad-knob" />
            </button>
          </div>

          <div className="chr-actions">
            <button type="button" className="chr-btn-reset chr-btn" onClick={onCancel}>
              取消
            </button>
            <button type="submit" className="chr-btn-reset chr-btn chr-btn-primary">
              创建
            </button>
          </div>
        </form>
      </div>
    </>
  );
}
