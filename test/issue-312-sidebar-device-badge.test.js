import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { createServer } from 'vite';
import react from '@vitejs/plugin-react';

import {
  isLocalHost,
  formatDeviceBadge,
  getDeviceBadgeTitle,
} from '../src/lib/deviceBadge.js';

// Setup Vite SSR pipeline to test real React components
const server = await createServer({
  configFile: false,
  root: fileURLToPath(new URL('..', import.meta.url)),
  plugins: [react()],
  server: { middlewareMode: true, watch: null, hmr: false },
  logLevel: 'silent',
});
after(() => server.close());

const { default: SpacesList } = await server.ssrLoadModule('/src/components/sidebar/SpacesList.jsx');
const { default: AgentsList } = await server.ssrLoadModule('/src/components/sidebar/AgentsList.jsx');

test('Issue #312: formatDeviceBadge derives compact alias and strips verbose addresses', () => {
  // 1. 本地回环地址归一化为 Local
  assert.equal(formatDeviceBadge('127.0.0.1:9900'), 'Local');
  assert.equal(formatDeviceBadge('ws://127.0.0.1:9900/ws'), 'Local');
  assert.equal(formatDeviceBadge('localhost:9900'), 'Local');
  assert.equal(formatDeviceBadge('Local'), 'Local');
  assert.equal(formatDeviceBadge('', { deviceLocal: true }), 'Local');
  assert.equal(formatDeviceBadge('AnyName', { deviceLocal: true }), 'Local');

  // 2. 5090 远端设备优先提取 5090 极简别名
  assert.equal(
    formatDeviceBadge('Windows 5090 · 安卓 APP', { deviceUrl: 'ws://192.168.31.110:9900/ws' }),
    '5090',
  );
  assert.equal(formatDeviceBadge('5090'), '5090');
  assert.equal(formatDeviceBadge('WSL-5090'), '5090');

  // 3. 常见包含分隔符的名称提取第一段有效别名
  assert.equal(formatDeviceBadge('Mac-Mini · WebSocket'), 'Mac-Mini');
  assert.equal(formatDeviceBadge('Home-Server · 10.0.0.5'), 'Home-Server');

  // 4. IP:Port 移除默认端口 9900
  assert.equal(formatDeviceBadge('100.75.207.88:9900'), '100.75.207.88');
  assert.equal(formatDeviceBadge('ws://192.168.1.100:9900/ws'), '192.168.1.100');

  // 5. 空白兜底
  assert.equal(formatDeviceBadge(''), 'Remote');
});

test('Issue #312: getDeviceBadgeTitle provides full device address for hover tooltip', () => {
  assert.equal(
    getDeviceBadgeTitle('Local', { deviceUrl: 'ws://127.0.0.1:9900/ws' }),
    'Local (ws://127.0.0.1:9900/ws)',
  );
  assert.equal(
    getDeviceBadgeTitle('Windows 5090 · 安卓 APP', { deviceUrl: 'ws://192.168.31.110:9900/ws' }),
    'Windows 5090 · 安卓 APP (ws://192.168.31.110:9900/ws)',
  );
  assert.equal(
    getDeviceBadgeTitle('127.0.0.1:9900', { deviceUrl: '' }),
    '127.0.0.1:9900',
  );
  assert.equal(
    getDeviceBadgeTitle('', { deviceUrl: 'ws://remote:9900/ws' }),
    'ws://remote:9900/ws',
  );
});

test('Issue #312: SpacesList completely hides badges in single-host mode (multiDevice=false)', () => {
  const mockSpaces = [
    {
      key: 'local::/home/user/tmux',
      name: 'tmux桌面端',
      count: 3,
      workingCount: 1,
      deviceName: '127.0.0.1:9900',
      deviceLocal: true,
      deviceUrl: 'ws://127.0.0.1:9900/ws',
    },
    {
      key: 'local::/home/user/repo2',
      name: '双基底',
      count: 2,
      workingCount: 0,
      deviceName: '127.0.0.1:9900',
      deviceLocal: true,
      deviceUrl: 'ws://127.0.0.1:9900/ws',
    },
  ];

  const html = renderToStaticMarkup(
    createElement(SpacesList, {
      spaces: mockSpaces,
      allCount: 5,
      allWorkingCount: 1,
      favCount: 0,
      selected: 'all',
      onSelect: () => {},
      onContextMenu: () => {},
      multiDevice: false,
    }),
  );

  // 单主机模式下：行内必须完全隐去 spaces-badge，绝不占用视口空间
  assert.doesNotMatch(html, /class="[^"]*spaces-badge[^"]*"/);
  assert.doesNotMatch(html, /127\.0\.0\.1:9900/);
  assert.match(html, /tmux桌面端/);
  assert.match(html, /双基底/);
});

test('Issue #312: SpacesList renders compact badge with title tooltip in multi-host mode (multiDevice=true)', () => {
  const mockSpaces = [
    {
      key: 'local::/home/user/tmux',
      name: 'tmux桌面端',
      count: 3,
      workingCount: 1,
      deviceName: '127.0.0.1:9900',
      deviceLocal: true,
      deviceUrl: 'ws://127.0.0.1:9900/ws',
    },
    {
      key: 'remote::/home/user/app',
      name: '安卓 APP',
      count: 2,
      workingCount: 0,
      deviceName: 'Windows 5090 · 安卓 APP',
      deviceLocal: false,
      deviceUrl: 'ws://192.168.31.110:9900/ws',
    },
  ];

  const html = renderToStaticMarkup(
    createElement(SpacesList, {
      spaces: mockSpaces,
      allCount: 5,
      allWorkingCount: 1,
      favCount: 0,
      selected: 'all',
      onSelect: () => {},
      onContextMenu: () => {},
      multiDevice: true,
    }),
  );

  // 多主机模式下渲染紧凑胶囊并携带完整 hover title 提示
  assert.match(html, /class="spaces-badge is-local"[^>]*title="127\.0\.0\.1:9900 \(ws:\/\/127\.0\.0\.1:9900\/ws\)"[^>]*>Local<\/span>/);
  assert.match(html, /class="spaces-badge"[^>]*title="Windows 5090 · 安卓 APP \(ws:\/\/192\.168\.31\.110:9900\/ws\)"[^>]*>5090<\/span>/);
  assert.doesNotMatch(html, />127\.0\.0\.1:9900</);
});

test('Issue #312: AgentsList completely hides badges in single-host mode (multiDevice=false)', () => {
  const mockAgents = [
    {
      key: 'local::%0',
      title: '桌面端leader',
      provider: 'codex',
      state: 'working',
      fav: true,
      spaceName: 'tmux桌面端',
      deviceName: '127.0.0.1:9900',
      deviceLocal: true,
      deviceUrl: 'ws://127.0.0.1:9900/ws',
    },
    {
      key: 'local::%1',
      title: 'frontend-dev',
      provider: 'codex',
      state: 'idle',
      fav: false,
      spaceName: 'tmux桌面端',
      deviceName: '127.0.0.1:9900',
      deviceLocal: true,
      deviceUrl: 'ws://127.0.0.1:9900/ws',
    },
  ];

  const html = renderToStaticMarkup(
    createElement(AgentsList, {
      agents: mockAgents,
      openKeys: ['local::%0'],
      activeUid: 'local::%0',
      closing: {},
      onOpen: () => {},
      onContextMenu: () => {},
      multiDevice: false,
    }),
  );

  // 单主机模式下：行内完全隐去 agents-badge，100% 宽度给会话名
  assert.doesNotMatch(html, /class="[^"]*agents-badge[^"]*"/);
  assert.doesNotMatch(html, /127\.0\.0\.1:9900/);
  assert.match(html, /桌面端leader/);
  assert.match(html, /frontend-dev/);
});

test('Issue #312: AgentsList renders compact badge with title tooltip in multi-host mode (multiDevice=true)', () => {
  const mockAgents = [
    {
      key: 'local::%0',
      title: '桌面端leader',
      provider: 'codex',
      state: 'working',
      fav: true,
      spaceName: 'tmux桌面端',
      deviceName: '127.0.0.1:9900',
      deviceLocal: true,
      deviceUrl: 'ws://127.0.0.1:9900/ws',
    },
    {
      key: 'remote::%1',
      title: 'android-runner',
      provider: 'codex',
      state: 'idle',
      fav: false,
      spaceName: '安卓 APP',
      deviceName: 'Windows 5090 · 安卓 APP',
      deviceLocal: false,
      deviceUrl: 'ws://192.168.31.110:9900/ws',
    },
  ];

  const html = renderToStaticMarkup(
    createElement(AgentsList, {
      agents: mockAgents,
      openKeys: ['local::%0'],
      activeUid: 'local::%0',
      closing: {},
      onOpen: () => {},
      onContextMenu: () => {},
      multiDevice: true,
    }),
  );

  // 多主机模式下渲染紧凑胶囊并携带完整 hover title 提示
  assert.match(html, /class="agents-badge is-local"[^>]*title="127\.0\.0\.1:9900 \(ws:\/\/127\.0\.0\.1:9900\/ws\)"[^>]*>Local<\/span>/);
  assert.match(html, /class="agents-badge"[^>]*title="Windows 5090 · 安卓 APP \(ws:\/\/192\.168\.31\.110:9900\/ws\)"[^>]*>5090<\/span>/);
  assert.doesNotMatch(html, />127\.0\.0\.1:9900</);
});

test('Issue #312: CSS contract enforces max-width 64px and ellipsis on both sidebar badges', async () => {
  const css = await readFile(new URL('../src/components/sidebar/sidebar.css', import.meta.url), 'utf8');

  // Spaces badge contract
  assert.match(css, /\.spaces-badge\s*\{[^}]*max-width:\s*64px;/);
  assert.match(css, /\.spaces-badge\s*\{[^}]*text-overflow:\s*ellipsis;/);
  assert.match(css, /\.spaces-badge\s*\{[^}]*flex-shrink:\s*0;/);

  // Agents badge contract
  assert.match(css, /\.agents-badge\s*\{[^}]*max-width:\s*64px;/);
  assert.match(css, /\.agents-badge\s*\{[^}]*text-overflow:\s*ellipsis;/);
  assert.match(css, /\.agents-badge\s*\{[^}]*flex-shrink:\s*0;/);

  // Empty marks hygiene
  assert.match(css, /\.agents-row-marks:empty\s*\{[^}]*display:\s*none;/);
});

test('Issue #312: App.jsx derives multiDevice based on active device count and mixed workspaces', async () => {
  const appCode = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // App must evaluate activeDevices, checkedDevices, and distinctWorkspaceDevices
  assert.match(appCode, /const checkedDevices = useMemo\(\(\) => devices\.filter\(\(d\) => d\.checked\)/);
  assert.match(appCode, /const activeDevices = useMemo\(\(\) => checkedDevices\.filter\(\(d\) => d\.state === 'ready'\)/);
  assert.match(appCode, /const distinctWorkspaceDevices = useMemo\(\(\) => new Set\(workspaces\.map\(\(w\) => w\.deviceId\)\)\.size/);
  assert.match(appCode, /const multiDevice = isMultiDeviceEnv && \(activeDevices\.length > 1 \|\| distinctWorkspaceDevices > 1\)/);
});
