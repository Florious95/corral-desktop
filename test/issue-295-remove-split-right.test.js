import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('Issue #295: App.jsx completely removes split-right from pane context menu', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // Verify 'split-right' and '向右分屏' are completely absent from App.jsx
  assert.doesNotMatch(appJsx, /key:\s*['"]split-right['"]/);
  assert.doesNotMatch(appJsx, /['"]向右分屏['"]/);

  // Verify dead code removal: splitSession and SplitIcon not imported in App.jsx
  assert.doesNotMatch(appJsx, /\bimport\s*\{[^}]*\bsplitSession\b[^}]*\}\s*from/);
  assert.doesNotMatch(appJsx, /\bimport\s*\{[^}]*\bSplitIcon\b[^}]*\}\s*from/);
  assert.doesNotMatch(appJsx, /\bunvisibleTabs\b/);
});

test('Issue #295: Pane context menu retains reflow, fav, and close-pane', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // Pane menu should retain essential pane actions
  assert.match(appJsx, /key:\s*['"]reflow['"]/);
  assert.match(appJsx, /key:\s*['"]close-pane['"]/);
});

test('Issue #295: Agent context menu retains fav and close without split actions', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // Agent context menu should have fav and close only
  assert.match(appJsx, /menu\.kind === 'agent'/);
  assert.match(appJsx, /key:\s*['"]close['"]/);
});

test('Issue #295: UI-SPEC.md §4.5 documents removal of split-right menu option', async () => {
  const spec = await readFile(new URL('../docs/UI-SPEC.md', import.meta.url), 'utf8');

  assert.match(spec, /彻底删除「向右分屏」（Issue #295）/);
});
