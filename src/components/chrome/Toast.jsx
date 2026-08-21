import { useEffect, useRef } from 'react';
import './chrome.css';

/**
 * 单条 Toast（UI-SPEC §4.6）。message 非空即显示，2600ms 后回调 onDone；不排队，新消息覆盖旧的。
 * @param {Object} props
 * @param {string|null} props.message
 * @param {() => void}  props.onDone
 */
export default function Toast({ message, onDone }) {
  // onDone 多半是行内箭头函数，进依赖会每次渲染都重置定时器，走 ref。
  const doneRef = useRef(onDone);
  doneRef.current = onDone;

  useEffect(() => {
    if (!message) return;
    const t = setTimeout(() => doneRef.current(), 2600);
    return () => clearTimeout(t);
  }, [message]);

  if (!message) return null;

  return (
    <div className="toast-pos">
      <div className="toast" role="status">
        {message}
      </div>
    </div>
  );
}
