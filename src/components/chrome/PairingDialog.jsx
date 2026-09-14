import { useEffect, useMemo, useState } from 'react';
import { serializePairingPayload } from '../../core/pairing.js';
import { createQrMatrix } from '../../lib/qr.js';
import { XIcon } from '../../lib/icons.jsx';
import './chrome.css';

function targetLabel(url) {
  try { return new URL(url).host; } catch { return ''; }
}

function PairingQr({ value }) {
  const matrix = useMemo(() => createQrMatrix(value), [value]);
  if (!matrix) return null;
  const quiet = 4;
  const cells = [];
  for (let row = 0; row < matrix.size; row += 1) {
    for (let col = 0; col < matrix.size; col += 1) {
      if (matrix.modules[row][col]) {
        cells.push(<rect key={`${row}:${col}`} x={col + quiet} y={row + quiet} width="1" height="1" />);
      }
    }
  }
  return (
    <svg
      className="pair-qr"
      viewBox={`0 0 ${matrix.size + quiet * 2} ${matrix.size + quiet * 2}`}
      role="img"
      aria-label="移动端配对二维码"
      shapeRendering="crispEdges"
    >
      <rect width="100%" height="100%" fill="var(--field-bg)" />
      <g fill="var(--ink-900)">{cells}</g>
    </svg>
  );
}

/**
 * 移动端配对二维码弹窗。Token 仅作为 QR/copy 的合法出口，不显示明文。
 * @param {Object} props
 * @param {boolean} props.open
 * @param {{v:number,url:string,token:string,ts_authkey:string,candidates:string[]}|null} props.payload
 * @param {() => void} props.onCancel
 * @param {(message:string) => void} [props.onCopied]
 * @param {(token:string) => void} [props.onSaveToken]
 */
export default function PairingDialog({ open, payload, onCancel, onCopied, onSaveToken }) {
  const [token, setToken] = useState('');
  const [copyState, setCopyState] = useState('');
  const configuredToken = typeof payload?.token === 'string' ? payload.token : '';
  const editableToken = configuredToken.length === 0;
  const effectivePayload = useMemo(() => {
    if (!payload) return null;
    const effectiveToken = configuredToken || token.trim();
    if (!effectiveToken) return null;
    try { return { ...payload, token: effectiveToken }; } catch { return null; }
  }, [payload, configuredToken, token]);
  const value = useMemo(() => {
    if (!effectivePayload) return '';
    try { return serializePairingPayload(effectivePayload); } catch { return ''; }
  }, [effectivePayload]);

  useEffect(() => {
    if (!open) return undefined;
    setToken(configuredToken);
    setCopyState('');
    const onKey = (e) => {
      if (e.key === 'Escape') onCancel();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, onCancel, configuredToken]);

  if (!open) return null;

  const copy = async () => {
    if (!value) return;
    if (editableToken) onSaveToken?.(token.trim());
    try {
      if (!globalThis.navigator?.clipboard?.writeText) throw new Error('clipboard unavailable');
      await globalThis.navigator.clipboard.writeText(value);
      setCopyState('已保存并复制');
      onCopied?.('配对信息已复制');
    } catch {
      setCopyState(editableToken ? '已保存，复制失败' : '复制失败');
      onCopied?.(editableToken ? 'Token 已保存，复制失败，请重试' : '复制失败，请重试');
    }
  };

  return (
    <>
      <div className="chr-scrim" onClick={onCancel} />
      <div className="chr-dialog-pos">
        <div
          className="chr-dialog pair-dialog"
          role="dialog"
          aria-modal="true"
          aria-label="配对移动端"
          onClick={(e) => e.stopPropagation()}
        >
          <div className="pair-head">
            <div>
              <div className="chr-dialog-title">配对移动端</div>
              <div className="chr-dialog-sub">用手机扫描二维码，即可连接这台 Mac</div>
            </div>
            <button type="button" className="chr-btn-reset pair-close" aria-label="关闭" onClick={onCancel}>
              <XIcon size={15} strokeWidth={2} />
            </button>
          </div>

          {editableToken && (
            <>
              <label className="chr-label pair-token-label" htmlFor="pair-token">配对 Token</label>
              <input
                id="pair-token"
                className="chr-input pair-token"
                type="password"
                autoComplete="off"
                spellCheck={false}
                value={token}
                placeholder="粘贴 agentmirrord 配对 Token"
                onChange={(e) => { setToken(e.target.value); setCopyState(''); }}
              />
            </>
          )}

          {value ? (
            <>
              <PairingQr value={value} />
              <div className="pair-target">{targetLabel(effectivePayload.url)}</div>
              <div className="pair-help">打开 AgentMirror 移动端，选择扫码连接并对准此二维码</div>
              <div className="pair-actions">
                <button type="button" className="chr-btn-reset chr-btn" onClick={copy}>
                  {copyState || (editableToken ? '保存并复制配对信息' : '复制配对链接 / Token')}
                </button>
                <button type="button" className="chr-btn-reset chr-btn chr-btn-primary" onClick={onCancel}>
                  完成
                </button>
              </div>
            </>
          ) : (
            <>
              <div className="pair-empty">移动端远程连接需要安全 Token</div>
              <div className="pair-help">粘贴安全配对 Token 后，将立即生成二维码。</div>
              <div className="pair-actions">
                <button type="button" className="chr-btn-reset chr-btn chr-btn-primary" onClick={onCancel}>
                  关闭
                </button>
              </div>
            </>
          )}
        </div>
      </div>
    </>
  );
}
