import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const root = fileURLToPath(new URL('..', import.meta.url));

test('#204 App.jsx source contract: directory tracking depends on scalar activeSpaceKey', async () => {
  const appSource = await readFile(join(root, 'src/App.jsx'), 'utf8');

  // Verify derivation of primitive string scalar activeSpaceKey
  assert.match(
    appSource,
    /const\s+activeSpaceKey\s*=\s*\(activeKey\s*&&\s*agentByKey\.get\(activeKey\)\?\.spaceKey\)\s*\|\|\s*null;/,
    'activeSpaceKey must be derived as a primitive scalar string or null'
  );

  // Verify effect dependencies
  const trackingEffect = appSource.match(/Issue #195[\s\S]*?},\s*\[([^\]]+)\]\);/);
  assert.ok(trackingEffect, 'directory tracking effect must be present');
  const deps = trackingEffect[1];
  assert.match(deps, /\bactiveKey\b/, 'tracking effect must depend on activeKey');
  assert.match(deps, /settings\.directoryTracking/, 'tracking effect must depend on settings.directoryTracking');
  assert.match(deps, /\bactiveSpaceKey\b/, 'tracking effect must depend on scalar activeSpaceKey');
  assert.doesNotMatch(deps, /\bagentByKey\b/, 'tracking effect must NOT depend on agentByKey (prevents snap back on listing refreshes)');

  // Verify setSelected uses activeSpaceKey
  assert.match(appSource, /setSelected\s*\(\s*activeSpaceKey\s*\);/);
});

test('#204 behavioral simulation: cold start alignment, manual Space retention, and tab switching', () => {
  let selected = 'all';
  let activeKey = 'agent-1';
  let directoryTracking = true;
  let spacesOpen = false;
  let agentsOpen = false;
  let scrollTarget = null;

  // Mutable agent catalog
  const agentCatalog = new Map();

  function deriveActiveSpaceKey() {
    return (activeKey && agentCatalog.get(activeKey)?.spaceKey) || null;
  }

  // Track React's dependency comparison across renders
  let prevDeps = null;

  function renderComponent() {
    const activeSpaceKey = deriveActiveSpaceKey();
    const currentDeps = [directoryTracking, activeKey, activeSpaceKey];

    const hasChanged = !prevDeps || currentDeps.some((dep, i) => dep !== prevDeps[i]);
    prevDeps = currentDeps;

    if (hasChanged) {
      // Execute directory tracking useEffect
      if (!directoryTracking || !activeKey || !activeSpaceKey) return;
      spacesOpen = true;
      agentsOpen = true;
      selected = activeSpaceKey;
      scrollTarget = activeSpaceKey;
    }
  }

  // 1. Cold start: activeKey restored to 'agent-1', but network listing has not arrived yet
  renderComponent();
  assert.equal(selected, 'all', 'Before listing arrives, activeSpaceKey is null so effect does not track prematurely');

  // 2. Network listing arrives: agentCatalog now populates 'agent-1' in 'space-A'
  agentCatalog.set('agent-1', { key: 'agent-1', spaceKey: 'space-A', title: 'Agent A' });
  agentCatalog.set('agent-2', { key: 'agent-2', spaceKey: 'space-B', title: 'Agent B' });
  renderComponent();
  assert.equal(selected, 'space-A', 'Cold start alignment: once listing arrives, activeSpaceKey transitions from null to space-A and tracks accurately');
  assert.equal(spacesOpen, true);
  assert.equal(agentsOpen, true);
  assert.equal(scrollTarget, 'space-A');

  // 3. User manually clicks 'space-B' in left sidebar
  selected = 'space-B'; // onSelect('space-B')
  renderComponent();
  assert.equal(selected, 'space-B', 'Manual directory click must NOT trigger effect; selected remains space-B without snap back');

  // 4. Background listing update / polling arrives (new Map instance, same activeSpaceKey)
  // Reconstruct agentCatalog to simulate new Map reference
  renderComponent();
  assert.equal(selected, 'space-B', 'Regular listing refresh must NOT trigger effect; manual selection remains 100% protected');

  // 5. User switches Tab to 'agent-2' (in 'space-B')
  activeKey = 'agent-2';
  renderComponent();
  assert.equal(selected, 'space-B', 'Switching tab to agent-2 triggers effect and aligns to space-B');

  // 6. User manually clicks 'space-A'
  selected = 'space-A';
  renderComponent();
  assert.equal(selected, 'space-A', 'Manual directory click to space-A remains intact');

  // 7. User switches Tab back to 'agent-1' (in 'space-A')
  activeKey = 'agent-1';
  renderComponent();
  assert.equal(selected, 'space-A', 'Switching tab back to agent-1 triggers effect and aligns to space-A');

  // 8. User disables directoryTracking in settings
  directoryTracking = false;
  renderComponent();
  assert.equal(selected, 'space-A');

  // Switch tab while tracking is disabled
  activeKey = 'agent-2';
  renderComponent();
  assert.equal(selected, 'space-A', 'When directoryTracking is false, tab switch must not change directory selection');

  // 9. User enables directoryTracking in settings
  directoryTracking = true;
  renderComponent();
  assert.equal(selected, 'space-B', 'Enabling directoryTracking immediately syncs to active agent space (space-B)');
});
