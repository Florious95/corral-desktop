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
  assert.match(titleBarJsx, /data-tauri-drag-region="deep"/);
  assert.match(titleBarJsx, /className="tb-drag"/);

  // Traffic lights safe reservation (78~86px range, exactly 80px)
  assert.match(chromeCss, /\.tb-traffic-lights\s*\{[^}]*width:\s*80px;/);
  assert.match(chromeCss, /\.tb\s*\{[^}]*height:\s*38px;/);
  assert.match(chromeCss, /\.tb-sidebar-toggle\s*\{[^}]*width:\s*28px;/);
  assert.match(chromeCss, /\.tb-sidebar-toggle\s*\{[^}]*height:\s*26px;/);
});

test('App structure implements split header layout per 2026-09-16 ruling and drops ChromePill', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');
  const appCss = await readFile(new URL('../src/styles/app.css', import.meta.url), 'utf8');
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');

  // ChromePill completely removed from App.jsx and chrome.css
  assert.equal(appJsx.includes('ChromePill'), false);
  assert.equal(chromeCss.includes('chrome-pill'), false);
  assert.equal(chromeCss.includes('chrome-lamp'), false);

  // Left column hosts TitleBar (traffic lights + toggle) above Sidebar
  assert.match(appJsx, /<div className=\{`app-left[\s\S]*?<TitleBar[\s\S]*?<Sidebar/);

  // Right column hosts tb-session-header with TabBar
  assert.match(appJsx, /<header className=\{`tb-session-header[\s\S]*?<TabBar/);

  // App root and body layout structure
  assert.match(appCss, /\.app-root\s*\{[^}]*display:\s*flex;/);
  assert.match(appCss, /\.app-body\s*\{[^}]*display:\s*flex;[^}]*flex-direction:\s*row;/);
  assert.match(appCss, /\.app-left\s*\{[^}]*border-right:\s*1px solid/);
});

test('Rust main.rs restores macOS native traffic lights and drops hide_native_traffic_lights', async () => {
  const mainRs = await readFile(new URL('../src-tauri/src/main.rs', import.meta.url), 'utf8');

  assert.equal(mainRs.includes('hide_native_traffic_lights'), false);
  assert.equal(mainRs.includes('setHidden'), false);
  assert.equal(mainRs.includes('standardWindowButton'), false);
  assert.match(mainRs, /ensure_devices_store/);
});

test('Tauri native drag contract: data-tauri-drag-region deep and false resolution via official drag.js rules', async () => {
  // 按照顾问裁定第 4.2 节：基于锁定 Tauri 2.11.5 官方 drag.js 源码实现精准规则校验
  const TAURI_DRAG_REGION_ATTR = 'data-tauri-drag-region';
  const CLICKABLE_TAGS = new Set(['A', 'BUTTON', 'INPUT', 'SELECT', 'TEXTAREA', 'LABEL', 'SUMMARY']);
  const INTERACTIVE_ROLES = new Set(['button', 'link', 'menuitem', 'tab', 'checkbox', 'radio', 'switch', 'option']);

  function isClickableElement(el) {
    return CLICKABLE_TAGS.has(el.tagName)
      || (el.getAttribute && el.getAttribute('contenteditable') && el.getAttribute('contenteditable') !== 'false')
      || (el.getAttribute && el.getAttribute('tabindex') && el.getAttribute('tabindex') !== '-1')
      || (el.getAttribute && INTERACTIVE_ROLES.has(el.getAttribute('role')));
  }

  function isDragRegion(composedPath) {
    for (const el of composedPath) {
      if (!el || !el.getAttribute) continue;
      const attr = el.getAttribute(TAURI_DRAG_REGION_ATTR);
      if (isClickableElement(el) && attr === null) return false;
      if (attr === null) continue;
      if (attr === 'false') return false;
      if (attr === 'deep') return true;
      if (attr === '' || attr === 'true') return el === composedPath[0];
    }
    return false;
  }

  // 1. 模拟在 TitleBar 的空白区域（.tb-drag 或 .tb-traffic-lights）按下：
  const blankChild = { tagName: 'DIV', getAttribute: () => null };
  const headerDeep = { tagName: 'HEADER', getAttribute: (k) => (k === TAURI_DRAG_REGION_ATTR ? 'deep' : null) };
  assert.equal(isDragRegion([blankChild, headerDeep]), true, 'Blank area inside deep header must trigger window drag');

  // 2. 模拟在折叠按钮（带 data-tauri-drag-region="false"）按下：
  const toggleBtn = { tagName: 'BUTTON', getAttribute: (k) => (k === TAURI_DRAG_REGION_ATTR ? 'false' : null) };
  assert.equal(isDragRegion([toggleBtn, headerDeep]), false, 'Button with drag-region false must block window drag');

  // 3. 模拟在 TabBar 的 Tab 标签（role="tab" 且带 false）按下：
  const tabEl = { tagName: 'DIV', getAttribute: (k) => (k === 'role' ? 'tab' : (k === TAURI_DRAG_REGION_ATTR ? 'false' : null)) };
  const navEl = { tagName: 'NAV', getAttribute: () => null };
  assert.equal(isDragRegion([tabEl, navEl, headerDeep]), false, 'Tab with role tab and false must block window drag');

  // 4. 模拟在 TabBar 的空白间隙处按下：
  const tabGap = { tagName: 'DIV', getAttribute: () => null };
  assert.equal(isDragRegion([tabGap, navEl, headerDeep]), true, 'Gap in TabBar inside deep header must trigger window drag');
});

test('sidebar workspace working lamp and header status synchronization', async () => {
  const sidebarJsx = await readFile(new URL('../src/components/sidebar/Sidebar.jsx', import.meta.url), 'utf8');
  const spacesListJsx = await readFile(new URL('../src/components/sidebar/SpacesList.jsx', import.meta.url), 'utf8');
  const tabBarJsx = await readFile(new URL('../src/components/chrome/TabBar.jsx', import.meta.url), 'utf8');

  // 1. Sidebar 传入 working 状态给折叠 GroupHeader
  assert.match(sidebarJsx, /working=\{spacesHasWorking\}/);
  assert.match(sidebarJsx, /spaces-dot is-working/);

  // 2. SpacesList 文件夹行绿灯已退役（2026-09-17 裁定）：行内状态灯已彻底移除，收敛至右侧双列数字徽标
  assert.equal(spacesListJsx.includes('SpaceState'), false, 'SpaceState must be eliminated from SpacesList');
  assert.equal(spacesListJsx.includes('spaces-dot is-'), false, 'spaces-dot must be eliminated from SpacesList');
  assert.match(spacesListJsx, /className="spaces-row-counts"/);
  assert.match(spacesListJsx, /spaces-count-working/);
  assert.match(spacesListJsx, /spaces-count-total/);

  // 3. TabBar 具备 getTabStatus 实时联动引擎，顶部选项卡呼吸灯绝对完好保留
  assert.match(tabBarJsx, /getTabStatus/);
  assert.match(tabBarJsx, /a\?\.state === 'working' \|\| a\?\.status === 'working'/);
  assert.match(tabBarJsx, /<StatusLamp status=\{finalStatus\} \/>/);
});

test('elimination of corrupt drag code and verification of capability permissions', async () => {
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');
  const windowChromeJs = await readFile(new URL('../src/lib/windowChrome.js', import.meta.url), 'utf8');
  const titleBarJsx = await readFile(new URL('../src/components/chrome/TitleBar.jsx', import.meta.url), 'utf8');
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');
  const tabBarJsx = await readFile(new URL('../src/components/chrome/TabBar.jsx', import.meta.url), 'utf8');
  const capabilitiesJson = await readFile(new URL('../src-tauri/capabilities/default.json', import.meta.url), 'utf8');

  // 1. 彻底清除 -webkit-app-region 腐败声明
  assert.equal(chromeCss.includes('-webkit-app-region'), false, 'All -webkit-app-region declarations must be deleted');

  // 2. 彻底删除 windowChrome.js 中过时的 triggerWindowDrag 与节流辅助代码
  assert.equal(windowChromeJs.includes('triggerWindowDrag'), false, 'triggerWindowDrag must be removed from windowChrome.js');
  assert.equal(windowChromeJs.includes('resetDragThrottleForTest'), false);
  assert.equal(windowChromeJs.includes('appWindowInstance'), false);

  // 3. 各组件中彻底移除 triggerWindowDrag 与内联 startDragging 调用
  assert.equal(titleBarJsx.includes('triggerWindowDrag'), false);
  assert.equal(appJsx.includes('triggerWindowDrag'), false);
  assert.equal(tabBarJsx.includes('triggerWindowDrag'), false);
  assert.equal(titleBarJsx.includes('.getCurrentWindow().startDragging()'), false);
  assert.equal(appJsx.includes('.getCurrentWindow().startDragging()'), false);

  // 4. capabilities 必须授予核心权限 core:window:allow-start-dragging
  assert.match(capabilitiesJson, /"core:window:allow-start-dragging"/);
});

test('visual & aesthetic refinement (2026-09-16 advisor review closing)', async () => {
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');
  const sidebarCss = await readFile(new URL('../src/components/sidebar/sidebar.css', import.meta.url), 'utf8');
  const terminalCss = await readFile(new URL('../src/components/terminal/terminal.css', import.meta.url), 'utf8');
  const agentsListJsx = await readFile(new URL('../src/components/sidebar/AgentsList.jsx', import.meta.url), 'utf8');
  const splitPanesJsx = await readFile(new URL('../src/components/terminal/SplitPanes.jsx', import.meta.url), 'utf8');

  // 1. 彻底消灭未定义 CSS 变量
  assert.equal(chromeCss.includes('--surface-2'), false, 'Undefined --surface-2 must be eliminated');
  assert.equal(chromeCss.includes('--border-soft'), false, 'Undefined --border-soft must be eliminated');
  assert.equal(chromeCss.includes('--hover-6'), false, 'Undefined --hover-6 must be eliminated');
  assert.equal(terminalCss.includes('--border-soft'), false, 'Undefined --border-soft must be eliminated');

  // 2. 激活 Tab 使用背景 var(--bg) 与边框 var(--border-input)
  assert.match(chromeCss, /\.tb-tab\.is-active\s*\{[^}]*background:\s*var\(--bg\);/);
  assert.match(chromeCss, /\.tb-tab\.is-active\s*\{[^}]*border-color:\s*var\(--border-input\);/);

  // 3. Inactive Tab 与 Agent meta 提升对比度
  assert.match(chromeCss, /\.tb-tab\s*\{[^}]*color:\s*var\(--ink-700\);/);
  assert.match(sidebarCss, /\.agents-row-meta\s*\{[^}]*color:\s*var\(--ink-700\);/);

  // 4. 区分已打开（open）与当前选中活跃（active）
  assert.match(agentsListJsx, /isActive=\{activeUid === ag\.key\}/);
  assert.match(sidebarCss, /\.agents-row\.is-open\s*\{[^}]*background-color:\s*var\(--fill-subtle\);/);
  assert.match(sidebarCss, /\.agents-row\.is-active\s*\{[^}]*background-color:\s*var\(--sel-bg\);/);

  // 5. 分屏多窗格输入焦点覆盖环
  assert.match(splitPanesJsx, /data-multi-pane=\{visibleUids\.length > 1/);
  assert.match(terminalCss, /\[data-multi-pane="true"\] \.pane-host\.is-active::after/);

  // 6. Pinned Tab 32px 与关闭/新建按钮热区
  assert.match(chromeCss, /\.tb-tab-pinned\s*\{[^}]*width:\s*32px;/);
  assert.match(chromeCss, /\.tb-tab-close\s*\{[^}]*width:\s*18px;[^}]*height:\s*18px;/);
  assert.match(chromeCss, /\.tb-tab-add\s*\{[^}]*width:\s*26px;[^}]*height:\s*26px;/);
});
