import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import {
  createMultiWorkspace,
  createWorkspaceTab,
  deserializeWorkspace,
  serializeWorkspace,
} from '../src/lib/workspaceLayout.js';

test('Issue 211 hides only the implicit empty startup tab', async () => {
  const initial = createMultiWorkspace();
  assert.equal(initial.tabs.length, 1);
  assert.equal(initial.tabs[0].isImplicitBlank, true);

  const explicit = createWorkspaceTab(initial);
  assert.equal(explicit.tabs.length, 2);
  assert.equal(explicit.tabs[1].isImplicitBlank, false);

  const roundTrip = deserializeWorkspace(serializeWorkspace(initial));
  assert.equal(roundTrip.tabs[0].isImplicitBlank, true);

  const tabBar = await readFile(new URL('../src/components/chrome/TabBar.jsx', import.meta.url), 'utf8');
  assert.match(tabBar, /t\.isImplicitBlank && isBlankTab\(t\)/);
});
