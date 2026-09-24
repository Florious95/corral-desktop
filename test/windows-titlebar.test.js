import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import {
  nativeCapabilities,
  setNativeEngineForTests,
  resetNativeEngineForTests,
} from '../src/core/nativeCapabilities.js';

test('detectPlatform returns current host platform and respects test engine overrides', () => {
  resetNativeEngineForTests();
  // 默认探测在 Node 环境下返回 macos 或 windows 或 unknown
  const defaultPlatform = nativeCapabilities.platform;
  assert.ok(defaultPlatform === 'macos' || defaultPlatform === 'windows' || defaultPlatform === 'unknown');

  // 支持 override 为 windows
  setNativeEngineForTests({ platform: 'windows' });
  assert.equal(nativeCapabilities.platform, 'windows');

  // 支持 override 为 macos
  setNativeEngineForTests({ platform: 'macos' });
  assert.equal(nativeCapabilities.platform, 'macos');

  resetNativeEngineForTests();
});

test('WindowsWindowControls component implements three buttons and strict drag-region false contract', async () => {
  const controlsJsx = await readFile(new URL('../src/components/chrome/WindowsWindowControls.jsx', import.meta.url), 'utf8');

  // 1. 结构与容器契约
  assert.match(controlsJsx, /className="tb-win-controls"/);
  assert.match(controlsJsx, /data-tauri-drag-region="false"/);

  // 2. 三个独立控制按钮
  assert.match(controlsJsx, /className="tb-win-btn tb-win-min"/);
  assert.match(controlsJsx, /title="最小化"/);
  assert.match(controlsJsx, /className="tb-win-btn tb-win-max"/);
  assert.match(controlsJsx, /isMax \? '还原' : '最大化'/);
  assert.match(controlsJsx, /className="tb-win-btn tb-win-close"/);
  assert.match(controlsJsx, /title="关闭"/);

  // 3. 所有按钮必须严格声明 data-tauri-drag-region="false"
  const buttonDragRegionMatches = controlsJsx.match(/data-tauri-drag-region="false"/g);
  assert.ok(buttonDragRegionMatches && buttonDragRegionMatches.length >= 4);

  // 4. 绑定 nativeCapabilities 窗口接口（最大化/还原，Issue #298）
  assert.match(controlsJsx, /nativeCapabilities\.window\.minimize/);
  assert.match(controlsJsx, /nativeCapabilities\.window\.toggleMaximize/);
  assert.match(controlsJsx, /nativeCapabilities\.window\.close/);
});

test('TitleBar adapts layout between macOS and Windows platforms', async () => {
  const titleBarJsx = await readFile(new URL('../src/components/chrome/TitleBar.jsx', import.meta.url), 'utf8');

  // 1. 识别 Windows 平台
  assert.match(titleBarJsx, /isWindows =/);

  // 2. 根容器动态附加 is-windows 类名
  assert.match(titleBarJsx, /isWindows \? ' is-windows' : ''/);

  // 3. macOS 下保留交通灯留白，Windows 下交通灯收敛为 0
  assert.match(titleBarJsx, /\{!isWindows && <div className="tb-traffic-lights"/);

  // 4. 严禁在左侧 TitleBar 内嵌套挂载 WindowsWindowControls，防止折叠时按钮向左严重漂移
  assert.equal(titleBarJsx.includes('<WindowsWindowControls'), false);
});

test('App.jsx mounts WindowsWindowControls in global session header with collapsed protection', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // 1. 引入 WindowsWindowControls 与平台判断
  assert.match(appJsx, /import WindowsWindowControls from '\.\/components\/chrome\/WindowsWindowControls\.jsx'/);
  assert.match(appJsx, /const isWindows = nativeCapabilities\.platform === 'windows'/);

  // 2. 在右侧 session header 最右上角挂载三联控制按钮
  assert.match(appJsx, /isWindows \? ' is-windows' : ''/);
  assert.match(appJsx, /\{isWindows && <WindowsWindowControls/);

  // 3. 侧栏折叠态在 Windows 模式下禁止渲染 macOS 交通灯留白
  assert.match(appJsx, /\{!isWindows && <div className="tb-traffic-lights"/);

  // 4. 智能 Ctrl+V 快捷键识别
  assert.match(appJsx, /if \(isWindows\) \{/);
  assert.match(appJsx, /readClipboardFiles/);
  assert.match(appJsx, /formatClipboardFiles/);
  assert.match(appJsx, /nativeCapabilities\.clipboard\.readText/);
});

test('chrome.css defines absolute top-right pinned Fluent controls and 138px gutter for TabBar', async () => {
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');

  // 1. Windows session-header 必须严格预留 138px 避让空间，绝不被 TabBar 压盖
  assert.match(chromeCss, /\.tb-session-header\.is-windows\s*\{[^}]*padding-right:\s*138px;/);

  // 2. WindowsWindowControls 必须绝对定位在视口最右上角且声明 z-index: 50
  assert.match(chromeCss, /\.tb-win-controls\s*\{[^}]*position:\s*absolute;/);
  assert.match(chromeCss, /\.tb-win-controls\s*\{[^}]*top:\s*0;/);
  assert.match(chromeCss, /\.tb-win-controls\s*\{[^}]*right:\s*0;/);
  assert.match(chromeCss, /\.tb-win-controls\s*\{[^}]*width:\s*138px;/);
  assert.match(chromeCss, /\.tb-win-controls\s*\{[^}]*z-index:\s*50;/);

  // 3. 按钮样式与关闭按钮 hover 高亮
  assert.match(chromeCss, /\.tb-win-btn\s*\{[^}]*width:\s*46px;/);
  assert.match(chromeCss, /\.tb-win-btn\.tb-win-close:hover\s*\{[^}]*background:\s*#c42b1c;/);

  // 4. Windows 下交通灯宽度收缩为 0 并隐藏
  assert.match(chromeCss, /\.tb-sidebar-header\.is-windows \.tb-traffic-lights/);

  // 5. 严禁包含废弃的 -webkit-app-region
  assert.equal(chromeCss.includes('-webkit-app-region'), false);
});
