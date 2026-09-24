import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import {
  DARK_TERMINAL_THEME,
  LIGHT_TERMINAL_THEME,
  detectDarkMode,
  resolveTerminalTheme,
} from '../src/term/theme.js';

// WCAG relative luminance calculation
function luminance(hex) {
  const rgb = [int(hex.slice(1, 3)), int(hex.slice(3, 5)), int(hex.slice(5, 7))];
  const linear = rgb.map((c) => {
    const v = c / 255;
    return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
}

function int(s) { return parseInt(s, 16); }

function contrast(fg, bg) {
  const l1 = luminance(fg);
  const l2 = luminance(bg);
  const upper = Math.max(l1, l2);
  const lower = Math.min(l1, l2);
  return (upper + 0.05) / (lower + 0.05);
}

test('Issue #296: Action-primary button pair satisfies WCAG AA (>= 4.5:1) in all states without white-on-light bug', () => {
  // Astra's Dark Theme Action-primary tokens:
  const bg = '#8FAADC';
  const fg = '#111722';
  const bgHover = '#A5BBE5';
  const bgPressed = '#7896CE';

  const normalContrast = contrast(fg, bg);
  const hoverContrast = contrast(fg, bgHover);
  const pressedContrast = contrast(fg, bgPressed);

  assert.ok(normalContrast >= 4.5, `Normal contrast ${normalContrast.toFixed(2)} must be >= 4.5`);
  assert.ok(hoverContrast >= 4.5, `Hover contrast ${hoverContrast.toFixed(2)} must be >= 4.5`);
  assert.ok(pressedContrast >= 4.5, `Pressed contrast ${pressedContrast.toFixed(2)} must be >= 4.5`);

  // Confirm old broken pair (#FFFFFF on #EDEDEC) was 1.17:1
  const brokenContrast = contrast('#FFFFFF', '#EDEDEC');
  assert.ok(brokenContrast < 1.5, `Old broken pair was ${brokenContrast.toFixed(2)}:1`);
});

test('Issue #296: Surface ramps and text contrast hierarchy strictly satisfy Astra aesthetic spec', () => {
  const background = '#0F1115';
  const surface0 = '#171B22';
  const surface1 = '#1E242D';
  const surface2 = '#272F3A';
  const surface3 = '#323D4B';
  const selection = '#28374C';

  const textPrimary = '#E5E7EB';
  const textSecondary = '#B7C0CD';
  const textMuted = '#9DAABB';

  // Text primary against all dark surfaces >= 7:1 (AAA)
  for (const [name, surf] of Object.entries({ background, surface0, surface1, surface2, surface3, selection })) {
    const c = contrast(textPrimary, surf);
    assert.ok(c >= 7.0, `textPrimary on ${name} contrast ${c.toFixed(2)} must be >= 7:1`);
  }

  // Text muted against background and surfaces >= 4.5:1 (AA for normal text)
  for (const [name, surf] of Object.entries({ background, surface0, surface1, surface2, surface3 })) {
    const c = contrast(textMuted, surf);
    assert.ok(c >= 4.5, `textMuted on ${name} contrast ${c.toFixed(2)} must be >= 4.5:1`);
  }

  // Terminal foreground (#D5DCE6) on terminal background (#0F1115) >= 12:1
  const termContrast = contrast('#D5DCE6', background);
  assert.ok(termContrast >= 12.0, `Terminal foreground contrast ${termContrast.toFixed(2)} must be >= 12:1`);
});

test('Issue #296: Switch and range slider controls maintain >= 3:1 boundary contrast', () => {
  const controlThumb = '#D5DCE6';
  const switchOff = '#414D5D';
  const switchOn = '#42638E';
  const controlBorder = '#6D7B90';
  const surface0 = '#171B22';

  assert.ok(contrast(controlThumb, switchOff) >= 3.0, 'Thumb on switch off track >= 3:1');
  assert.ok(contrast(controlThumb, switchOn) >= 3.0, 'Thumb on switch on track >= 3:1');
  assert.ok(contrast(controlBorder, surface0) >= 3.0, 'Control border on surface-0 >= 3:1');
});

test('Issue #296: DARK_TERMINAL_THEME uses cool neutral #D5DCE6 foreground and cursor matching UI secondary text', () => {
  assert.equal(DARK_TERMINAL_THEME.foreground, '#D5DCE6');
  assert.equal(DARK_TERMINAL_THEME.cursor, '#D5DCE6');
  assert.equal(DARK_TERMINAL_THEME.background, '#0f1115');
});

test('Issue #296: detectDarkMode respects explicit light data-theme even when OS prefers dark', () => {
  const origWindow = globalThis.window;
  const origDoc = globalThis.document;

  try {
    const attributes = new Map();
    globalThis.document = {
      documentElement: {
        getAttribute: (k) => attributes.get(k) ?? null,
      },
      body: { classList: { contains: () => false } },
    };
    globalThis.window = {
      matchMedia: () => ({ matches: true }), // OS prefers dark!
    };

    // Case 1: data-theme is 'light' -> MUST return false, not falling through to matchMedia!
    attributes.set('data-theme', 'light');
    assert.equal(detectDarkMode(), false, 'Explicit light must return false even when OS is dark');

    // Case 2: data-theme is 'dark' -> returns true
    attributes.set('data-theme', 'dark');
    assert.equal(detectDarkMode(), true);

    // Case 3: data-theme is unset -> falls back to matchMedia (true)
    attributes.delete('data-theme');
    assert.equal(detectDarkMode(), true);
  } finally {
    globalThis.window = origWindow;
    globalThis.document = origDoc;
  }
});

test('Issue #296 R1: ProviderIcon includes grok in monochrome whitelist and renders is-monochrome', async () => {
  const providerIconJsx = await readFile(new URL('../src/components/sidebar/ProviderIcon.jsx', import.meta.url), 'utf8');

  // Verify grok is included in MONOCHROME_PROVIDERS alongside codex, openai, cursor, pi
  assert.match(providerIconJsx, /const MONOCHROME_PROVIDERS = new Set\(\[['"][^\]]*grok/);
  assert.match(providerIconJsx, /const MONOCHROME_PROVIDERS = new Set\(\[['"][^\]]*codex/);
  assert.match(providerIconJsx, /const MONOCHROME_PROVIDERS = new Set\(\[['"][^\]]*cursor/);
  assert.match(providerIconJsx, /const MONOCHROME_PROVIDERS = new Set\(\[['"][^\]]*pi/);
});

test('Issue #296 R2: Range thumb has distinct dark ink border against filled track with >= 3:1 contrast', async () => {
  const css = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');
  const tokensCss = await readFile(new URL('../src/styles/tokens.css', import.meta.url), 'utf8');

  // Range thumb uses dedicated range-thumb-border token
  assert.match(css, /\.settings-size-slider::-webkit-slider-thumb\s*\{[^}]*border:\s*1px solid var\(--range-thumb-border/);
  assert.match(css, /\.settings-size-slider::-moz-range-thumb\s*\{[^}]*border:\s*1px solid var\(--range-thumb-border/);

  // Dark mode defines --range-thumb-border as #111722
  assert.match(tokensCss, /--range-thumb-border:\s*#111722;/);

  // Contrast between #111722 border and #8FAADC filled track is >= 3:1 (actual ~7.65:1)
  const thumbBorderContrast = contrast('#111722', '#8FAADC');
  assert.ok(thumbBorderContrast >= 3.0, `Thumb border contrast ${thumbBorderContrast.toFixed(2)} must be >= 3:1`);
});

test('Issue #296 R3: Restores light mode tokens without regressions', async () => {
  const tokensCss = await readFile(new URL('../src/styles/tokens.css', import.meta.url), 'utf8');
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');

  // 1. Preview caption is paired: light mode uses #C4C0B7 with high contrast on dark preview background
  assert.match(tokensCss, /--preview-caption:\s*#C4C0B7;/);
  const lightPreviewCaptionContrast = contrast('#C4C0B7', '#3A3835');
  assert.ok(lightPreviewCaptionContrast >= 4.5, `Light preview caption contrast ${lightPreviewCaptionContrast.toFixed(2)} must be >= 4.5:1`);
  assert.match(chromeCss, /\.settings-preview-heading\s*\{[^}]*color:\s*var\(--preview-caption/);

  // 2. Light switch on-state is restored to ink-800 rather than orange brand or blue
  assert.match(tokensCss, /--switch-on-bg:\s*var\(--ink-800\);/);
  assert.match(tokensCss, /--switch-on-border:\s*var\(--ink-800\);/);
  assert.match(chromeCss, /\.settings-switch\[aria-checked='true'\]\s*\{[^}]*border-color:\s*var\(--switch-on-border/);

  // 3. Light pane active border maps to original input-focus
  assert.match(tokensCss, /--pane-active-border:\s*var\(--input-focus\);/);

  // 4. Border subtle is provided for light mode, preventing 0px header border
  assert.match(tokensCss, /--border-subtle:\s*rgba\(0,\s*0,\s*0,\s*\.06\);/);
  assert.match(chromeCss, /\.tb-session-header\s*\{[^}]*border-bottom:\s*1px solid var\(--border-subtle/);
});

test('Issue #296: tokens.css declares paired semantic action tokens in root and dark themes', async () => {
  const css = await readFile(new URL('../src/styles/tokens.css', import.meta.url), 'utf8');

  // Verify semantic tokens defined in :root
  assert.match(css, /--action-primary-bg:\s*#3a3835;/i);
  assert.match(css, /--action-primary-fg:\s*#ffffff;/i);
  assert.match(css, /--preview-bg:\s*#3a3835;/);
  assert.match(css, /--preview-fg:\s*#fbfaf8;/);

  // Verify semantic tokens defined in [data-theme='dark']
  assert.match(css, /--action-primary-bg:\s*#8FAADC;/);
  assert.match(css, /--action-primary-fg:\s*#111722;/);
  assert.match(css, /--preview-bg:\s*#0F1115;/);
  assert.match(css, /--preview-fg:\s*#D5DCE6;/);
  assert.match(css, /--surface-0:\s*#171B22;/);
  assert.match(css, /--surface-1:\s*#1E242D;/);
  assert.match(css, /--surface-2:\s*#272F3A;/);
  assert.match(css, /--surface-3:\s*#323D4B;/);
  assert.match(css, /--switch-off-bg:\s*#414D5D;/);
  assert.match(css, /--switch-on-bg:\s*#42638E;/);
});

test('Issue #296: chrome.css consumes paired action tokens and neutral surface tokens', async () => {
  const css = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');

  // Primary button uses paired action tokens
  assert.match(css, /\.chr-btn-primary\s*\{[^}]*color:\s*var\(--action-primary-fg/);
  assert.match(css, /\.chr-btn-primary\s*\{[^}]*background:\s*var\(--action-primary-bg/);

  // Settings preview uses preview tokens
  assert.match(css, /\.settings-preview\s*\{[^}]*background:\s*var\(--preview-bg/);
  assert.match(css, /\.settings-preview\s*\{[^}]*color:\s*var\(--preview-fg/);

  // Choice button selected uses choice tokens
  assert.match(css, /\.settings-preset-btn\[aria-pressed='true'\]\s*\{[^}]*background:\s*var\(--choice-selected-bg/);
});

test('Issue #296: sidebar.css inverts monochrome provider icons in dark mode without altering brand icons', async () => {
  const css = await readFile(new URL('../src/components/sidebar/sidebar.css', import.meta.url), 'utf8');

  // Monochrome filter rule
  assert.match(css, /\.provider-icon\.is-monochrome\s*\{[^}]*filter:\s*invert\(0?\.88\)/);
});

test('Issue #296: terminal.css keeps split-resizer visual rail centered at 2px', async () => {
  const css = await readFile(new URL('../src/components/terminal/terminal.css', import.meta.url), 'utf8');

  assert.match(css, /\.split-resizer\[data-axis="x"\]::after\s*\{[^}]*left:\s*2px;\s*right:\s*2px;/);
  assert.match(css, /\.split-resizer\[data-axis="y"\]::after\s*\{[^}]*top:\s*2px;\s*bottom:\s*2px;/);
  assert.match(css, /\.split-resizer::after\s*\{[^}]*background-color:\s*var\(--accent/);
});

test('Issue #296: UI-SPEC.md §1.10 documents Dark Theme aesthetic reconstruction according to Astra spec', async () => {
  const spec = await readFile(new URL('../docs/UI-SPEC.md', import.meta.url), 'utf8');

  assert.match(spec, /1\.10 深色模式主题系统与审美规范（2026-09-24 裁定，Issue #255 \/ #296）/);
  assert.match(spec, /--action-primary-bg:\s*#8FAADC/);
  assert.match(spec, /--action-primary-fg:\s*#111722/);
  assert.match(spec, /--pane-active-border:\s*#5C79A3/);
});
