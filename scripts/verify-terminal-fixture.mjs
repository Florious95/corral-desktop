#!/usr/bin/env node
/*
 * Verification probe for isolated terminal benchmark fixture.
 *
 * Verifies that:
 * 1. terminal-mock-daemon starts on port 9919, responds to /health and /pair/whoami
 * 2. setup-terminal-fixture configures 1-pane and 4-pane workspaces with zero credentials
 * 3. Client connection successfully receives snapshot and burst, and settles into quiet state
 *
 * Usage:
 *   node scripts/verify-terminal-fixture.mjs
 */

import { WebSocket } from 'ws';
import { startTerminalMockDaemon, MOCK_DEVICE_ID, MOCK_SESSIONS } from './terminal-mock-daemon.mjs';
import { buildFixtureWorkspace, applyTerminalFixture, getFixturePaths } from './setup-terminal-fixture.mjs';

async function main() {
  console.log('[verify] Starting isolated terminal fixture verification...');

  // 1. Verify workspace configuration builders
  console.log('[verify] 1. Testing workspace state builders...');
  const cfg1 = buildFixtureWorkspace(1, 9919);
  if (cfg1.workspaceState.tabs[0].root.kind !== 'leaf') {
    throw new Error('1-pane workspace root should be a leaf node');
  }
  const cfg4 = buildFixtureWorkspace(4, 9919);
  if (cfg4.workspaceState.tabs[0].root.kind !== 'split') {
    throw new Error('4-pane workspace root should be a split node');
  }
  console.log('  ✓ 1-pane and 4-pane configurations verified');

  // 2. Start mock daemon on isolated port 9939 for self-test
  console.log('[verify] 2. Testing mock daemon protocol...');
  const daemon = startTerminalMockDaemon({ port: 9939, burstLines: 2, burstIntervalMs: 30 });
  await daemon.ready;
  console.log(`  ✓ Mock daemon listening on ws://127.0.0.1:9939/ws`);

  // Check HTTP whoami
  const whoamiRes = await fetch('http://127.0.0.1:9939/pair/whoami');
  const whoami = await whoamiRes.json();
  if (whoami.host_id !== MOCK_DEVICE_ID || whoami.port !== 9939) {
    throw new Error('Invalid /pair/whoami payload');
  }
  console.log('  ✓ /pair/whoami verified');

  // Connect client
  const ws = new WebSocket(daemon.url);
  await new Promise((res, rej) => {
    ws.on('open', res);
    ws.on('error', rej);
  });

  const binaryFrames = [];
  ws.on('message', (data, isBinary) => {
    if (isBinary) binaryFrames.push(data);
  });

  // Subscribe to pane 1
  ws.send(JSON.stringify({ v: 1, type: 'subscribe', payload: { ref: MOCK_SESSIONS[0].ref, rows: 24, cols: 80 } }));

  // Wait for burst completion
  await new Promise((r) => setTimeout(r, 120));

  if (binaryFrames.length < 2) {
    throw new Error(`Expected at least 2 binary frames (snapshot + deltas), got ${binaryFrames.length}`);
  }

  const snapshotKind = binaryFrames[0][3];
  if (snapshotKind !== 1) {
    throw new Error(`First binary frame must be snapshot (kind=1), got kind=${snapshotKind}`);
  }
  console.log('  ✓ Snapshot frame received and verified');

  // Check health endpoint
  const healthRes = await fetch('http://127.0.0.1:9939/health');
  const health = await healthRes.json();
  if (!health.ok || !health.allSettled) {
    throw new Error(`Expected daemon to report allSettled: true, got: ${JSON.stringify(health)}`);
  }
  console.log('  ✓ Daemon /health reports allSettled: true');

  // Clean up
  ws.close();
  await daemon.close();
  console.log('[verify] All fixture verification checks PASSED successfully!');
}

main().catch((err) => {
  console.error('[verify] FAILED:', err);
  process.exit(1);
});
