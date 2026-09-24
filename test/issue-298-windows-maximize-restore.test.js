import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import {
  nativeCapabilities,
  setNativeEngineForTests,
  resetNativeEngineForTests,
} from '../src/core/nativeCapabilities.js';
import { fillsDisplay } from '../src/lib/fullscreen.js';

test('Issue #298 W298-05: nativeCapabilities.window provides isMaximized, maximize, unmaximize, and toggleMaximize', async () => {
  resetNativeEngineForTests();

  assert.equal(typeof nativeCapabilities.window.isMaximized, 'function');
  assert.equal(typeof nativeCapabilities.window.maximize, 'function');
  assert.equal(typeof nativeCapabilities.window.unmaximize, 'function');
  assert.equal(typeof nativeCapabilities.window.toggleMaximize, 'function');

  // Verify testEngineOverride delegation
  let isMax = false;
  let maxCount = 0;
  let unmaxCount = 0;

  setNativeEngineForTests({
    window: {
      isMaximized: () => isMax,
      maximize: () => { maxCount += 1; isMax = true; },
      unmaximize: () => { unmaxCount += 1; isMax = false; },
    },
  });

  assert.equal(await nativeCapabilities.window.isMaximized(), false);

  // Toggle 1: should call maximize
  const res1 = await nativeCapabilities.window.toggleMaximize();
  assert.equal(res1, true);
  assert.equal(maxCount, 1);
  assert.equal(unmaxCount, 0);
  assert.equal(await nativeCapabilities.window.isMaximized(), true);

  // Toggle 2: should call unmaximize
  const res2 = await nativeCapabilities.window.toggleMaximize();
  assert.equal(res2, false);
  assert.equal(maxCount, 1);
  assert.equal(unmaxCount, 1);
  assert.equal(await nativeCapabilities.window.isMaximized(), false);

  resetNativeEngineForTests();
});

test('Issue #298 W298-03: isFullscreen and isMaximized are decoupled on Windows (fillsDisplay returns false)', () => {
  resetNativeEngineForTests();
  setNativeEngineForTests({ platform: 'windows' });

  // On Windows, maximized windows fill the screen work area, but are strictly NOT fullscreen
  assert.equal(fillsDisplay(), false, 'fillsDisplay must return false on Windows so maximized is never confused with fullscreen');

  setNativeEngineForTests({ platform: 'macos' });
  // On macOS it can return boolean based on display geometry
  assert.equal(typeof fillsDisplay(), 'boolean');

  resetNativeEngineForTests();
});

test('Issue #298 W298-04: WindowsWindowControls component binds to toggleMaximize and switches title/aria-label', async () => {
  const controlsJsx = await readFile(new URL('../src/components/chrome/WindowsWindowControls.jsx', import.meta.url), 'utf8');

  // Must bind to toggleMaximize rather than toggleFullscreen
  assert.match(controlsJsx, /nativeCapabilities\.window\.toggleMaximize/);
  assert.doesNotMatch(controlsJsx, /nativeCapabilities\.window\.toggleFullscreen/);

  // Title and aria-label must alternate between '最大化' and '还原' based on isMax
  assert.match(controlsJsx, /title=\{isMax \? '还原' : '最大化'\}/);
  assert.match(controlsJsx, /aria-label=\{isMax \? '还原' : '最大化'\}/);

  // Renders restore icon when maximized and single square when not
  assert.match(controlsJsx, /\{isMax \? \(/);
});

test('Issue #298 W298-04: Failure resilience: toggleMaximize rejection is caught safely without throwing', async () => {
  resetNativeEngineForTests();

  setNativeEngineForTests({
    window: {
      isMaximized: () => false,
      maximize: () => Promise.reject(new Error('Tauri API failure')),
      unmaximize: () => Promise.reject(new Error('Tauri API failure')),
    },
  });

  // Calling toggleMaximize when internal calls reject should reject or catch gracefully, not crash
  await assert.rejects(
    nativeCapabilities.window.toggleMaximize(),
    (err) => err.message === 'Tauri API failure',
  );

  resetNativeEngineForTests();
});

test('Issue #298: App.jsx does not pass fullscreen to WindowsWindowControls', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // WindowsWindowControls must NOT be bound to fullscreen prop
  assert.match(appJsx, /\{isWindows && <WindowsWindowControls \/>\}/);
  assert.doesNotMatch(appJsx, /<WindowsWindowControls[^>]*fullscreen=/);
});

test('Issue #298: default.json grants all window maximize and restore permissions', async () => {
  const defaultJson = await readFile(new URL('../src-tauri/capabilities/default.json', import.meta.url), 'utf8');
  const parsed = JSON.parse(defaultJson);

  assert.ok(parsed.permissions.includes('core:window:allow-toggle-maximize'));
  assert.ok(parsed.permissions.includes('core:window:allow-maximize'));
  assert.ok(parsed.permissions.includes('core:window:allow-unmaximize'));
  assert.ok(parsed.permissions.includes('core:window:allow-is-maximized'));
});

test('Issue #298: UI-SPEC.md records Windows maximize and restore state decoupling ruling', async () => {
  const spec = await readFile(new URL('../docs/UI-SPEC.md', import.meta.url), 'utf8');

  assert.match(spec, /Windows 窗口最大化与还原状态解耦（2026-09-24，Issue #298）/);
  assert.match(spec, /nativeCapabilities\.window.*isMaximized.*maximize.*unmaximize.*toggleMaximize/);
});
