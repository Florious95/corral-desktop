import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('TabBar component matches UI-SPEC §4.1.1 and advisor requirements', async () => {
  const tabBarJsx = await readFile(new URL('../src/components/chrome/TabBar.jsx', import.meta.url), 'utf8');
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');

  // TabBar structure
  assert.match(tabBarJsx, /className="tb-tabbar"/);
  assert.match(tabBarJsx, /className="tb-tabs-pinned"/);
  assert.match(tabBarJsx, /className="tb-tabs-scroll"/);
  assert.match(tabBarJsx, /tb-tab-lamp/);
  assert.match(tabBarJsx, /className="tb-tab-close"/);

  // Status indicator lamps (working / idle / unknown - 2026-09-16 顾问审查精进)
  assert.match(tabBarJsx, /const status = agent\?\.state \|\| agent\?\.status \|\| 'unknown';/);
  assert.match(chromeCss, /\.tb-tab-lamp\.is-working\s*\{[^}]*background:\s*(var\(--green\)|#34c759|#22c55e);/);
  assert.match(chromeCss, /\.tb-tab-lamp\.is-working\s*\{[^}]*box-shadow:\s*0 0 6px (var\(--green-ring\)|rgba\(34, 197, 94, 0\.6\));/);
  assert.match(chromeCss, /\.tb-tab-lamp\.is-working\s*\{[^}]*animation:\s*tb-lamp-pulse/);
  assert.match(chromeCss, /\.tb-tab-lamp\.is-idle\s*\{[^}]*background:\s*(var\(--icon-idle\)|rgba\(255,\s*255,\s*255,\s*0\.28\));/);
  assert.match(chromeCss, /\.tb-tab-lamp\.is-unknown\s*\{[^}]*border:\s*1px solid var\(--text-faint\);/);

  // prefers-reduced-motion protection
  assert.match(chromeCss, /@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{[^}]*\.tb-tab-lamp\.is-working\s*\{[^}]*animation:\s*none;/);

  // Pinned tab style (32px 舒适边距，2026-09-16 裁定)
  assert.match(chromeCss, /\.tb-tab-pinned\s*\{[^}]*width:\s*(32px|28px);/);
});

test('TerminalStage (SplitPanes) guarantees same-parent flattened absolute projection', async () => {
  const splitPanesJsx = await readFile(new URL('../src/components/terminal/SplitPanes.jsx', import.meta.url), 'utf8');
  const terminalCss = await readFile(new URL('../src/components/terminal/terminal.css', import.meta.url), 'utf8');

  // Same-parent single DOM container
  assert.match(splitPanesJsx, /className="splitpanes terminal-stage"/);
  assert.match(splitPanesJsx, /previewUid/);
  assert.match(splitPanesJsx, /validUids\.add\(previewUid\)/);
  assert.match(splitPanesJsx, /key=\{uid\}/);
  assert.match(splitPanesJsx, /className=\{`pane-host\$\{isVisible \? '' : ' is-hidden'\}/);

  // Absolute projection; visible macOS bottom leaves follow the live stage edge.
  assert.match(splitPanesJsx, /position:\s*'absolute'/);
  assert.match(splitPanesJsx, /left:\s*`\$\{currentRect\.x\}px`/);
  assert.match(splitPanesJsx, /top:\s*`\$\{currentRect\.y\}px`/);
  assert.match(splitPanesJsx, /width:\s*`\$\{currentRect\.w\}px`/);
  assert.match(splitPanesJsx, /height:\s*anchorBottom \? undefined : `\$\{currentRect\.h\}px`/);
  assert.match(splitPanesJsx, /bottom:\s*anchorBottom \? 0 : undefined/);

  // Background resident pane retains geometry and receives visibility: hidden + inert + aria-hidden
  assert.match(splitPanesJsx, /visibility:\s*isVisible \? 'visible' : 'hidden'/);
  assert.match(splitPanesJsx, /pointerEvents:\s*isVisible \? 'auto' : 'none'/);
  assert.match(splitPanesJsx, /inert=\{!isVisible\}/);
  assert.match(splitPanesJsx, /aria-hidden=\{!isVisible \? 'true' : undefined\}/);

  // Pane close button rendered when multiple visible panes exist
  assert.match(splitPanesJsx, /isVisible && visibleUids\.length > 1/);
  assert.match(splitPanesJsx, /className="pane-close-btn"/);

  // CSS rules for terminal-stage and pane-host
  assert.match(terminalCss, /\.terminal-stage\s*\{[^}]*position:\s*relative;/);
  assert.match(terminalCss, /\.pane-host\s*\{[^}]*position:\s*absolute;/);
  assert.match(terminalCss, /\.pane-host\.is-hidden\s*\{[^}]*visibility:\s*hidden;/);
  assert.match(terminalCss, /\.pane-close-btn\s*\{/);
});

test('App wires TabBar into session header and mounts TerminalStage with am.workspace.v1', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // Session header hosts TabBar
  assert.match(appJsx, /<header className=\{`tb-session-header[\s\S]*?<TabBar[\s\S]*?<\/header>/);

  // SplitPanes receives root, tabs, activeUid, and the transient preview uid
  assert.match(appJsx, /<SplitPanes[\s\S]*?root=\{workspace\.root\}[\s\S]*?tabs=\{workspace\.tabs\}[\s\S]*?activeUid=\{workspace\.activeUid\}[\s\S]*?previewUid=\{workspace\.previewUid\}/);

  // Storage persistence with am.workspace.v1
  assert.match(appJsx, /loadWorkspaceFromStorage/);
  assert.match(appJsx, /saveWorkspaceToStorage\(workspace\)/);

  // Level2 unsubscribe on 'all' or 'fav' (Bug 1 regression guard)
  assert.match(appJsx, /if\s*\(selected === 'all' \|\| selected === 'fav'\)\s*\{\s*dm\.unsubscribeLevel2\(\);/);

  // Tab right-click menu and Pane right-click menu (Issue #261: split-down and split-up removed, split-right preserved)
  assert.match(appJsx, /menu\.kind === 'tab'/);
  assert.match(appJsx, /key: 'split-right'/);
  assert.doesNotMatch(appJsx, /key: 'split-down'/);
  assert.doesNotMatch(appJsx, /向下分屏/);
  assert.doesNotMatch(appJsx, /向上分屏/);
});
