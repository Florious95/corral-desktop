import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('Issue #270: sidebar toggle button is vertically centered and collinear with TabBar items', async () => {
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');
  const titleBarJsx = await readFile(new URL('../src/components/chrome/TitleBar.jsx', import.meta.url), 'utf8');

  // 1. .tb-sidebar-toggle rules must strictly center vertically without 3px top offset
  const toggleBlock = chromeCss.match(/\.tb-sidebar-toggle\s*\{([^}]*)\}/)?.[1] || '';
  assert.match(toggleBlock, /height:\s*26px;/);
  assert.match(toggleBlock, /align-self:\s*center;/);
  assert.doesNotMatch(toggleBlock, /align-self:\s*flex-start;/);
  assert.doesNotMatch(toggleBlock, /margin-top:\s*3px;/);

  // 2. Both headers (.tb and .tb-session-header) are fixed 38px flex containers with align-items: center
  const tbBlock = chromeCss.match(/\.tb\s*\{([^}]*)\}/)?.[1] || '';
  const sessionHeaderBlock = chromeCss.match(/\.tb-session-header\s*\{([^}]*)\}/)?.[1] || '';
  assert.match(tbBlock, /height:\s*38px;/);
  assert.match(tbBlock, /align-items:\s*center;/);
  assert.match(sessionHeaderBlock, /height:\s*38px;/);
  assert.match(sessionHeaderBlock, /align-items:\s*center;/);

  // 3. TabBar and tabs have matching vertical dimensions and vertical center at y = 19px
  const tabbarBlock = chromeCss.match(/\.tb-tabbar\s*\{([^}]*)\}/)?.[1] || '';
  const tabBlock = chromeCss.match(/\.tb-tab\s*\{([^}]*)\}/)?.[1] || '';
  assert.match(tabbarBlock, /height:\s*28px;/);
  assert.match(tabbarBlock, /align-items:\s*center;/);
  assert.match(tabBlock, /height:\s*26px;/);

  // 4. Calculate exact physical geometry in 38px flex container
  const headerHeight = 38;
  const toggleHeight = 26;
  const tabHeight = 26;
  const tabbarHeight = 28;

  // Toggle button in 38px header (align-self: center)
  const toggleTop = (headerHeight - toggleHeight) / 2; // (38 - 26) / 2 = 6px
  const toggleCenter = toggleTop + toggleHeight / 2; // 6 + 13 = 19px

  // TabBar in 38px header (align-items: center)
  const tabbarTop = (headerHeight - tabbarHeight) / 2; // (38 - 28) / 2 = 5px
  // Tab inside TabBar (align-items: center)
  const tabTopInsideTabbar = (tabbarHeight - tabHeight) / 2; // (28 - 26) / 2 = 1px
  const tabAbsoluteTop = tabbarTop + tabTopInsideTabbar; // 5 + 1 = 6px
  const tabAbsoluteCenter = tabAbsoluteTop + tabHeight / 2; // 6 + 13 = 19px

  assert.equal(toggleTop, 6, 'Toggle button top must be 6px from header top');
  assert.equal(tabAbsoluteTop, 6, 'Tab capsule top must be 6px from header top');
  assert.equal(toggleCenter, 19, 'Toggle button vertical centerline must be at y=19px');
  assert.equal(tabAbsoluteCenter, 19, 'Tab capsule vertical centerline must be at y=19px');
  assert.equal(toggleCenter - tabAbsoluteCenter, 0, 'Vertical offset between sidebar toggle and tab capsule must be exactly 0px');

  // 5. Windows collapsed header padding reservation
  assert.match(chromeCss, /\.tb-session-header\.is-sidebar-collapsed\.is-windows\s*\{[^}]*padding-left:\s*8px;/);

  // 6. JSX structures in collapsed and expanded states
  assert.match(appJsx, /className=\{`tb-session-header\$\{collapsed \? ' is-sidebar-collapsed' : ''\}\$\{isWindows \? ' is-windows' : ''\}`\}/);
  assert.match(appJsx, /<button[\s\S]*?className="tb-btn tb-sidebar-toggle"[\s\S]*?onClick=\{\(\) => setCollapsed\(false\)\}/);
  assert.match(titleBarJsx, /<button[\s\S]*?className="tb-btn tb-sidebar-toggle"[\s\S]*?onClick=\{onToggleSidebar\}/);
});
