import { useEffect, useMemo, useRef, useState } from 'react';
import ProviderIcon from '../sidebar/ProviderIcon.jsx';
import { resolveProviderSelection } from '../../lib/providerSelection.js';
import './chrome.css';

/**
 * 新建 Agent 对话框（UI-SPEC §4.4）。Provider 列表来自当前设备 auth_ack 能力广告，
 * 组件不维护静态厂家列表，也不拼装服务端命令参数。
 * @param {Object} props
 * @param {boolean} props.open
 * @param {string} props.spaceName
 * @param {{provider:string,display_name:string,supports_bypass:boolean,naming:string}[]} [props.launchers]
 * @param {boolean} [props.loading]
 * @param {(v:{name:string,provider:string,bypass:boolean}) => void} props.onCreate
 * @param {() => void} props.onCancel
 */
export default function NewAgentDialog({
  open, spaceName, launchers = [], loading = false, onCreate, onCancel,
}) {
  const [name, setName] = useState('');
  const [provider, setProvider] = useState('');
  const [bypass, setBypass] = useState(false);
  const wasOpen = useRef(false);
  const selected = useMemo(
    () => launchers.find((launcher) => launcher.provider === provider) || null,
    [launchers, provider],
  );

  useEffect(() => {
    if (!open) {
      wasOpen.current = false;
      return;
    }
    const opening = !wasOpen.current;
    wasOpen.current = true;
    if (opening) {
      setName('');
      setBypass(false);
    }
    setProvider((current) => resolveProviderSelection(current, launchers, opening));
  }, [open, launchers]);

  useEffect(() => {
    if (!selected) {
      if (provider) setProvider(launchers[0]?.provider || '');
      if (bypass) setBypass(false);
      return;
    }
    if (!selected.supports_bypass && bypass) setBypass(false);
  }, [selected, launchers, provider, bypass]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e) => {
      if (e.key === 'Escape' && !loading) onCancel();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, loading, onCancel]);

  if (!open) return null;
  const nameChars = Array.from(name);
  const nameHasControl = nameChars.some((ch) => /\p{Cc}/u.test(ch));
  const nameTooLong = nameChars.length > 64;
  const nameError = nameHasControl
    ? '名称不能包含控制字符'
    : nameTooLong ? '名称不能超过 64 个字符' : '';
  const bypassSupported = selected?.supports_bypass === true;
  const canCreate = !loading && !!selected && !!name.trim() && !nameError;

  return (
    <>
      <div className="chr-scrim" onClick={loading ? undefined : onCancel} />
      <div className="chr-dialog-pos">
        <form
          className="chr-dialog"
          role="dialog"
          aria-modal="true"
          aria-label="新建 Agent"
          onSubmit={(e) => {
            e.preventDefault();
            if (canCreate) onCreate({ name: name.trim(), provider, bypass: !!selected.supports_bypass && bypass });
          }}
        >
          <div className="chr-dialog-title">新建 Agent</div>
          <div className="chr-dialog-sub">在「{spaceName}」中创建</div>

          <label className="chr-label" htmlFor="new-agent-name">任务名称</label>
          <input
            id="new-agent-name"
            name="new-agent-name"
            className="chr-input"
            autoFocus
            required
            disabled={loading}
            value={name}
            placeholder="任务名称"
            aria-invalid={nameError ? 'true' : undefined}
            onChange={(e) => setName(e.target.value)}
          />
          {nameError ? <div className="nad-error" role="alert">{nameError}</div> : null}

          <div className="nad-sec">选择 Agent</div>
          {launchers.length > 0 ? (
            <div className="nad-grid">
              {launchers.map((launcher) => (
                <button
                  key={launcher.provider}
                  type="button"
                  className="chr-btn-reset nad-tile"
                  aria-pressed={provider === launcher.provider}
                  disabled={loading}
                  onClick={() => setProvider(launcher.provider)}
                >
                  <ProviderIcon provider={launcher.provider} size={20} active />
                  <span className="nad-tile-name">{launcher.display_name}</span>
                </button>
              ))}
            </div>
          ) : (
            <div className="nad-empty" role="status">当前设备未广告可用的 Agent</div>
          )}

          <div className={`nad-bypass${bypassSupported ? '' : ' is-disabled'}`} aria-disabled={!bypassSupported}>
            <div className="nad-bypass-main">
              <div className="nad-bypass-title">Bypass permissions</div>
              <div className="nad-bypass-desc">允许 Agent 不经确认执行 shell 命令</div>
            </div>
            <button
              type="button"
              className="chr-btn-reset nad-switch"
              role="switch"
              aria-checked={bypassSupported && bypass}
              aria-label="Bypass permissions"
              disabled={loading || !bypassSupported}
              onClick={() => { if (bypassSupported) setBypass((v) => !v); }}
            >
              <span className="nad-knob" />
            </button>
          </div>

          <div className="nad-loading" role="status" aria-hidden={!loading}>{loading ? '正在创建 Agent…' : '\u00a0'}</div>
          <div className="chr-actions">
            <button type="button" className="chr-btn-reset chr-btn" disabled={loading} onClick={onCancel}>
              取消
            </button>
            <button type="submit" className="chr-btn-reset chr-btn chr-btn-primary" disabled={!canCreate}>
              {loading ? '创建中…' : '创建'}
            </button>
          </div>
        </form>
      </div>
    </>
  );
}
