import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  createMultiWorkspace,
  createWorkspaceTab,
  openSessionInActiveTab,
  smartOpenSession,
  removeSessionFromWorkspace,
  getLeaves,
} from '../src/lib/workspaceLayout.js';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', 'src');
const source = (path) => readFileSync(join(ROOT, path), 'utf8');

test('agent lifecycle UI is capability-driven and uses typed request state', () => {
  const app = source('App.jsx');
  const dialog = source('components/chrome/NewAgentDialog.jsx');
  const closeDialog = source('components/chrome/CloseAgentDialog.jsx');
  const agents = source('components/sidebar/AgentsList.jsx');
  assert.match(app, /getAgentLaunchers/);
  assert.match(app, /dm\.createAgent\(/);
  assert.match(app, /dm\.closeSession\(/);
  assert.match(app, /awaitingListing/);
  assert.match(app, /removeSessionFromWorkspace/);
  assert.doesNotMatch(app, /globalThis\.confirm|window\.confirm/);
  assert.match(dialog, /launchers\.map/);
  assert.match(dialog, /supports_bypass/);
  assert.doesNotMatch(dialog, /const PROVIDERS\s*=/);
  assert.match(closeDialog, /onConfirm/);
  assert.doesNotMatch(closeDialog, /window\.confirm|globalThis\.confirm/);
  assert.match(agents, /onClose\(ag\)/);
});

test('authoritative listing gates lifecycle workspace reconciliation across tabs', () => {
  let state = createMultiWorkspace();
  state = openSessionInActiveTab(state, 'device::first');
  state = createWorkspaceTab(state);
  state = openSessionInActiveTab(state, 'device::second');
  state = { ...state, previewUid: 'device::preview', root: { kind: 'leaf', uid: 'device::preview' }, activeUid: 'device::preview' };

  const before = removeSessionFromWorkspace(state, 'device::created');
  assert.deepEqual(before, state, 'create result alone must not mutate workspace');

  const after = removeSessionFromWorkspace(state, 'device::first');
  assert.deepEqual(getLeaves(after.tabs[0].root), []);
  assert.deepEqual(getLeaves(after.tabs[1].root), ['device::second']);
  assert.equal(after.previewUid, 'device::preview');
});

test('closing the preview uid clears only the transient preview slot', () => {
  let state = createMultiWorkspace();
  state = openSessionInActiveTab(state, 'device::first');
  state = smartOpenSession(state, 'device::preview');
  assert.equal(state.previewUid, 'device::preview');
  const next = removeSessionFromWorkspace(state, 'device::preview');
  assert.equal(next.previewUid, null);
  assert.deepEqual(getLeaves(next.root), ['device::first']);
});
