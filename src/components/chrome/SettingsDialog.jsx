import { useState, useEffect, useRef } from 'react';
import {
  DEFAULT_FONT_FAMILY,
  DEFAULT_FONT_SIZE,
  DEFAULT_DIRECTORY_TRACKING,
  clampFontSize,
  saveSetting,
} from '../../core/settings.js';
import './chrome.css';

const COMMON_FONTS = [
  'Cascadia Code, Consolas, monospace',
  'JetBrains Mono, Menlo, monospace',
  'Fira Code, Monaco, monospace',
  'Menlo, Monaco, monospace',
  'Consolas, "Courier New", monospace',
  'monospace',
];
const primaryFont = (font) => font.split(',')[0].trim().replace(/["']/g, '').toLowerCase();

/** 设置即时生效；数字输入保留未完成的中间态，失焦 / Enter 才夹逼。 */
export default function SettingsDialog({ open, settings, onUpdateSettings, onClose }) {
  const dialogRef = useRef(null);
  const [fontFamily, setFontFamily] = useState(settings?.['terminal.fontFamily'] || DEFAULT_FONT_FAMILY);
  const [fontSize, setFontSize] = useState(settings?.['terminal.fontSize'] || DEFAULT_FONT_SIZE);
  const [fontSizeInput, setFontSizeInput] = useState(String(fontSize));
  const [directoryTracking, setDirectoryTracking] = useState(settings?.directoryTracking ?? DEFAULT_DIRECTORY_TRACKING);

  useEffect(() => {
    if (!open) return;
    setFontFamily(settings?.['terminal.fontFamily'] || DEFAULT_FONT_FAMILY);
    const size = settings?.['terminal.fontSize'] || DEFAULT_FONT_SIZE;
    setFontSize(size);
    setFontSizeInput(String(size));
    setDirectoryTracking(settings?.directoryTracking ?? DEFAULT_DIRECTORY_TRACKING);
  }, [open, settings]);

  useEffect(() => {
    if (!open) return;
    const previousFocus = document.activeElement;
    dialogRef.current?.focus({ preventScroll: true });
    return () => {
      if (previousFocus?.isConnected) previousFocus.focus({ preventScroll: true });
    };
  }, [open]);

  if (!open) return null;

  const handleFontFamilyChange = (value) => {
    setFontFamily(value);
    saveSetting('terminal.fontFamily', value);
    onUpdateSettings?.('terminal.fontFamily', value);
  };

  const commitFontSize = (value = fontSizeInput) => {
    const size = clampFontSize(value);
    setFontSize(size);
    setFontSizeInput(String(size));
    saveSetting('terminal.fontSize', size);
    onUpdateSettings?.('terminal.fontSize', size);
  };

  const handleFontSizeChange = (value) => {
    setFontSizeInput(value);
    const size = parseInt(value, 10);
    // “1”或空值仍可继续输入，不能提前变成 10 / 默认值。
    if (!Number.isNaN(size) && size >= 10 && size <= 24) {
      setFontSize(size);
      saveSetting('terminal.fontSize', size);
      onUpdateSettings?.('terminal.fontSize', size);
    }
  };

  const handleDialogKeyDown = (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      onClose();
    } else if (event.key === 'Tab') {
      const controls = dialogRef.current.querySelectorAll('button:not(:disabled), input:not(:disabled)');
      const first = controls[0];
      const last = controls[controls.length - 1];
      if (event.shiftKey && (document.activeElement === first || document.activeElement === dialogRef.current)) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }
  };

  return (
    <>
      <div className="chr-scrim" onClick={onClose} />
      <div className="chr-dialog-pos">
        <div
          ref={dialogRef}
          className="chr-dialog settings-dialog"
          role="dialog"
          aria-modal="true"
          aria-labelledby="settings-title"
          aria-describedby="settings-description"
          tabIndex={-1}
          onKeyDown={handleDialogKeyDown}
        >
          <header className="settings-header">
            <div>
              <h2 id="settings-title">设置</h2>
              <p id="settings-description">微调终端外观，让工作区更顺手。</p>
            </div>
            <button type="button" className="chr-btn-reset settings-close" aria-label="关闭设置" onClick={onClose}>
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
                <path d="m4.5 4.5 7 7m0-7-7 7" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
              </svg>
            </button>
          </header>

          <div className="settings-body">
            <section className="settings-section" aria-labelledby="settings-typography-title">
              <h3 className="settings-section-title" id="settings-typography-title">终端外观</h3>
              <div className="settings-card">
                <div className="settings-field-heading">
                  <span id="settings-font-label" className="settings-label">字体</span>
                  <span className="settings-hint">使用本机已安装的字体</span>
                </div>
                <div className="settings-font-presets" role="group" aria-labelledby="settings-font-label">
                  {COMMON_FONTS.map((font) => (
                    <button
                      key={font}
                      type="button"
                      className="chr-btn-reset settings-preset-btn"
                      style={{ fontFamily: font }}
                      aria-pressed={primaryFont(fontFamily || DEFAULT_FONT_FAMILY) === primaryFont(font)}
                      onClick={() => handleFontFamilyChange(font)}
                    >
                      {font.split(',')[0]}
                    </button>
                  ))}
                </div>
                <label className="settings-custom-label" htmlFor="setting-font-family">自定义字体栈</label>
                <input
                  id="setting-font-family"
                  name="terminal.fontFamily"
                  className="chr-input chr-setting-font-family"
                  aria-label="Terminal Font Family"
                  value={fontFamily}
                  onChange={(event) => handleFontFamilyChange(event.target.value)}
                  placeholder="如 Menlo, Monaco, monospace"
                  spellCheck={false}
                />

                <div className="settings-size-field">
                  <div className="settings-field-heading">
                    <label className="settings-label" htmlFor="setting-font-size">字号</label>
                    <span className="settings-hint">10–24 px</span>
                  </div>
                  <div className="settings-font-size-row">
                    <input
                      type="range"
                      min="10"
                      max="24"
                      step="1"
                      className="settings-size-slider"
                      aria-label="终端字号滑块"
                      value={fontSize}
                      style={{ '--settings-range-progress': `${((fontSize - 10) / 14) * 100}%` }}
                      onChange={(event) => commitFontSize(event.target.value)}
                    />
                    <div className="settings-stepper">
                      <button type="button" className="chr-btn-reset settings-step" aria-label="减小字号" disabled={fontSize <= 10} onClick={() => commitFontSize(fontSize - 1)}>−</button>
                      <input
                        id="setting-font-size"
                        name="terminal.fontSize"
                        type="text"
                        inputMode="numeric"
                        pattern="[0-9]*"
                        className="chr-setting-font-size"
                        aria-label="Terminal Font Size"
                        value={fontSizeInput}
                        onChange={(event) => handleFontSizeChange(event.target.value.replace(/[^0-9]/g, ''))}
                        onBlur={() => commitFontSize()}
                        onKeyDown={(event) => {
                          if (event.key === 'Enter') {
                            event.preventDefault();
                            commitFontSize();
                          } else if (event.key === 'ArrowUp' || event.key === 'ArrowDown') {
                            event.preventDefault();
                            const size = parseInt(fontSizeInput || fontSize, 10);
                            commitFontSize((Number.isNaN(size) ? DEFAULT_FONT_SIZE : size) + (event.key === 'ArrowUp' ? 1 : -1));
                          }
                        }}
                      />
                      <span className="settings-unit">px</span>
                      <button type="button" className="chr-btn-reset settings-step" aria-label="增大字号" disabled={fontSize >= 24} onClick={() => commitFontSize(fontSize + 1)}>+</button>
                    </div>
                  </div>
                </div>

                <div className="settings-preview" role="region" aria-label="终端字体预览">
                  <div className="settings-preview-heading"><span>即时预览</span><span>{fontSize} px</span></div>
                  <div className="settings-preview-sample" style={{ fontFamily: fontFamily || DEFAULT_FONT_FAMILY, fontSize }}>
                    <span><span className="settings-preview-prompt" aria-hidden="true">❯ </span>Aa Bb 012345 · 清晰可见</span>
                  </div>
                </div>
              </div>
            </section>

            <section className="settings-section" aria-labelledby="settings-workspace-title">
              <h3 className="settings-section-title" id="settings-workspace-title">工作区行为</h3>
              <div className="settings-card settings-tracking-card">
                <div className="settings-tracking-copy">
                  <label className="settings-label" htmlFor="setting-dir-tracking">目录跟踪</label>
                  <p id="settings-tracking-description" className="settings-hint">切换 Agent 时，自动定位并展开左侧目录。</p>
                </div>
                <button
                  type="button"
                  id="setting-dir-tracking"
                  name="directoryTracking"
                  className="chr-btn-reset settings-switch chr-setting-dir-tracking"
                  role="switch"
                  aria-label="目录跟踪 (Directory Tracking)"
                  aria-describedby="settings-tracking-description"
                  aria-checked={directoryTracking}
                  onClick={() => {
                    const checked = !directoryTracking;
                    setDirectoryTracking(checked);
                    saveSetting('directoryTracking', checked);
                    onUpdateSettings?.('directoryTracking', checked);
                  }}
                >
                  <span className="settings-switch-knob" />
                </button>
              </div>
            </section>
          </div>

          <footer className="settings-footer">
            <span className="settings-save-note">
              <svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true">
                <path d="m3.5 8 3 3 6-6" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
              </svg>
              修改即时保存
            </span>
            <button type="button" className="chr-btn-reset chr-btn chr-btn-primary settings-done" onClick={onClose}>完成</button>
          </footer>
        </div>
      </div>
    </>
  );
}
