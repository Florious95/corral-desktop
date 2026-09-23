import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { createServer } from 'vite';
import react from '@vitejs/plugin-react';
import {
  DEFAULT_SETTINGS, DEFAULT_FONT_FAMILY, DEFAULT_FONT_SIZE,
  TERMINAL_FONT_FAMILIES, clampFontSize, loadSettings, saveSetting,
} from '../src/core/settings.js';

// Render the actual JSX with the production React/Vite toolchain, not a copied component.
const server = await createServer({
  configFile: false,
  root: fileURLToPath(new URL('..', import.meta.url)),
  plugins: [react()],
  server: { middlewareMode: true, watch: null, hmr: false },
  logLevel: 'silent',
});
after(() => server.close());
const { default: SettingsDialog } = await server.ssrLoadModule('/src/components/chrome/SettingsDialog.jsx');
const render = (settings = {}, props = {}) => renderToStaticMarkup(createElement(SettingsDialog, {
  open: true, settings: { ...DEFAULT_SETTINGS, ...settings }, onClose() {}, ...props,
}));
const input = (html, name) => html.match(new RegExp(`<input[^>]*name="${name.replace('.', '\\.')}"[^>]*>`))?.[0];

// Behavioural DOM events, focus restoration and layout are additionally exercised in a real browser.
test('settings: closed dialog renders nothing; open dialog has a named modal and two sections', () => {
  assert.equal(render({}, { open: false }), '');
  const html = render();
  assert.match(html, /role="dialog" aria-modal="true" aria-labelledby="settings-title" aria-describedby="settings-description"/);
  assert.match(html, /id="settings-title">设置/);
  assert.equal((html.match(/<section /g) || []).length, 2);
  assert.match(html, /aria-label="关闭设置"/);
  assert.match(html, /修改即时保存/);
  assert.match(html, />完成<\/button>/);
});

test('settings: six font pills expose a single active primary font, including the default fallback stack', () => {
  for (const family of [DEFAULT_FONT_FAMILY, '"Menlo", monospace', 'JetBrains Mono, monospace']) {
    const html = render({ 'terminal.fontFamily': family });
    assert.equal((html.match(/aria-pressed="(?:true|false)"/g) || []).length, 6);
    assert.equal((html.match(/aria-pressed="true"/g) || []).length, 1);
    const expected = family.split(',')[0].replaceAll('"', '');
    assert.ok(html.includes(`aria-pressed="true">${expected}</button>`));
  }
});

test('settings: paired presets keep distinct physical fallback stacks', () => {
  assert.equal(TERMINAL_FONT_FAMILIES.length, 6);
  assert.equal(new Set(TERMINAL_FONT_FAMILIES).size, 6);
  for (const [left, right] of [[1, 5], [5, 1], [2, 3], [3, 2]]) {
    assert.notEqual(TERMINAL_FONT_FAMILIES[left], TERMINAL_FONT_FAMILIES[right]);
    const leftConcrete = new Set(TERMINAL_FONT_FAMILIES[left].split(',').map((name) => name.trim().toLowerCase()));
    const rightConcrete = new Set(TERMINAL_FONT_FAMILIES[right].split(',').map((name) => name.trim().toLowerCase()));
    leftConcrete.delete('monospace');
    rightConcrete.delete('monospace');
    assert.equal([...leftConcrete].some((name) => rightConcrete.has(name)), false);
  }
});

test('settings: custom font input stays available without falsely selecting a preset', () => {
  const html = render({ 'terminal.fontFamily': 'My Local Font, monospace' });
  assert.match(input(html, 'terminal.fontFamily'), /value="My Local Font, monospace"/);
  assert.doesNotMatch(html, /aria-pressed="true"/);
  assert.match(html, /使用本机已安装的字体/);
});

test('settings: range, precise text input and preview share the persisted size', () => {
  const html = render({ 'terminal.fontFamily': 'Menlo, monospace', 'terminal.fontSize': 18 });
  assert.match(html, /type="range" min="10" max="24" step="1"[^>]*value="18"/);
  assert.match(input(html, 'terminal.fontSize'), /type="text" inputMode="numeric"/);
  assert.match(input(html, 'terminal.fontSize'), /value="18"/);
  assert.match(html, /class="settings-preview-sample" style="font-family:Menlo, monospace;font-size:18px"/);
  assert.match(html, /Aa Bb 012345 · 清晰可见/);
});

test('settings: stepper boundaries disable only the exhausted direction', () => {
  for (const size of [10, 13, 24]) {
    const html = render({ 'terminal.fontSize': size });
    const minus = html.match(/<button[^>]*aria-label="减小字号"[^>]*>/)[0];
    const plus = html.match(/<button[^>]*aria-label="增大字号"[^>]*>/)[0];
    assert.equal(minus.includes('disabled'), size === 10);
    assert.equal(plus.includes('disabled'), size === 24);
  }
});

test('settings: tracking is a labelled button switch with its current persisted state', () => {
  for (const checked of [false, true]) {
    const html = render({ directoryTracking: checked });
    const button = html.match(/<button[^>]*name="directoryTracking"[^>]*>/)[0];
    assert.match(button, /role="switch"/);
    assert.match(button, new RegExp(`aria-checked="${checked}"`));
    assert.match(html, /aria-describedby="settings-tracking-description"/);
    assert.doesNotMatch(html, /type="checkbox"/);
  }
});

test('settings: preview safely renders a user-provided font stack as a style value', () => {
  const html = render({ 'terminal.fontFamily': '"><script>alert(1)</script>, monospace' });
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /&lt;script&gt;/);
});

test('settings: scoped styles use defined tokens, bounded scrolling and reduced motion', async () => {
  const css = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');
  const tokens = await readFile(new URL('../src/styles/tokens.css', import.meta.url), 'utf8');
  const settingsCss = css.slice(css.indexOf('/* ---------- §4.10'));
  for (const [, name] of settingsCss.matchAll(/var\((--[\w-]+)/g)) {
    assert.ok(name === '--settings-range-progress' || tokens.includes(`${name}:`), `undefined token ${name}`);
  }
  assert.match(settingsCss, /max-height: calc\(100dvh - 32px\)/);
  assert.match(settingsCss, /overflow-y: auto/);
  assert.match(settingsCss, /prefers-reduced-motion: reduce/);
  assert.match(settingsCss, /:focus-visible/);
  assert.match(settingsCss, /translateX\(15px\)/);
});

test('settings: font size bounds and fallback remain shared with persistence', () => {
  for (const [raw, expected] of [['', DEFAULT_FONT_SIZE], ['1', 10], ['10', 10], ['18', 18], ['24', 24], ['99', 24], ['invalid', DEFAULT_FONT_SIZE]]) {
    assert.equal(clampFontSize(raw), expected);
  }
});

test('settings: existing storage keys round-trip without adding a new state channel', (t) => {
  const data = new Map();
  const original = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  Object.defineProperty(globalThis, 'localStorage', {
    configurable: true,
    value: {
      getItem: (key) => data.get(key) ?? null,
      setItem: (key, value) => data.set(key, value),
    },
  });
  t.after(() => {
    if (original) Object.defineProperty(globalThis, 'localStorage', original);
    else delete globalThis.localStorage;
  });
  assert.deepEqual(loadSettings(), DEFAULT_SETTINGS);
  saveSetting('terminal.fontFamily', 'Menlo, monospace');
  saveSetting('terminal.fontSize', 99);
  saveSetting('directoryTracking', true);
  assert.deepEqual(loadSettings(), {
    'terminal.fontFamily': 'Menlo, monospace', 'terminal.fontSize': 24, directoryTracking: true,
  });
  saveSetting('directoryTracking', false);
  saveSetting('terminal.fontFamily', '');
  assert.equal(loadSettings().directoryTracking, false);
  assert.equal(loadSettings()['terminal.fontFamily'], DEFAULT_FONT_FAMILY);
  assert.equal(data.size, 3);
});
