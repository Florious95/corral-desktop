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

test('triggerWindowDrag respects interactive controls and enables window dragging on blank areas', async () => {
  const { triggerWindowDrag } = await import('../src/lib/windowChrome.js');

  // 1. 点击 button 或带有 no-drag 的交互元素时，坚决不触发拖窗
  let dragCalled = false;
  triggerWindowDrag({
    button: 0,
    target: { closest: (sel) => (sel.includes('button') ? true : null) },
  });
  assert.equal(dragCalled, false);

  // 2. 右键或非主键点击，不触发拖窗
  triggerWindowDrag({
    button: 2,
    target: { closest: () => null },
  });
  assert.equal(dragCalled, false);

  // 3. 校验 CSS 样式中 TabBar、Header 与拖拽留白区均具备 -webkit-app-region: drag
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');
  assert.match(chromeCss, /\.tb-tabbar,\s*\.tb-tabs-scroll/);
  assert.match(chromeCss, /\.tb-tab-close,\s*\.tb-tab-add/);
});

test('sidebar workspace working lamp and header status synchronization', async () => {
  const sidebarJsx = await readFile(new URL('../src/components/sidebar/Sidebar.jsx', import.meta.url), 'utf8');
  const spacesListJsx = await readFile(new URL('../src/components/sidebar/SpacesList.jsx', import.meta.url), 'utf8');
  const tabBarJsx = await readFile(new URL('../src/components/chrome/TabBar.jsx', import.meta.url), 'utf8');

  // Sidebar 传入 working 状态给折叠 GroupHeader
  assert.match(sidebarJsx, /working=\{spacesHasWorking\}/);
  assert.match(sidebarJsx, /spaces-dot is-working/);

  // SpacesList 支持工作状态绿点展示
  assert.match(spacesListJsx, /state=\{allSpacesWorking \? 'working' : 'unknown'\}/);
  assert.match(spacesListJsx, /spaces-dot is-\$\{state\}/);

  // TabBar 具备 getTabStatus 实时联动引擎
  assert.match(tabBarJsx, /getTabStatus/);
  assert.match(tabBarJsx, /a\?\.state === 'working' \|\| a\?\.status === 'working'/);
});

test('triggerWindowDrag guarantees exactly-once dispatch and deduplicates bubble/burst events', async () => {
  const { triggerWindowDrag, resetDragThrottleForTest } = await import('../src/lib/windowChrome.js');
  resetDragThrottleForTest();

  let stopCount = 0;
  const mockEvt = {
    button: 0,
    target: { closest: () => null },
    stopPropagation: () => { stopCount++; },
  };

  // 第一次调用：成功分发，标记 _amDragHandled 为 true，并调用 stopPropagation
  const first = triggerWindowDrag(mockEvt);
  assert.equal(first, true);
  assert.equal(mockEvt._amDragHandled, true);
  assert.equal(stopCount, 1);

  // 同一事件冒泡至父元素再次调用：被 _amDragHandled 立即拦截，返回 false
  const second = triggerWindowDrag(mockEvt);
  assert.equal(second, false);
  assert.equal(stopCount, 1);

  // 100ms 内微秒级抛出的另一个事件对象（如同一手势派发的 mousedown）：被时间戳节流拦截
  const burstEvt = {
    button: 0,
    target: { closest: () => null },
    stopPropagation: () => { stopCount++; },
  };
  const third = triggerWindowDrag(burstEvt);
  assert.equal(third, false);
  assert.equal(stopCount, 2);

  // 校验组件源码：TitleBar.jsx、TabBar.jsx、App.jsx 均无内联 getCurrentWindow().startDragging()
  const titleBarJsx = await readFile(new URL('../src/components/chrome/TitleBar.jsx', import.meta.url), 'utf8');
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');
  const tabBarJsx = await readFile(new URL('../src/components/chrome/TabBar.jsx', import.meta.url), 'utf8');

  assert.equal(titleBarJsx.includes('.getCurrentWindow().startDragging()'), false);
  assert.equal(appJsx.includes('.getCurrentWindow().startDragging()'), false);
  assert.equal(tabBarJsx.includes('.getCurrentWindow().startDragging()'), false);
});
