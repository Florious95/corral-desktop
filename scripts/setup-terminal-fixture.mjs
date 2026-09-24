#!/usr/bin/env node
/*
 * Setup script for CorralTest.app isolated terminal fixture.
 *
 * Configures ~/Library/Application Support/com.corral.desktop.test/ and clears
 * stale WebKit localStorage so CorralTest.app automatically launches with
 * 1 pane or 4 panes connected to the isolated mock daemon (ws://127.0.0.1:9919/ws).
 *
 * Usage:
 *   node scripts/setup-terminal-fixture.mjs [--panes 1|4] [--port 9919] [--clean]
 */

import { homedir } from 'node:os';
import { join } from 'node:path';
import { existsSync } from 'node:fs';
import { mkdir, writeFile, rm, chmod } from 'node:fs/promises';
import { createMultiWorkspace } from '../src/lib/workspaceLayout.js';
import { DEFAULT_MOCK_PORT, MOCK_DEVICE_ID, MOCK_SESSIONS } from './terminal-mock-daemon.mjs';

export const BUNDLE_ID = 'com.corral.desktop.test';

export function getFixturePaths(customAppSupport = null, customWebKit = null) {
  const home = homedir();
  const appSupport = customAppSupport || join(home, 'Library', 'Application Support', BUNDLE_ID);
  const webKit = customWebKit || join(home, 'Library', 'WebKit', BUNDLE_ID);
  return {
    appSupport,
    webKit,
    devicesFile: join(appSupport, 'devices.json'),
    uiSnapshotFile: join(appSupport, 'ui-snapshot-v1.json'),
  };
}

export function buildFixtureWorkspace(panes = 1, port = DEFAULT_MOCK_PORT) {
  const deviceId = MOCK_DEVICE_ID;
  const uid1 = `${deviceId}::${MOCK_SESSIONS[0].ref}`;
  const uid2 = `${deviceId}::${MOCK_SESSIONS[1].ref}`;
  const uid3 = `${deviceId}::${MOCK_SESSIONS[2].ref}`;
  const uid4 = `${deviceId}::${MOCK_SESSIONS[3].ref}`;

  let root;
  let activeUid;
  let tabName;

  if (panes === 4) {
    tabName = 'Benchmark 4-Pane Grid';
    activeUid = uid1;
    root = {
      kind: 'split',
      axis: 'x',
      ratio: 0.5,
      first: {
        kind: 'split',
        axis: 'y',
        ratio: 0.5,
        first: { kind: 'leaf', uid: uid1 },
        second: { kind: 'leaf', uid: uid2 },
      },
      second: {
        kind: 'split',
        axis: 'y',
        ratio: 0.5,
        first: { kind: 'leaf', uid: uid3 },
        second: { kind: 'leaf', uid: uid4 },
      },
    };
  } else {
    // Default 1-pane
    tabName = 'Benchmark 1-Pane Terminal';
    activeUid = uid1;
    root = { kind: 'leaf', uid: uid1 };
  }

  const workspaceState = createMultiWorkspace({
    tabs: [
      {
        id: 'tab-benchmark',
        uid: 'tab-benchmark',
        name: tabName,
        isCustomTitle: true,
        pinned: false,
        isBlank: false,
        activeUid,
        root,
      },
    ],
    activeTabId: 'tab-benchmark',
  });

  const devicesArray = [
    {
      id: deviceId,
      name: `MockDaemon ${port}`,
      url: `ws://127.0.0.1:${port}/ws`,
      token: '',
    },
  ];

  const uiSnapshot = {
    version: 1,
    values: {
      'am.devices': JSON.stringify(devicesArray),
      'am.deviceChecks': JSON.stringify({ [deviceId]: true }),
      'am.workspace.v2': JSON.stringify(workspaceState),
      'am.workspace.v1': JSON.stringify(workspaceState),
      'am.selected': 'all',
      'am.spacesOpen': 'true',
      'am.agentsOpen': 'true',
      'am.collapsed': 'false',
    },
  };

  return {
    panes,
    port,
    deviceId,
    devicesArray,
    workspaceState,
    uiSnapshot,
  };
}

export async function applyTerminalFixture(options = {}) {
  const panes = Number(options.panes || 1);
  const port = Number(options.port || DEFAULT_MOCK_PORT);
  const paths = getFixturePaths(options.appSupport, options.webKit);

  if (options.clean === true) {
    if (existsSync(paths.webKit)) {
      await rm(paths.webKit, { recursive: true, force: true });
    }
    if (existsSync(paths.devicesFile)) {
      await rm(paths.devicesFile, { force: true });
    }
    if (existsSync(paths.uiSnapshotFile)) {
      await rm(paths.uiSnapshotFile, { force: true });
    }
    return { cleaned: true, paths };
  }

  // 1. Clear WebKit website data to wipe stale localStorage SQLite databases
  if (existsSync(paths.webKit)) {
    await rm(paths.webKit, { recursive: true, force: true });
  }

  // 2. Ensure application support directory exists
  await mkdir(paths.appSupport, { recursive: true, mode: 0o700 });

  // 3. Build state
  const config = buildFixtureWorkspace(panes, port);

  // 4. Write devices.json (0600 mode)
  await writeFile(paths.devicesFile, JSON.stringify({ devices: config.devicesArray }, null, 2), {
    mode: 0o600,
  });
  await chmod(paths.devicesFile, 0o600);

  // 5. Write ui-snapshot-v1.json
  await writeFile(paths.uiSnapshotFile, JSON.stringify(config.uiSnapshot, null, 2), {
    mode: 0o600,
  });

  return {
    ok: true,
    panes,
    port,
    paths,
    config,
  };
}

import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

// Direct CLI invocation
if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  const isClean = process.argv.includes('--clean');
  const panesIdx = process.argv.indexOf('--panes');
  const panes = panesIdx !== -1 ? Number(process.argv[panesIdx + 1]) : 1;
  const portIdx = process.argv.indexOf('--port');
  const port = portIdx !== -1 ? Number(process.argv[portIdx + 1]) : DEFAULT_MOCK_PORT;

  const result = await applyTerminalFixture({ panes, port, clean: isClean });
  if (isClean) {
    console.log('[setup-terminal-fixture] Test profile cleaned successfully.');
  } else {
    console.log(`[setup-terminal-fixture] Configured ${panes}-pane terminal fixture for CorralTest.app:`);
    console.log(`  - Daemon: ws://127.0.0.1:${port}/ws (zero-credential isolated loopback)`);
    console.log(`  - Devices file: ${result.paths.devicesFile}`);
    console.log(`  - UI snapshot: ${result.paths.uiSnapshotFile}`);
    console.log(`  - WebKit data: wiped clean for fresh auto-hydration`);
  }
}
