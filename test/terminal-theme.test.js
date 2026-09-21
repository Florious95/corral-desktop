import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DARK_TERMINAL_THEME, LIGHT_TERMINAL_THEME, resolveTerminalTheme } from '../src/term/theme.js';
import { TerminalView } from '../src/term/TerminalView.js';

function hexToRgb(hex) {
  const clean = hex.replace(/^#/, '');
  const num = parseInt(clean, 16);
  return [(num >> 16) & 255, (num >> 8) & 255, num & 255];
}

function relativeLuminance([r, g, b]) {
  const [rs, gs, bs] = [r, g, b].map((c) => {
    const s = c / 255;
    return s <= 0.04045 ? s / 12.92 : Math.pow((s + 0.055) / 1.055, 2.4);
  });
  return 0.2126 * rs + 0.7152 * gs + 0.0722 * bs;
}

function contrastRatio(hex1, hex2) {
  const l1 = relativeLuminance(hexToRgb(hex1));
  const l2 = relativeLuminance(hexToRgb(hex2));
  const lighter = Math.max(l1, l2);
  const darker = Math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

test('Dark terminal theme strictly satisfies WCAG AA (>= 4.5:1) on WSL dark base #0f1115', () => {
  const bg = DARK_TERMINAL_THEME.background;
  assert.equal(bg, '#0f1115', 'Background must match WSL dark terminal base');

  const checkContrast = (name, hex) => {
    const ratio = contrastRatio(hex, bg);
    assert.ok(
      ratio >= 4.5,
      `Color ${name} (${hex}) contrast ratio ${ratio.toFixed(2)}:1 must be >= 4.5:1 against ${bg}`,
    );
  };

  // 检查主要前景色和光标
  checkContrast('foreground', DARK_TERMINAL_THEME.foreground);
  checkContrast('cursor', DARK_TERMINAL_THEME.cursor);

  // 检查 ANSI 16 色中所有可读文本前景色
  const textColors = [
    ['red', DARK_TERMINAL_THEME.red],
    ['green', DARK_TERMINAL_THEME.green],
    ['yellow', DARK_TERMINAL_THEME.yellow],
    ['blue', DARK_TERMINAL_THEME.blue],
    ['magenta', DARK_TERMINAL_THEME.magenta],
    ['cyan', DARK_TERMINAL_THEME.cyan],
    ['white', DARK_TERMINAL_THEME.white],
    ['brightBlack', DARK_TERMINAL_THEME.brightBlack],
    ['brightRed', DARK_TERMINAL_THEME.brightRed],
    ['brightGreen', DARK_TERMINAL_THEME.brightGreen],
    ['brightYellow', DARK_TERMINAL_THEME.brightYellow],
    ['brightBlue', DARK_TERMINAL_THEME.brightBlue],
    ['brightMagenta', DARK_TERMINAL_THEME.brightMagenta],
    ['brightCyan', DARK_TERMINAL_THEME.brightCyan],
    ['brightWhite', DARK_TERMINAL_THEME.brightWhite],
  ];

  for (const [name, hex] of textColors) {
    checkContrast(name, hex);
  }
});

test('resolveTerminalTheme selects correct theme based on options', () => {
  const darkTheme = resolveTerminalTheme({ dark: true });
  assert.equal(darkTheme.background, '#0f1115');
  assert.equal(darkTheme.foreground, '#c0caf5');

  const lightTheme = resolveTerminalTheme({ dark: false });
  assert.equal(lightTheme.background, '#fbfaf8');
  assert.equal(lightTheme.foreground, '#3a3835');

  const customTheme = resolveTerminalTheme({ dark: true, theme: { cursor: '#ff0000' } });
  assert.equal(customTheme.background, '#0f1115');
  assert.equal(customTheme.cursor, '#ff0000');
});

test('TerminalView supports setDark and dynamic theme updates', () => {
  class FakeTerminal {
    constructor(opts) {
      this.options = { theme: opts.theme };
      this.cols = 80;
      this.rows = 24;
    }
    open() {}
    dispose() {}
  }

  const container = { addEventListener() {}, removeEventListener() {} };
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminal,
    dark: false,
  });

  assert.equal(view.term.options.theme.background, '#fbfaf8');

  // 动态切换到暗色主题
  view.setDark(true);
  assert.equal(view.term.options.theme.background, '#0f1115');
  assert.equal(view.term.options.theme.foreground, '#c0caf5');

  // 动态切回亮色主题
  view.setDark(false);
  assert.equal(view.term.options.theme.background, '#fbfaf8');
  assert.equal(view.term.options.theme.foreground, '#3a3835');
});
