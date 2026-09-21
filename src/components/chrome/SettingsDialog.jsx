import { useState, useEffect } from 'react';
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

/**
 * 设置中心抽屉/弹窗（Issue #193, #195）
 * 支持配置终端外观（字体族、字号）与目录跟踪开关。
 */
export default function SettingsDialog({
  open,
  settings,
  onUpdateSettings,
  onClose,
}) {
  const [fontFamily, setFontFamily] = useState(
    settings?.['terminal.fontFamily'] || DEFAULT_FONT_FAMILY
  );
  const [fontSize, setFontSize] = useState(
    settings?.['terminal.fontSize'] || DEFAULT_FONT_SIZE
  );
  const [fontSizeInput, setFontSizeInput] = useState(
    String(settings?.['terminal.fontSize'] || DEFAULT_FONT_SIZE)
  );
  const [directoryTracking, setDirectoryTracking] = useState(
    settings?.directoryTracking !== undefined
      ? settings.directoryTracking
      : DEFAULT_DIRECTORY_TRACKING
  );

  useEffect(() => {
    if (!open) return;
    setFontFamily(settings?.['terminal.fontFamily'] || DEFAULT_FONT_FAMILY);
    const size = settings?.['terminal.fontSize'] || DEFAULT_FONT_SIZE;
    setFontSize(size);
    setFontSizeInput(String(size));
    setDirectoryTracking(
      settings?.directoryTracking !== undefined
        ? settings.directoryTracking
        : DEFAULT_DIRECTORY_TRACKING
    );
  }, [open, settings]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e) => {
      if (e.key === 'Escape') onClose();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [open, onClose]);

  if (!open) return null;

  const handleFontFamilyChange = (val) => {
    setFontFamily(val);
    saveSetting('terminal.fontFamily', val);
    onUpdateSettings?.('terminal.fontFamily', val);
  };

  const commitFontSize = (valToCommit) => {
    const raw = valToCommit !== undefined ? valToCommit : fontSizeInput;
    const num = parseInt(raw, 10);
    const clamped = Math.min(24, Math.max(10, Number.isNaN(num) ? DEFAULT_FONT_SIZE : num));
    setFontSize(clamped);
    setFontSizeInput(String(clamped));
    saveSetting('terminal.fontSize', clamped);
    onUpdateSettings?.('terminal.fontSize', clamped);
  };

  const handleFontSizeChange = (val) => {
    setFontSizeInput(val);
    const num = parseInt(val, 10);
    // 若键入的数值已经在 [10, 24] 合法范围内（如直接微调或直接贴入 16），即时联动生效；
    // 未完成的中间输入（如敲入单个数字 1）保留在输入框中，不提前夹逼打断输入
    if (!Number.isNaN(num) && num >= 10 && num <= 24) {
      setFontSize(num);
      saveSetting('terminal.fontSize', num);
      onUpdateSettings?.('terminal.fontSize', num);
    }
  };

  const handleTrackingChange = (checked) => {
    setDirectoryTracking(checked);
    saveSetting('directoryTracking', checked);
    onUpdateSettings?.('directoryTracking', checked);
  };

  return (
    <>
      <div className="chr-scrim" onClick={onClose} />
      <div className="chr-dialog-pos">
        <div className="chr-dialog settings-dialog" role="dialog" aria-modal="true" aria-label="设置">
          <div className="chr-dialog-title">设置</div>
          <div className="chr-dialog-sub">配置终端外观与工作区行为</div>

          <section className="settings-section">
            <h4 className="settings-section-title">终端外观 (Terminal Typography)</h4>

            <label className="chr-label" htmlFor="setting-font-family">
              字体族 (Font Family)
            </label>
            <input
              id="setting-font-family"
              name="terminal.fontFamily"
              className="chr-input chr-setting-font-family"
              aria-label="Terminal Font Family"
              value={fontFamily}
              onChange={(e) => handleFontFamilyChange(e.target.value)}
              placeholder="如 Cascadia Code, JetBrains Mono, monospace"
            />
            <div className="settings-font-presets">
              {COMMON_FONTS.map((font) => (
                <button
                  key={font}
                  type="button"
                  className="chr-btn-reset settings-preset-btn"
                  onClick={() => handleFontFamilyChange(font)}
                >
                  {font.split(',')[0]}
                </button>
              ))}
            </div>

            <label className="chr-label" htmlFor="setting-font-size" style={{ marginTop: 14 }}>
              字号 (Font Size, 10px ~ 24px)
            </label>
            <div className="settings-font-size-row">
              <input
                id="setting-font-size"
                name="terminal.fontSize"
                type="text"
                inputMode="numeric"
                pattern="[0-9]*"
                className="chr-input chr-setting-font-size"
                aria-label="Terminal Font Size"
                value={fontSizeInput}
                onChange={(e) => {
                  const cleaned = e.target.value.replace(/[^0-9]/g, '');
                  handleFontSizeChange(cleaned);
                }}
                onBlur={() => commitFontSize()}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') {
                    e.preventDefault();
                    commitFontSize();
                  } else if (e.key === 'ArrowUp') {
                    e.preventDefault();
                    const num = parseInt(fontSizeInput || fontSize, 10);
                    const next = Math.min(24, (Number.isNaN(num) ? DEFAULT_FONT_SIZE : num) + 1);
                    commitFontSize(next);
                  } else if (e.key === 'ArrowDown') {
                    e.preventDefault();
                    const num = parseInt(fontSizeInput || fontSize, 10);
                    const next = Math.max(10, (Number.isNaN(num) ? DEFAULT_FONT_SIZE : num) - 1);
                    commitFontSize(next);
                  }
                }}
              />
              <span className="settings-unit">px</span>
            </div>
          </section>

          <section className="settings-section" style={{ marginTop: 18 }}>
            <h4 className="settings-section-title">侧边栏联动</h4>
            <div className="settings-toggle-row">
              <label className="settings-checkbox-label">
                <input
                  type="checkbox"
                  id="setting-dir-tracking"
                  name="directoryTracking"
                  className="chr-setting-dir-tracking"
                  aria-label="目录跟踪 (Directory Tracking)"
                  checked={directoryTracking}
                  onChange={(e) => handleTrackingChange(e.target.checked)}
                />
                <span className="settings-toggle-title">目录跟踪</span>
              </label>
              <div className="settings-toggle-desc">
                当前选中的 CLI，左侧菜单自动跳转并展开对应目录
              </div>
            </div>
          </section>

          <div className="chr-dialog-actions" style={{ marginTop: 22 }}>
            <button type="button" className="chr-btn chr-btn-primary" onClick={onClose}>
              完成
            </button>
          </div>
        </div>
      </div>
    </>
  );
}
