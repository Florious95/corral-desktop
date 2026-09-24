import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WebSocket } from 'ws';
import {
  startTerminalMockDaemon,
  encodeBinary,
  MOCK_SESSIONS,
  MOCK_DEVICE_ID,
} from '../scripts/terminal-mock-daemon.mjs';
import {
  buildFixtureWorkspace,
  applyTerminalFixture,
  getFixturePaths,
} from '../scripts/setup-terminal-fixture.mjs';

test('terminal-mock-daemon: starts, authenticates, serves workspaces and bounded snapshot burst', async () => {
  const daemon = startTerminalMockDaemon({ port: 9929, burstLines: 2, burstIntervalMs: 20 });
  await daemon.ready;

  assert.equal(daemon.port, 9929);

  // Check HTTP whoami
  const whoamiRes = await fetch(`http://127.0.0.1:9929/pair/whoami`);
  assert.equal(whoamiRes.status, 200);
  const whoamiJson = await whoamiRes.json();
  assert.equal(whoamiJson.host_id, MOCK_DEVICE_ID);
  assert.equal(whoamiJson.port, 9929);

  // Connect WebSocket client
  const ws = new WebSocket(daemon.url);
  await new Promise((res, rej) => {
    ws.on('open', res);
    ws.on('error', rej);
  });

  const textFrames = [];
  const binaryFrames = [];

  ws.on('message', (data, isBinary) => {
    if (isBinary) {
      binaryFrames.push(data);
    } else {
      textFrames.push(JSON.parse(String(data)));
    }
  });

  // Request list
  ws.send(JSON.stringify({ v: 1, type: 'list', payload: { req_id: 101 } }));
  await new Promise((resolve) => setTimeout(resolve, 50));

  const listFrame = textFrames.find((f) => f.type === 'listing');
  assert.ok(listFrame);
  assert.equal(listFrame.payload.workspaces.length, 1);
  assert.equal(listFrame.payload.workspaces[0].sessions.length, 4);

  // Subscribe to pane 1
  const targetRef = MOCK_SESSIONS[0].ref;
  ws.send(JSON.stringify({ v: 1, type: 'subscribe', payload: { ref: targetRef, rows: 24, cols: 80 } }));

  // Wait for burst completion
  await new Promise((resolve) => setTimeout(resolve, 150));

  // Verify binary frames received: 1 snapshot + burst deltas
  assert.ok(binaryFrames.length >= 2, `Expected >= 2 binary frames, got ${binaryFrames.length}`);

  // First frame must be kind: 1 (snapshot)
  const firstFrame = binaryFrames[0];
  assert.equal(firstFrame[0], 0x52); // 'R'
  assert.equal(firstFrame[1], 0x41); // 'A'
  assert.equal(firstFrame[2], 0x01); // v1
  assert.equal(firstFrame[3], 0x01); // kind 1 (snapshot)

  // Verify health check
  const healthRes = await fetch(`http://127.0.0.1:9929/health`);
  assert.equal(healthRes.status, 200);
  const healthJson = await healthRes.json();
  assert.equal(healthJson.ok, true);
  assert.equal(healthJson.snapshotsCount, 1);
  assert.equal(healthJson.uniqueSessionsWithSnapshot, 1);
  assert.equal(healthJson.allSettled, true);

  // Clean close
  ws.close();
  await daemon.close();
});

test('terminal-mock-daemon: allows legitimate geometry change re-subscription without getting stuck in awaitingSnapshot', async () => {
  const { SameWidthController } = await import('../src/term/sameWidth.js');
  const daemon = startTerminalMockDaemon({ port: 9931, burstLines: 2, burstIntervalMs: 20 });
  await daemon.ready;

  const ws = new WebSocket(daemon.url);
  const gate = new SameWidthController();
  let snapshots = 0;
  ws.on('message', (bytes, binary) => {
    if (binary && bytes[3] === 1) {
      snapshots += 1;
      gate.acceptSnapshot();
    }
  });

  await new Promise((res) => ws.on('open', res));
  const ref = MOCK_SESSIONS[0].ref;

  // 1. Initial 44x46 subscribe
  gate.settle(44, 46);
  gate.noteSent(44, 46);
  ws.send(JSON.stringify({ v: 1, type: 'subscribe', payload: { ref, rows: 44, cols: 46 } }));

  await new Promise((r) => setTimeout(r, 80));
  assert.equal(snapshots, 1);
  assert.equal(gate.awaitingSnapshot, false);

  // 2. Real container layout settled to 54x148 (must deliver new snapshot and NOT be suppressed!)
  gate.settle(54, 148);
  gate.noteSent(54, 148);
  ws.send(JSON.stringify({ v: 1, type: 'subscribe', payload: { ref, rows: 54, cols: 148 } }));

  await new Promise((r) => setTimeout(r, 100));
  assert.equal(snapshots, 2, 'Legitimate 54x148 layout re-subscription must receive snapshot');
  assert.equal(gate.awaitingSnapshot, false, 'SameWidthController must successfully receive snapshot');

  const health = await (await fetch('http://127.0.0.1:9931/health')).json();
  assert.equal(health.snapshotsCount, 2, 'snapshotsCount must accurately reflect 2 frames');
  assert.equal(health.allSettled, true);

  ws.close();
  await daemon.close();
});

test('setup-terminal-fixture: builds valid 1-pane and 4-pane workspace configurations', () => {
  const cfg1 = buildFixtureWorkspace(1, 9919);
  assert.equal(cfg1.panes, 1);
  assert.equal(cfg1.workspaceState.tabs.length, 1);
  assert.equal(cfg1.workspaceState.tabs[0].root.kind, 'leaf');

  const cfg4 = buildFixtureWorkspace(4, 9919);
  assert.equal(cfg4.panes, 4);
  assert.equal(cfg4.workspaceState.tabs.length, 1);
  assert.equal(cfg4.workspaceState.tabs[0].root.kind, 'split');
});
