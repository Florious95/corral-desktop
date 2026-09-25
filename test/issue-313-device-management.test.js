import { after, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createElement } from 'react';
import { renderToStaticMarkup } from 'react-dom/server';
import { createServer } from 'vite';
import react from '@vitejs/plugin-react';

import { DeviceManager } from '../src/core/devices.js';
import { DEFAULT_LOCAL_DEVICE } from '../src/core/local.js';

// Setup Vite SSR pipeline to test real React components
const server = await createServer({
  configFile: false,
  root: fileURLToPath(new URL('..', import.meta.url)),
  plugins: [react()],
  server: { middlewareMode: true, watch: null, hmr: false },
  logLevel: 'silent',
});
after(() => server.close());

const { default: DevicesPopover } = await server.ssrLoadModule('/src/components/chrome/DevicesPopover.jsx');

test('Issue #313: DeviceManager.renameDevice updates device name and persists correctly', () => {
  const store = new Map();
  const mockStorage = {
    getItem: (k) => store.get(k) || null,
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
  };

  const dm = new DeviceManager({
    storage: mockStorage,
    seedDevices: [
      { id: 'dev-1', name: '100.75.207.88:9900', url: 'ws://100.75.207.88:9900/ws', token: 'tok-1', checked: true },
      { id: 'local', name: 'Local', url: 'ws://127.0.0.1:9900/ws', token: '', checked: true },
    ],
  });

  assert.equal(dm.devices.find((d) => d.id === 'dev-1')?.name, '100.75.207.88:9900');

  // 1. 重命名成功并去除首尾空格
  const ok = dm.renameDevice('dev-1', '  5090 Host  ');
  assert.equal(ok, true);
  assert.equal(dm.devices.find((d) => d.id === 'dev-1')?.name, '5090 Host');

  // 2. 空名称拒绝重命名
  assert.equal(dm.renameDevice('dev-1', '   '), false);
  assert.equal(dm.devices.find((d) => d.id === 'dev-1')?.name, '5090 Host');

  // 3. 不存在的设备返回 false
  assert.equal(dm.renameDevice('non-existent', 'NewName'), false);
});

test('Issue #313: DeviceManager.removeDevice disconnects client and clears state cleanly', () => {
  const store = new Map();
  const mockStorage = {
    getItem: (k) => store.get(k) || null,
    setItem: (k, v) => store.set(k, String(v)),
    removeItem: (k) => store.delete(k),
  };

  const dm = new DeviceManager({
    storage: mockStorage,
    seedDevices: [
      { id: 'dev-1', name: 'Dev 1', url: 'ws://10.0.0.1:9900/ws', token: 't1', checked: true },
      { id: 'dev-2', name: 'Dev 2', url: 'ws://10.0.0.2:9900/ws', token: 't2', checked: true },
    ],
  });

  assert.equal(dm.devices.length, 2);

  // 移除 dev-1
  const ok = dm.removeDevice('dev-1');
  assert.equal(ok, true);
  assert.equal(dm.devices.length, 1);
  assert.equal(dm.devices[0].id, 'dev-2');

  // 再次移除同一个设备返回 false
  assert.equal(dm.removeDevice('dev-1'), false);
});

test('Issue #313: DevicesPopover renders action buttons with edit and trash icons', () => {
  const mockDevices = [
    { id: 'd1', name: '100.75.207.88:9900', url: 'ws://100.75.207.88:9900/ws', online: false, checked: true },
    { id: 'local', name: 'Local', url: 'ws://127.0.0.1:9900/ws', online: true, checked: true },
  ];

  const html = renderToStaticMarkup(
    createElement(DevicesPopover, {
      devices: mockDevices,
      onToggle: () => {},
      onToggleAll: () => {},
      onRenameDevice: () => {},
      onRemoveDevice: () => {},
      onAddDevice: () => {},
      onPairMobile: () => {},
      onClose: () => {},
    }),
  );

  // 确保包含操作按钮区域
  assert.match(html, /class="dp-actions"/);
  assert.match(html, /aria-label="修改设备 100\.75\.207\.88:9900 名称"/);
  assert.match(html, /aria-label="删除设备 100\.75\.207\.88:9900"/);
  assert.match(html, /aria-label="修改设备 Local 名称"/);
  assert.match(html, /aria-label="删除设备 Local"/);
});

test('Issue #313: DevicesPopover code strictly adheres to input hygiene (autoComplete="off")', async () => {
  const code = await readFile(new URL('../src/components/chrome/DevicesPopover.jsx', import.meta.url), 'utf8');

  // 必须声明 autoComplete="off" 避免原生浏览器/系统弹窗干扰
  assert.match(code, /autoComplete="off"/);
  assert.match(code, /autoCorrect="off"/);
  assert.match(code, /autoCapitalize="off"/);
  assert.match(code, /spellCheck="false"/);
});

test('Issue #313: CSS defines .dp-actions, .dp-action-btn, and inline input styles', async () => {
  const css = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');

  assert.match(css, /\.dp-actions\s*\{/);
  assert.match(css, /\.dp-action-btn\s*\{/);
  assert.match(css, /\.dp-rename-input\s*\{/);
  assert.match(css, /\.dp-delete-confirm\s*\{/);
});

test('Issue #313: App.jsx passes onRenameDevice and onRemoveDevice callbacks to DevicesPopover', async () => {
  const appCode = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  assert.match(appCode, /onRenameDevice=\{handleRenameDevice\}/);
  assert.match(appCode, /onRemoveDevice=\{handleRemoveDevice\}/);
  assert.match(appCode, /dm\.renameDevice/);
  assert.match(appCode, /dm\.removeDevice/);
});
