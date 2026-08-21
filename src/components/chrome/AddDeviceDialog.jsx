import { useEffect, useState } from 'react';
import './chrome.css';

const WS_RE = /^wss?:\/\//;

/** 解析配对二维码里的单行 JSON（protocol.md §2.1）。不是配对载荷则返回 null。 */
function parsePairing(text) {
  let o;
  try {
    o = JSON.parse(text);
  } catch {
    return null;
  }
  if (!o || typeof o.url !== 'string' || !WS_RE.test(o.url)) return null;
  const candidates = Array.isArray(o.candidates)
    ? o.candidates.filter((c) => typeof c === 'string' && WS_RE.test(c))
    : [];
  if (!candidates.includes(o.url)) candidates.unshift(o.url);
  return { url: o.url, token: typeof o.token === 'string' ? o.token : '', candidates };
}

const hostOf = (url) => url.replace(WS_RE, '').split('/')[0];

/**
 * 添加设备对话框（UI-SPEC §4.3）。token 恒为密文态，不回显、不进日志。
 * @param {Object}  props
 * @param {boolean} props.open
 * @param {(d:{name:string,url:string,token:string}) => void} props.onSubmit
 * @param {(d:{name:string,url:string,token:string}) => void} [props.onAdd]  onSubmit 的别名（UI-SPEC 与任务书命名不一致，两者都接）
 * @param {() => void} props.onCancel
 */
export default function AddDeviceDialog({ open, onSubmit, onAdd, onCancel }) {
  const [name, setName] = useState('');
  const [url, setUrl] = useState('');
  const [token, setToken] = useState('');
  const [candidates, setCandidates] = useState([]);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!open) return;
    setName('');
    setUrl('');
    setToken('');
    setCandidates([]);
    setError('');
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

  const submit = (e) => {
    e.preventDefault();
    const u = url.trim();
    if (!WS_RE.test(u)) {
      setError('地址必须以 ws:// 或 wss:// 开头');
      return;
    }
    (onSubmit || onAdd)({ name: name.trim() || hostOf(u), url: u, token });
  };

  // 任意输入框里粘贴配对 JSON → 一键填充地址、Token 与候选地址。
  const onPaste = (e) => {
    const hit = parsePairing(e.clipboardData.getData('text'));
    if (!hit) return;
    e.preventDefault();
    setUrl(hit.url);
    setToken(hit.token);
    setCandidates(hit.candidates);
    setError('');
  };

  return (
    <>
      <div className="chr-scrim" onClick={onCancel} />
      <div className="chr-dialog-pos">
        <form
          className="chr-dialog"
          role="dialog"
          aria-modal="true"
          aria-label="添加设备"
          onSubmit={submit}
          onPaste={onPaste}
        >
          <div className="chr-dialog-title">添加设备</div>
          <div className="chr-dialog-sub">填写 agentmirrord 打印的地址与配对 Token</div>
          <div className="add-hint">粘贴配对二维码里的 JSON 可自动填充</div>

          <label className="chr-label" htmlFor="add-name">
            显示名称（可选）
          </label>
          <input
            id="add-name"
            className="chr-input"
            value={name}
            placeholder="Mac Studio @ Home"
            onChange={(e) => setName(e.target.value)}
          />

          <label className="chr-label" htmlFor="add-url">
            WebSocket 地址
          </label>
          <input
            id="add-url"
            className="chr-input"
            autoFocus
            spellCheck={false}
            autoComplete="off"
            value={url}
            placeholder="ws://192.168.31.116:9900/ws"
            onChange={(e) => setUrl(e.target.value)}
          />

          {candidates.length > 1 && (
            <>
              <label className="chr-label" htmlFor="add-cand">
                候选地址（同一主机的其它网卡）
              </label>
              <select
                id="add-cand"
                className="chr-input add-select"
                value={candidates.includes(url) ? url : ''}
                onChange={(e) => setUrl(e.target.value)}
              >
                {!candidates.includes(url) && <option value="">自定义</option>}
                {candidates.map((c) => (
                  <option key={c} value={c}>
                    {c}
                  </option>
                ))}
              </select>
            </>
          )}

          <label className="chr-label" htmlFor="add-token">
            配对 Token
          </label>
          <input
            id="add-token"
            className="chr-input"
            type="password"
            autoComplete="off"
            value={token}
            onChange={(e) => setToken(e.target.value)}
          />

          {error && <div className="chr-error">{error}</div>}

          <div className="chr-actions">
            <button type="button" className="chr-btn-reset chr-btn" onClick={onCancel}>
              取消
            </button>
            <button type="submit" className="chr-btn-reset chr-btn chr-btn-primary">
              添加
            </button>
          </div>
        </form>
      </div>
    </>
  );
}
