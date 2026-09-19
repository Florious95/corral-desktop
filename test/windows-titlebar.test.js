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
  assert.match(controlsJsx, /fullscreen \? '还原' : '最大化'/);
  assert.match(controlsJsx, /className="tb-win-btn tb-win-close"/);
  assert.match(controlsJsx, /title="关闭"/);

  // 3. 所有按钮必须严格声明 data-tauri-drag-region="false"
  const buttonDragRegionMatches = controlsJsx.match(/data-tauri-drag-region="false"/g);
  assert.ok(buttonDragRegionMatches && buttonDragRegionMatches.length >= 4);

  // 4. 绑定 nativeCapabilities 窗口接口
  assert.match(controlsJsx, /nativeCapabilities\.window\.minimize/);
  assert.match(controlsJsx, /nativeCapabilities\.window\.toggleFullscreen/);
  assert.match(controlsJsx, /nativeCapabilities\.window\.close/);
});

test('TitleBar adapts layout between macOS and Windows platforms', async () => {
  const titleBarJsx = await readFile(new URL('../src/components/chrome/TitleBar.jsx', import.meta.url), 'utf8');

  // 1. 引入 WindowsWindowControls 与平台判断
  assert.match(titleBarJsx, /import WindowsWindowControls from '\.\/WindowsWindowControls\.jsx'/);
  assert.match(titleBarJsx, /isWindows =/);

  // 2. 根容器动态附加 is-windows 类名
  assert.match(titleBarJsx, /isWindows \? ' is-windows' : ''/);

  // 3. macOS 下保留交通灯留白，Windows 下交通灯收敛为 0
  assert.match(titleBarJsx, /\{!isWindows && <div className="tb-traffic-lights"/);

  // 4. Windows 下在右侧末端挂载 WindowsWindowControls
  assert.match(titleBarJsx, /\{isWindows && <WindowsWindowControls/);
});

test('App.jsx implements intelligent Ctrl+V handling for Windows platform', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // 1. 引入 nativeCapabilities
  assert.match(appJsx, /import \{ nativeCapabilities \} from '\.\/core\/nativeCapabilities\.js'/);

  // 2. handlePaneCtrlV 中识别 Windows 平台
  assert.match(appJsx, /const isWindows = nativeCapabilities\.platform === 'windows'/);

  // 3. Windows 下非图片时异步尝试读取并粘贴文件或文本
  assert.match(appJsx, /if \(isWindows\) \{/);
  assert.match(appJsx, /readClipboardFiles/);
  assert.match(appJsx, /formatClipboardFiles/);
  assert.match(appJsx, /nativeCapabilities\.clipboard\.readText/);

  // 4. macOS 仍然保持原有 Toast 提示
  assert.match(appJsx, /setToastMsg\('Ctrl\+V 仅支持图片，请使用 Cmd\+V 粘贴文字'\)/);
});

test('chrome.css defines Fluent styles for Windows window controls without corrupt drag properties', async () => {
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');

  // 必须定义 Windows 控制按钮与悬停样式
  assert.match(chromeCss, /\.tb-win-controls\s*\{/);
  assert.match(chromeCss, /\.tb-win-btn\s*\{[^}]*width:\s*46px;/);
  assert.match(chromeCss, /\.tb-win-btn\.tb-win-close:hover\s*\{[^}]*background:\s*#c42b1c;/);

  // Windows 下交通灯宽度收缩为 0 并隐藏
  assert.match(chromeCss, /\.tb-sidebar-header\.is-windows \.tb-traffic-lights/);

  // 严禁包含废弃的 -webkit-app-region
  assert.equal(chromeCss.includes('-webkit-app-region'), false);
});
