import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import {
  PILL_HIDE_MS, FULLSCREEN_CHROME_INSET, pillHotTop, createPillReveal, runWindowChrome,
} from '../src/lib/windowChrome.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test('collapsed chrome: no 131px column; no traffic-light gutter', async () => {
  const css = await readFile(new URL('../src/styles/app.css', import.meta.url), 'utf8');
  const chrome = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');
  assert.match(css, /\.app-left\.is-collapsed\s*\{[^}]*width:\s*0/);
  assert.equal(css.includes('width: 131px'), false);
  assert.equal(css.includes('padding-top: 38px'), false);
  assert.match(chrome, /border-radius:\s*999px/);
  assert.match(chrome, /\.chrome-pill\.is-reveal/);
  assert.match(chrome, /\.chrome-lamp\.r/);
});

test('fullscreen hot zone sits below 62px system chrome inset', () => {
  assert.equal(FULLSCREEN_CHROME_INSET, 62);
  assert.equal(pillHotTop(false), 0);
  assert.equal(pillHotTop(true), 62);
  assert.equal(PILL_HIDE_MS, 160);
});

test('pill reveal: enter shows; leave waits hideMs; re-enter cancels hide', async () => {
  const seen = [];
  const r = createPillReveal({ hideMs: 40, onChange: (v) => seen.push(v) });
  r.enter();
  assert.equal(r.revealed, true);
  r.leave();
  await sleep(15);
  assert.equal(r.revealed, true);
  r.enter();
  await sleep(50);
  assert.equal(r.revealed, true);
  r.leave();
  await sleep(50);
  assert.equal(r.revealed, false);
  assert.deepEqual(seen, [true, false]);
  r.dispose();
});

test('runWindowChrome close/min/zoom against a mock API', async () => {
  const log = [];
  const api = {
    close: async () => { log.push('close'); },
    minimize: async () => { log.push('min'); },
    isFullscreen: async () => false,
    setFullscreen: async (v) => { log.push(['fs', v]); },
  };
  await runWindowChrome('close', api);
  await runWindowChrome('min', api);
  await runWindowChrome('zoom', api);
  assert.deepEqual(log, ['close', 'min', ['fs', true]]);
});

test('Cmd+B is local; Cmd+W and Cmd+Q are not protocol keys (native close/quit)', async () => {
  const { isLocalSidebarToggle, unsupportedKeyEvent } = await import('../src/term/nativeInput.js');
  const cmdB = { type: 'keydown', key: 'b', metaKey: true, ctrlKey: false, altKey: false };
  const cmdW = { type: 'keydown', key: 'w', metaKey: true, ctrlKey: false, altKey: false };
  const cmdQ = { type: 'keydown', key: 'q', metaKey: true, ctrlKey: false, altKey: false };
  assert.equal(isLocalSidebarToggle(cmdB), true);
  assert.equal(isLocalSidebarToggle(cmdW), false);
  assert.equal(unsupportedKeyEvent(cmdB), null);
  assert.equal(unsupportedKeyEvent(cmdW), null);
  assert.equal(unsupportedKeyEvent(cmdQ), null);
});

test('fillsDisplay is a function used for fullscreen detection', async () => {
  const { fillsDisplay } = await import('../src/lib/fullscreen.js');
  assert.equal(typeof fillsDisplay, 'function');
});

test('Rust does not prevent_close or hide on CloseRequested', async () => {
  const rust = await readFile(new URL('../src-tauri/src/main.rs', import.meta.url), 'utf8');
  assert.equal(rust.includes('prevent_close'), false);
  assert.equal(rust.includes('CloseRequested'), false);
  assert.match(rust, /setHidden/);
});
