import { useEffect, useRef, useState } from 'react';
import { ArrowUpIcon } from '../../lib/icons.jsx';
import './terminal.css';

/** 快捷键闭集（UI-SPEC §6.3）。⛔ keys 不附加回车，且与 text 互斥：一帧只带其一。 */
const KEYS = [
  ['Esc', 'esc'], ['Ctrl-C', 'ctrl_c'], ['Tab', 'tab'],
  ['↑', 'up'], ['↓', 'down'], ['←', 'left'], ['→', 'right'],
];

/** pending 兜底解锁（ms，UI-SPEC §6.3）。协议层本地超时是 10s，这里只保证 UI 不会卡死。 */
const ACK_WATCHDOG_MS = 5000;

/**
 * 底部输入条：整行文本发送（协议 input.text）+ 快捷键（协议 input.keys）。
 * 等待 input_ack 期间禁止重复发送；失败/超时给行内提示。
 *
 * @param {Object} props
 * @param {(text:string) => Promise<void>} props.onSend  由 App 实现「打字帧 + 裸 Enter 帧」两帧提交
 *                                                       （CLIENT-CONTRACT §3.5）；失败请 reject
 * @param {(key:string) => Promise<void>} props.onKey    闭集：esc|ctrl_c|tab|up|down|left|right
 * @param {boolean} props.disabled                       无选中 Agent 或连接断开
 */
export default function InputBar({ onSend, onKey, disabled = false }) {
  const [text, setText] = useState('');
  const [pending, setPending] = useState(false);
  const [err, setErr] = useState('');
  const taRef = useRef(null);
  const watchdogRef = useRef(null);
  const errTimerRef = useRef(null);

  useEffect(() => () => { clearTimeout(watchdogRef.current); clearTimeout(errTimerRef.current); }, []);

  const fail = (msg) => {
    setErr(msg);
    clearTimeout(errTimerRef.current);
    errTimerRef.current = setTimeout(() => setErr(''), 4000);
  };

  const run = async (fn) => {
    if (disabled || pending) return;
    setPending(true);
    clearTimeout(watchdogRef.current);
    watchdogRef.current = setTimeout(() => { setPending(false); fail('未收到回执'); }, ACK_WATCHDOG_MS);
    try {
      await fn();
      setErr('');
      clearTimeout(errTimerRef.current);
    } catch (e) {
      fail(`发送失败：${(e && e.message) || e || '未知原因'}`);
    } finally {
      clearTimeout(watchdogRef.current);
      setPending(false);
    }
  };

  const send = () => {
    if (!onSend) return;
    const value = text;          // 空文本 = 协议「仅回车」，允许
    setText('');
    if (taRef.current) taRef.current.style.height = 'auto';
    run(() => onSend(value));
  };

  const grow = (el) => {
    el.style.height = 'auto';
    el.style.height = `${Math.min(122, Math.max(32, el.scrollHeight))}px`;
  };

  const blocked = disabled || pending;

  return (
    <div className="inputbar">
      <div className="inputbar-keys">
        {KEYS.map(([label, key]) => (
          <button
            key={key}
            type="button"
            className="inputbar-chip"
            disabled={blocked}
            onClick={() => onKey && run(() => onKey(key))}
          >
            {label}
          </button>
        ))}
        {err && <span className="inputbar-err">{err}</span>}
      </div>

      <div className="inputbar-row">
        <textarea
          ref={taRef}
          className="inputbar-input"
          rows={1}
          value={text}
          disabled={disabled}
          spellCheck={false}
          placeholder="输入并回车发送 · Shift+Enter 换行"
          onChange={(e) => { setText(e.target.value); grow(e.target); }}
          onKeyDown={(e) => {
            if (e.key !== 'Enter' || e.shiftKey) return;
            if (e.nativeEvent.isComposing) return;   // 中文输入法选词的回车不算发送
            e.preventDefault();
            send();
          }}
        />
        <button
          type="button"
          className="inputbar-send"
          title="发送（留空 = 仅回车）"
          aria-label="发送"
          disabled={blocked}
          onClick={send}
        >
          <ArrowUpIcon size={14} strokeWidth={2} />
        </button>
      </div>
    </div>
  );
}
