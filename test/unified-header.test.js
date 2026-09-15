import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('TitleBar renders full-width header with 80px native traffic lights safe gutter and drag region', async () => {
  const titleBarJsx = await readFile(new URL('../src/components/chrome/TitleBar.jsx', import.meta.url), 'utf8');
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');

  // TitleBar JSX structure
  assert.match(titleBarJsx, /className=\{`tb/);
  assert.match(titleBarJsx, /className="tb-traffic-lights"/);
  assert.match(titleBarJsx, /className="tb-btn tb-sidebar-toggle"/);
  assert.match(titleBarJsx, /<SidebarIcon\s+size=\{16\}/);
  assert.match(titleBarJsx, /className="tb-drag"\s+data-tauri-drag-region/);

  // Traffic lights safe reservation (78~86px range, exactly 80px)
  assert.match(chromeCss, /\.tb-traffic-lights\s*\{[^}]*width:\s*80px;/);
  assert.match(chromeCss, /\.tb\s*\{[^}]*height:\s*38px;/);
  assert.match(chromeCss, /\.tb-sidebar-toggle\s*\{[^}]*width:\s*28px;/);
  assert.match(chromeCss, /\.tb-sidebar-toggle\s*\{[^}]*height:\s*26px;/);
});

test('App structure isolates constant TitleBar above app-body and drops ChromePill', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');
  const appCss = await readFile(new URL('../src/styles/app.css', import.meta.url), 'utf8');
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');

  // ChromePill completely removed from App.jsx and chrome.css
  assert.equal(appJsx.includes('ChromePill'), false);
  assert.equal(chromeCss.includes('chrome-pill'), false);
  assert.equal(chromeCss.includes('chrome-lamp'), false);

  // TitleBar is mounted directly at the root, before app-body
  assert.match(appJsx, /<TitleBar[\s\S]*?<div className="app-body">/);

  // App root is column flex to house full-width header + lower body
  assert.match(appCss, /\.app-root\s*\{[^}]*display:\s*flex;[^}]*flex-direction:\s*column;/);
  assert.match(appCss, /\.app-body\s*\{[^}]*display:\s*flex;[^}]*flex-direction:\s*row;/);
});

test('Rust main.rs restores macOS native traffic lights and drops hide_native_traffic_lights', async () => {
  const mainRs = await readFile(new URL('../src-tauri/src/main.rs', import.meta.url), 'utf8');

  assert.equal(mainRs.includes('hide_native_traffic_lights'), false);
  assert.equal(mainRs.includes('setHidden'), false);
  assert.equal(mainRs.includes('standardWindowButton'), false);
  assert.match(mainRs, /ensure_devices_store/);
});
