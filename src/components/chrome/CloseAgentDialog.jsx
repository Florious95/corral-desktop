import { useEffect } from 'react';
import './chrome.css';

/** Controlled confirmation for terminating an Agent; no native confirm dialog. */
export default function CloseAgentDialog({ open, agent, loading = false, onConfirm, onCancel }) {
  useEffect(() => {
    if (!open) return undefined;
    const onKey = (event) => {
      if (event.key === 'Escape' && !loading) onCancel();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, loading, onCancel]);

  if (!open || !agent) return null;
  const title = agent.title || agent.ref || '未命名 Agent';
  return (
    <>
      <div className="chr-scrim" onClick={loading ? undefined : onCancel} />
      <div className="chr-dialog-pos">
        <div className="chr-dialog cad-dialog" role="dialog" aria-modal="true" aria-label="关闭 Agent">
          <div className="chr-dialog-title">关闭 Agent</div>
          <div className="chr-dialog-sub">确定要关闭「{title}」吗？</div>
          <div className="cad-warning">这会终止当前 Agent 会话，未保存的工作可能会丢失。</div>
          <div className="chr-actions">
            <button type="button" className="chr-btn-reset chr-btn" disabled={loading} onClick={onCancel}>取消</button>
            <button type="button" className="chr-btn-reset chr-btn cad-danger" disabled={loading} onClick={onConfirm}>
              {loading ? '关闭中…' : '关闭 Agent'}
            </button>
          </div>
        </div>
      </div>
    </>
  );
}
