import React from 'react';
import { nativeCapabilities } from '../../core/nativeCapabilities.js';

/**
 * Windows 11 Fluent 风格窗口控制三联按钮（最小化、最大化/还原、关闭）
 *
 * @param {Object} props
 * @param {boolean} [props.fullscreen]
 * @param {() => void} [props.onMinimize]
 * @param {() => void} [props.onToggleMaximize]
 * @param {() => void} [props.onClose]
 */
export default function WindowsWindowControls({
  fullscreen = false,
  onMinimize,
  onToggleMaximize,
  onClose,
}) {
  const handleMinimize = () => {
    if (onMinimize) onMinimize();
    else nativeCapabilities.window.minimize().catch(() => {});
  };

  const handleToggleMaximize = () => {
    if (onToggleMaximize) onToggleMaximize();
    else nativeCapabilities.window.toggleFullscreen().catch(() => {});
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
        title={fullscreen ? '还原' : '最大化'}
        aria-label={fullscreen ? '还原' : '最大化'}
        onClick={handleToggleMaximize}
      >
        {fullscreen ? (
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
