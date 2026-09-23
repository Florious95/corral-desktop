/**
 * 全局设置与持久化管理器（UI-SPEC 设置中心）。
 * 针对 Issue #193（终端字体与字号）和 Issue #195（目录跟踪）提供可靠持久化。
 */

export const DEFAULT_FONT_FAMILY =
  'Cascadia Code, Consolas, Fira Code, JetBrains Mono, Menlo, Monaco, monospace';
export const DEFAULT_FONT_SIZE = 13;
export const DEFAULT_DIRECTORY_TRACKING = false;
export const DEFAULT_THEME_MODE = 'system';

// Keep a distinct installed-font fallback for every preset. Generic `monospace`
// alone collapses several choices to the same renderer on hosts without the
// optional coding fonts (Issue #259).
export const TERMINAL_FONT_FAMILIES = Object.freeze([
  'Cascadia Code, Consolas, monospace',
  'JetBrains Mono, "Andale Mono", Menlo, "Lucida Console", monospace',
  'Fira Code, Monaco, "Courier New", monospace',
  'Menlo, "Segoe UI Mono", monospace',
  'Consolas, "Andale Mono", monospace',
  'Courier New, monospace',
]);

export const DEFAULT_SETTINGS = Object.freeze({
  'terminal.fontFamily': DEFAULT_FONT_FAMILY,
  'terminal.fontSize': DEFAULT_FONT_SIZE,
  directoryTracking: false,
  themeMode: DEFAULT_THEME_MODE,
});

/**
 * 将终端字号严格限制在 10px ~ 24px 之间
 */
export function clampFontSize(size) {
  const num = typeof size === 'number' ? size : parseInt(size, 10);
  if (Number.isNaN(num)) return DEFAULT_FONT_SIZE;
  return Math.min(24, Math.max(10, num));
}

/**
 * 加载当前设置
 */
export function loadSettings() {
  if (typeof localStorage === 'undefined') {
    return { ...DEFAULT_SETTINGS };
  }
  const fontFamily = localStorage.getItem('terminal.fontFamily') || DEFAULT_FONT_FAMILY;
  const rawSize = localStorage.getItem('terminal.fontSize');
  const fontSize = rawSize ? clampFontSize(rawSize) : DEFAULT_FONT_SIZE;
  const rawTrack = localStorage.getItem('directoryTracking');
  const directoryTracking = rawTrack !== null ? rawTrack === 'true' : false;
  const rawTheme = localStorage.getItem('themeMode');
  const themeMode = (rawTheme === 'light' || rawTheme === 'dark' || rawTheme === 'system')
    ? rawTheme : DEFAULT_THEME_MODE;

  return {
    'terminal.fontFamily': fontFamily,
    'terminal.fontSize': fontSize,
    directoryTracking,
    themeMode,
  };
}

/**
 * 持久化保存单项设置
 */
export function saveSetting(key, value) {
  if (typeof localStorage === 'undefined') return value;
  if (key === 'terminal.fontSize') {
    const clamped = clampFontSize(value);
    localStorage.setItem('terminal.fontSize', String(clamped));
    return clamped;
  }
  if (key === 'terminal.fontFamily') {
    const val = String(value || DEFAULT_FONT_FAMILY);
    localStorage.setItem('terminal.fontFamily', val);
    return val;
  }
  if (key === 'directoryTracking') {
    const bool = Boolean(value);
    localStorage.setItem('directoryTracking', String(bool));
    return bool;
  }
  if (key === 'themeMode') {
    const mode = (value === 'light' || value === 'dark' || value === 'system') ? value : DEFAULT_THEME_MODE;
    localStorage.setItem('themeMode', mode);
    return mode;
  }
  return value;
}
