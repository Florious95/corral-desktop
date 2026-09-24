import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import {
  DEFAULT_THEME_MODE,
  DEFAULT_SETTINGS,
  loadSettings,
  saveSetting,
} from '../src/core/settings.js';

test('Issue #253: Sidebar search placeholder is completely removed from JSX and CSS', async () => {
  const [sidebarJsx, sidebarCss] = await Promise.all([
    readFile(new URL('../src/components/sidebar/Sidebar.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/components/sidebar/sidebar.css', import.meta.url), 'utf8'),
  ]);

  // Sidebar.jsx must not import or render SearchIcon or sidebar-search
  assert.doesNotMatch(sidebarJsx, /SearchIcon/);
  assert.doesNotMatch(sidebarJsx, /sidebar-search/);
  assert.doesNotMatch(sidebarJsx, /<span className="sidebar-search-label">/);

  // sidebar.css must not contain sidebar-search selectors
  assert.doesNotMatch(sidebarCss, /\.sidebar-search\b/);
  assert.doesNotMatch(sidebarCss, /\.sidebar-search-label\b/);
});

test('Issue #252: Settings button has dedicated interactive region separated from All Devices', async () => {
  const [sidebarJsx, sidebarCss] = await Promise.all([
    readFile(new URL('../src/components/sidebar/Sidebar.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/components/sidebar/sidebar.css', import.meta.url), 'utf8'),
  ]);

  // Dedicated footer container with two sibling interactive elements
  assert.match(sidebarJsx, /className="sidebar-footer"/);
  assert.match(sidebarJsx, /className="chr-btn-reset sidebar-devices"/);
  assert.match(sidebarJsx, /className="chr-btn-reset sidebar-settings-btn sidebar-devices-gear"/);
  assert.match(sidebarJsx, /onClick=\{onOpenSettings\}/);

  // Settings button is a sibling, not nested inside the devices toggle area
  const devicesBlock = sidebarJsx.match(/<button[^>]*sidebar-devices[^>]*>[\s\S]*?<\/button>/)?.[0] || '';
  assert.doesNotMatch(devicesBlock, /sidebar-settings-btn/);
  assert.doesNotMatch(devicesBlock, /onOpenSettings/);

  // CSS ensures settings button has at least 32px hitbox and separate layout
  assert.match(sidebarCss, /\.sidebar-footer\s*\{[^}]*display:\s*flex;/);
  assert.match(sidebarCss, /\.sidebar-settings-btn\s*\{[^}]*width:\s*34px;/);
  assert.match(sidebarCss, /\.sidebar-settings-btn\s*\{[^}]*height:\s*34px;/);
  assert.match(sidebarCss, /\.sidebar-settings-btn:hover\s*\{[^}]*transform:\s*rotate/);
});

test('Issue #254: AgentsList streamlines session row to three core elements without redundant text', async () => {
  const [agentsListJsx, sidebarCss] = await Promise.all([
    readFile(new URL('../src/components/sidebar/AgentsList.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/components/sidebar/sidebar.css', import.meta.url), 'utf8'),
  ]);

  // Redundant metaText and PROVIDER_LABEL text are completely eliminated
  assert.doesNotMatch(agentsListJsx, /metaText/);
  assert.doesNotMatch(agentsListJsx, /PROVIDER_LABEL/);
  assert.doesNotMatch(agentsListJsx, /agents-row-metatext/);

  // Row contains only: status dot, ProviderIcon, and session title
  assert.match(agentsListJsx, /className=\{`agents-dot is-\$\{stateOf\(ag\.state\)\}`\}/);
  assert.match(agentsListJsx, /<ProviderIcon[\s\S]*?provider=\{ag\.provider\}/);
  assert.match(agentsListJsx, /className="agents-row-title">\{ag\.title\}<\/span>/);

  // CSS aligns row items cleanly and centers vertically
  assert.match(sidebarCss, /\.agents-row\s*\{[^}]*display:\s*flex;/);
  assert.match(sidebarCss, /\.agents-row\s*\{[^}]*align-items:\s*center;/);
  assert.match(sidebarCss, /\.agents-row-main\s*\{[^}]*display:\s*flex;/);
  assert.match(sidebarCss, /\.agents-row-main\s*\{[^}]*align-items:\s*center;/);
});

test('Issue #255: Theme mode settings and tokens support light, dark, and system auto-adaptation', async () => {
  const [tokensCss, appJsx] = await Promise.all([
    readFile(new URL('../src/styles/tokens.css', import.meta.url), 'utf8'),
    readFile(new URL('../src/App.jsx', import.meta.url), 'utf8'),
  ]);

  // tokens.css declares dark theme tokens and system media query
  assert.match(tokensCss, /\[data-theme='dark'\]/);
  assert.match(tokensCss, /@media \(prefers-color-scheme: dark\)/);

  // App.jsx applies data-theme on documentElement and listens to system scheme changes
  assert.match(appJsx, /document\.documentElement\.setAttribute\('data-theme'/);
  assert.match(appJsx, /window\.matchMedia\('\(prefers-color-scheme: dark\)'\)/);
  assert.match(appJsx, /terminal:theme-change/);

  // Settings contract supports themeMode
  assert.equal(DEFAULT_THEME_MODE, 'system');
  assert.equal(DEFAULT_SETTINGS.themeMode, 'system');
});

test('Issue #261 & #295: Pane context menu removes split-down and split-right', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // Pane menu excludes all legacy split actions (split-right, split-down, split-up)
  assert.doesNotMatch(appJsx, /key: 'split-right'/);
  assert.doesNotMatch(appJsx, /向右分屏/);
  assert.doesNotMatch(appJsx, /key: 'split-down'/);
  assert.doesNotMatch(appJsx, /向下分屏/);
  assert.doesNotMatch(appJsx, /向上分屏/);
});
