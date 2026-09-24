import React, { useState, useEffect } from 'react';
import { nativeCapabilities } from '../../core/nativeCapabilities.js';

/**
 * Windows 11 Fluent 风格窗口控制三联按钮（最小化、最大化/还原、关闭）
 *
 * @param {Object} props
 * @param {boolean} [props.maximized]          受控最大化状态（如果传入则优先使用）
 * @param {boolean} [props.fullscreen]         兼容历史传入（若无 maximized 则降级参考）
 * @param {() => void} [props.onMinimize]
 * @param {() => void} [props.onToggleMaximize]
 * @param {() => void} [props.onClose]
 */
export default function WindowsWindowControls({
  maximized,
  fullscreen,
  onMinimize,
  onToggleMaximize,
  onClose,
}) {
  const [internalMaximized, setInternalMaximized] = useState(false);

  // 优先使用显式受控 prop（maximized），若未传则使用内部监听的真实 isMaximized 状态
  const isMax = maximized !== undefined
    ? Boolean(maximized)
    : (fullscreen !== undefined && maximized === undefined ? Boolean(fullscreen) : internalMaximized);

  useEffect(() => {
    let unlisten = null;
    let disposed = false;

    const checkMaximized = async () => {
      try {
        const val = await nativeCapabilities.window.isMaximized();
        if (!disposed) setInternalMaximized(Boolean(val));
      } catch {}
    };

    checkMaximized();

    // 监听窗口尺寸变化，随动同步最大化/还原状态
    window.addEventListener('resize', checkMaximized);

    // 若运行在 Tauri 环境，挂载 onResized 监听
    if (typeof window !== 'undefined' && window.__TAURI_INTERNALS__) {
      import('@tauri-apps/api/window')
        .then(({ getCurrentWindow }) => {
          if (disposed) return;
          getCurrentWindow().onResized(checkMaximized).then((u) => {
            if (disposed) u();
            else unlisten = u;
          }).catch(() => {});
        })
        .catch(() => {});
    }

    return () => {
      disposed = true;
      window.removeEventListener('resize', checkMaximized);
      if (unlisten) {
        try { unlisten(); } catch {}
      }
    };
  }, []);

  const handleMinimize = () => {
    if (onMinimize) onMinimize();
    else nativeCapabilities.window.minimize().catch(() => {});
  };

  const handleToggleMaximize = async () => {
    if (onToggleMaximize) {
      try { onToggleMaximize(); } catch {}
      return;
    }
    try {
      const next = await nativeCapabilities.window.toggleMaximize();
      setInternalMaximized(Boolean(next));
    } catch {
      // reject 不抛出未处理异常，保持按钮可再次点击 (Issue #298 W298-04)
    }
  };

  const handleClose = () => {
    if (onClose) onClose();
    else nativeCapabilities.window.close().catch(() => {});
  };

  return (
    <aside className="tb-win-controls" aria-label="窗口控制" data-tauri-drag-region="false">
      <button
        type="button"
        className="tb-win-btn tb-win-min"
        data-tauri-drag-region="false"
        title="最小化"
        aria-label="最小化"
        onClick={handleMinimize}
      >
        <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
          <line x1="0" y1="5" x2="10" y2="5" stroke="currentColor" strokeWidth="1" />
        </svg>
      </button>

      <button
        type="button"
        className="tb-win-btn tb-win-max"
        data-tauri-drag-region="false"
        title={isMax ? '还原' : '最大化'}
        aria-label={isMax ? '还原' : '最大化'}
        onClick={handleToggleMaximize}
      >
        {isMax ? (
          <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
            <path d="M2.5 7.5V2.5H7.5V7.5H2.5Z" fill="none" stroke="currentColor" strokeWidth="1" />
            <path d="M4 2.5V1H9V6H7.5" fill="none" stroke="currentColor" strokeWidth="1" />
          </svg>
        ) : (
          <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
            <rect x="0.5" y="0.5" width="9" height="9" fill="none" stroke="currentColor" strokeWidth="1" />
          </svg>
        )}
      </button>

      <button
        type="button"
        className="tb-win-btn tb-win-close"
        data-tauri-drag-region="false"
        title="关闭"
        aria-label="关闭"
        onClick={handleClose}
      >
        <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
          <line x1="0.5" y1="0.5" x2="9.5" y2="9.5" stroke="currentColor" strokeWidth="1" />
          <line x1="9.5" y1="0.5" x2="0.5" y2="9.5" stroke="currentColor" strokeWidth="1" />
        </svg>
      </button>
    </aside>
  );
}
