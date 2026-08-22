import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('collapsed chrome: no 131px column; hover reveals toggle', async () => {
  const css = await readFile(new URL('../src/styles/app.css', import.meta.url), 'utf8');
  const chrome = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');
  assert.match(css, /\.app-left\.is-collapsed\s*\{[^}]*width:\s*0/);
  assert.equal(css.includes('width: 131px'), false);
  assert.match(css, /\.app-root\.is-collapsed:not\(\.is-fullscreen\) \.app-main/);
  assert.match(css, /padding-top:\s*38px/);
  assert.match(chrome, /\.hover-chrome\.is-hot \.hover-chrome-btn/);
  assert.match(chrome, /left:\s*86px/);
  assert.match(chrome, /opacity:\s*0/);
  assert.equal(/padding:\s*0 8px 0 78px/.test(chrome), false);
  assert.match(css, /\.app-root\.is-fullscreen \.hover-chrome/);
  assert.match(css, /top:\s*32px/);
});

test('Cmd+B is a local sidebar toggle and is not an unsupported protocol key', async () => {
  const { isLocalSidebarToggle, unsupportedKeyEvent } = await import('../src/term/nativeInput.js');
  const cmdB = { type: 'keydown', key: 'b', metaKey: true, ctrlKey: false, altKey: false };
  const cmdV = { type: 'keydown', key: 'v', metaKey: true, ctrlKey: false, altKey: false };
  assert.equal(isLocalSidebarToggle(cmdB), true);
  assert.equal(isLocalSidebarToggle(cmdV), false);
  assert.equal(unsupportedKeyEvent(cmdB), null);
});
