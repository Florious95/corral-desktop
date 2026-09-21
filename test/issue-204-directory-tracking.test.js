import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';

const root = fileURLToPath(new URL('..', import.meta.url));

test('#204 App.jsx source contract: directory tracking only triggers on activeKey transition or toggle', async () => {
  const appSource = await readFile(join(root, 'src/App.jsx'), 'utf8');

  // Verify ref declarations exist
  assert.match(appSource, /const\s+prevActiveKeyRef\s*=\s*useRef\s*\(\s*activeKey\s*\);/, 'prevActiveKeyRef must be initialized with activeKey');
  assert.match(appSource, /const\s+prevTrackingRef\s*=\s*useRef\s*\(\s*settings\.directoryTracking\s*\);/, 'prevTrackingRef must track settings.directoryTracking');

  // Verify effect dependencies
  const trackingEffect = appSource.match(/Issue #195[\s\S]*?},\s*\[([^\]]+)\]\);/);
  assert.ok(trackingEffect, 'directory tracking effect must be present');
  const deps = trackingEffect[1];
  assert.match(deps, /\bactiveKey\b/, 'tracking effect must depend on activeKey');
  assert.match(deps, /settings\.directoryTracking/, 'tracking effect must depend on settings.directoryTracking');
  assert.doesNotMatch(deps, /\bagentByKey\b/, 'tracking effect must NOT depend on agentByKey (prevents snap back on listing refreshes)');

  // Verify activeKey transition check guards setSelected
  assert.match(appSource, /activeKeyChanged\s*=\s*activeKey\s*!==\s*prevActiveKeyRef\.current/);
  assert.match(appSource, /if\s*\(\s*!activeKeyChanged\s*&&\s*!trackingJustEnabled\s*\)\s*return;/);
});

test('#204 behavioral simulation: manual directory selection is preserved across re-renders and agent updates', () => {
  // Simulate the React component state and effect execution
  let selected = 'all';
  let activeKey = 'agent-1';
  let directoryTracking = true;
  let spacesOpen = false;
  let agentsOpen = false;
  let scrollTarget = null;

  const agentCatalog = new Map([
    ['agent-1', { key: 'agent-1', spaceKey: 'space-A', title: 'Agent A' }],
    ['agent-2', { key: 'agent-2', spaceKey: 'space-B', title: 'Agent B' }],
  ]);

  // Ref holders
  const prevActiveKeyRef = { current: activeKey };
  const prevTrackingRef = { current: directoryTracking };
  const agentByKeyRef = { current: agentCatalog };

  function runDirectoryTrackingEffect() {
    const isTrackingEnabled = !!directoryTracking;
    const trackingJustEnabled = isTrackingEnabled && !prevTrackingRef.current;
    const activeKeyChanged = activeKey !== prevActiveKeyRef.current;

    prevTrackingRef.current = isTrackingEnabled;
    prevActiveKeyRef.current = activeKey;

    if (!isTrackingEnabled || !activeKey) return;
    if (!activeKeyChanged && !trackingJustEnabled) return;

    const currentAgent = agentByKeyRef.current.get(activeKey);
    if (!currentAgent?.spaceKey) return;

    spacesOpen = true;
    agentsOpen = true;
    selected = currentAgent.spaceKey;
    scrollTarget = currentAgent.spaceKey;
  }

  // Initial render with tracking enabled: activeKey is 'agent-1', prevActiveKeyRef is 'agent-1'
  runDirectoryTrackingEffect();
  // On mount with prevActiveKeyRef = useRef(activeKey), it doesn't overwrite initial selected
  assert.equal(selected, 'all');

  // 1. User switches tab to 'agent-2'
  activeKey = 'agent-2';
  runDirectoryTrackingEffect();
  assert.equal(selected, 'space-B', 'Tab switch to agent-2 must track to space-B');
  assert.equal(spacesOpen, true);
  assert.equal(agentsOpen, true);
  assert.equal(scrollTarget, 'space-B');

  // 2. User manually clicks 'space-A' in sidebar to browse other directory
  selected = 'space-A'; // onSelect('space-A')

  // Component re-renders with the same activeKey ('agent-2')
  runDirectoryTrackingEffect();
  assert.equal(selected, 'space-A', 'Manual directory selection must NOT be snapped back to space-B');

  // Background listing update occurs: new Map instance for agentByKey
  agentByKeyRef.current = new Map(agentCatalog);
  runDirectoryTrackingEffect();
  assert.equal(selected, 'space-A', 'Listing / agentByKey refresh must NOT snap back manual directory selection');

  // Another re-render with manual selection to 'all'
  selected = 'all';
  runDirectoryTrackingEffect();
  assert.equal(selected, 'all', 'Manual selection to "all" must NOT be snapped back');

  // 3. User switches tab back to 'agent-1'
  activeKey = 'agent-1';
  runDirectoryTrackingEffect();
  assert.equal(selected, 'space-A', 'Explicit tab switch to agent-1 must track to space-A');

  // 4. User manually selects 'space-B'
  selected = 'space-B';
  runDirectoryTrackingEffect();
  assert.equal(selected, 'space-B', 'Manual selection to space-B must remain intact');

  // 5. User disables directoryTracking setting
  directoryTracking = false;
  runDirectoryTrackingEffect();
  assert.equal(selected, 'space-B');

  // Switch tab while tracking is disabled
  activeKey = 'agent-2';
  runDirectoryTrackingEffect();
  assert.equal(selected, 'space-B', 'When tracking is disabled, tab switch must not change directory selection');

  // 6. User re-enables directoryTracking setting
  directoryTracking = true;
  runDirectoryTrackingEffect();
  assert.equal(selected, 'space-B', 'Toggling directory tracking ON must immediately sync to active agent directory (space-B)');
});
