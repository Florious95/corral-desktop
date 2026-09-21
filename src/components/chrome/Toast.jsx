import { useEffect, useRef, useState } from 'react';
import './chrome.css';

/**
 * 单条 Toast（UI-SPEC §4.6）。message 非空即显示，2500ms 后回调 onDone；不排队，新消息覆盖旧的。
 * @param {Object} props
 * @param {string|null} props.message
 * @param {() => void}  props.onDone
 * @param {number}      [props.duration=2500]
 */
export default function Toast({ message, onDone, duration = 2500 }) {
  // onDone 多半是行内箭头函数，进依赖会每次渲染都重置定时器，走 ref。
  const doneRef = useRef(onDone);
  doneRef.current = onDone;
  const [visible, setVisible] = useState(false);
  const activeMessageRef = useRef(null);

  useEffect(() => {
    if (!message) {
      setVisible(false);
      activeMessageRef.current = null;
      return;
    }

    // 防止相同消息因外部频繁 re-render 而被不断 clearTimeout 重新计时（Issue #191）
    if (activeMessageRef.current === message && visible) {
      return;
    }

    activeMessageRef.current = message;
    setVisible(true);

    const t = setTimeout(() => {
      setVisible(false);
      activeMessageRef.current = null;
      doneRef.current?.();
    }, duration || 2500);

    return () => clearTimeout(t);
  }, [message, duration, visible]);

  if (!visible || !message) return null;

  return (
    <div className="toast-pos">
      <div className="toast" role="status">
        {message}
      </div>
    </div>
  );
}
