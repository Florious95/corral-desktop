import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('MVP M3: MainWindowController.swift configures input hygiene without suspend or blur purge', async () => {
  const swiftCode = await readFile(new URL('../native/Sources/Shell/MainWindowController.swift', import.meta.url), 'utf8');

  // Must configure allowsInlinePredictions = false on macOS 14+
  assert.match(swiftCode, /allowsInlinePredictions\s*=\s*false/);
  assert.match(swiftCode, /allowsAirPlayForMediaPlayback\s*=\s*false/);
  assert.match(swiftCode, /mediaTypesRequiringUserActionForPlayback\s*=\s*\.all/);
  assert.match(swiftCode, /isElementFullscreenEnabled\s*=\s*false/);

  // Strictly EXCLUDE suspend scheduling policy and blur/memory-pressure purge
  assert.doesNotMatch(swiftCode, /inactiveSchedulingPolicy\s*=\s*\.suspend/);
  assert.doesNotMatch(swiftCode, /purgeTransientWebKitData/);
  assert.doesNotMatch(swiftCode, /applicationWillResignActive/);
  assert.doesNotMatch(swiftCode, /makeMemoryPressureSource/);
});

test('MVP M3: Dialogs and inputs strictly enforce autoComplete="off" input hygiene', async () => {
  const [addDeviceJsx, newAgentJsx, settingsJsx, tabBarJsx, devicesPopoverJsx] = await Promise.all([
    readFile(new URL('../src/components/chrome/AddDeviceDialog.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/components/chrome/NewAgentDialog.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/components/chrome/SettingsDialog.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/components/chrome/TabBar.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/components/chrome/DevicesPopover.jsx', import.meta.url), 'utf8'),
  ]);

  // AddDeviceDialog
  assert.match(addDeviceJsx, /<form[^>]*autoComplete="off"/);
  assert.match(addDeviceJsx, /<input[^>]*id="add-name"[^>]*autoComplete="off"/);

  // NewAgentDialog
  assert.match(newAgentJsx, /<form[^>]*autoComplete="off"/);
  assert.match(newAgentJsx, /<input[^>]*id="new-agent-name"[^>]*autoComplete="off"/);

  // SettingsDialog
  assert.match(settingsJsx, /<input[^>]*id="setting-font-family"[^>]*autoComplete="off"/);
  assert.match(settingsJsx, /<input[^>]*id="setting-font-size"[^>]*autoComplete="off"/);

  // TabBar
  assert.match(tabBarJsx, /<input[^>]*className="chr-tab-title-input tb-tab-title-input"[^>]*autoComplete="off"/);

  // DevicesPopover
  assert.match(devicesPopoverJsx, /<input[^>]*className="dp-rename-input"[^>]*autoComplete="off"/);
});
