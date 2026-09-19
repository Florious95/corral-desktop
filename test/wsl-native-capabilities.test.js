import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import {
  nativeCapabilities,
  setNativeEngineForTests,
  resetNativeEngineForTests,
} from '../src/core/nativeCapabilities.js';

test('nativeCapabilities.wsl.checkEnvironment returns safe default status structure in mock environment', async () => {
  resetNativeEngineForTests();

  const status = await nativeCapabilities.wsl.checkEnvironment();
  assert.ok(typeof status === 'object' && status !== null);
  assert.equal(status.wsl_installed, false);
  assert.equal(status.ubuntu_installed, false);
  assert.equal(status.ubuntu_running, false);
  assert.equal(status.tmux_installed, false);
  assert.equal(status.service_running, false);
  assert.equal(status.wsl_ip, null);
});

test('nativeCapabilities.wsl.checkEnvironment supports testEngineOverride with complete fields', async () => {
  resetNativeEngineForTests();

  setNativeEngineForTests({
    wsl: {
      checkEnvironment: async () => ({
        wsl_installed: true,
        ubuntu_installed: true,
        ubuntu_running: true,
        tmux_installed: true,
        service_running: false,
        wsl_ip: '172.28.14.2',
      }),
    },
  });

  const status = await nativeCapabilities.wsl.checkEnvironment();
  assert.equal(status.wsl_installed, true);
  assert.equal(status.ubuntu_installed, true);
  assert.equal(status.ubuntu_running, true);
  assert.equal(status.tmux_installed, true);
  assert.equal(status.service_running, false);
  assert.equal(status.wsl_ip, '172.28.14.2');

  resetNativeEngineForTests();
});

test('nativeCapabilities.wsl.startService rejects with unsupported_platform on non-Tauri environments', async () => {
  resetNativeEngineForTests();

  await assert.rejects(
    nativeCapabilities.wsl.startService('agentmirrord'),
    (err) => {
      assert.ok(err instanceof Error);
      assert.match(err.message, /unsupported_platform/);
      assert.equal(err.code, 'unsupported_platform');
      return true;
    }
  );
});

test('nativeCapabilities.wsl.startService forwards serviceName via testEngineOverride', async () => {
  resetNativeEngineForTests();
  let requestedService = null;

  setNativeEngineForTests({
    wsl: {
      startService: async (name) => {
        requestedService = name;
        return { ok: true };
      },
    },
  });

  const res = await nativeCapabilities.wsl.startService('corral-core');
  assert.equal(requestedService, 'corral-core');
  assert.deepEqual(res, { ok: true });

  resetNativeEngineForTests();
});

test('WslBootstrapCard renders respective guidance text and command hints for every WSL state', async () => {
  const cardJsx = await readFile(new URL('../src/components/chrome/WslBootstrapCard.jsx', import.meta.url), 'utf8');

  // 1. 基本结构
  assert.match(cardJsx, /className="app-empty wsl-bootstrap-card"/);
  assert.match(cardJsx, /className=\{`app-empty-icon wsl-icon\$\{isLoading \? ' is-loading' : ''\}`\}/);

  // 2. 状态分支覆盖
  assert.match(cardJsx, /state === 'starting'/);
  assert.match(cardJsx, /正在唤醒 WSL 2 会话服务\.\.\./);
  assert.match(cardJsx, /state === 'unready'/);
  assert.match(cardJsx, /WSL 2 会话环境未就绪/);
  assert.match(cardJsx, /wsl --install/);
  assert.match(cardJsx, /wsl --install -d Ubuntu/);
  assert.match(cardJsx, /sudo apt-get install -y tmux/);

  // 3. 重试按钮
  assert.match(cardJsx, /className="app-empty-btn wsl-retry-btn"/);
  assert.match(cardJsx, /onClick=\{onRetry\}/);
});

test('App.jsx integrates WSL auto-healing state machine and conditionally mounts WslBootstrapCard', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // 1. 引入组件与声明状态
  assert.match(appJsx, /import WslBootstrapCard from '\.\/components\/chrome\/WslBootstrapCard\.jsx'/);
  assert.match(appJsx, /const \[wslState, setWslState\] = useState\('idle'\)/);
  assert.match(appJsx, /const \[wslEnvStatus, setWslEnvStatus\] = useState\(null\)/);

  // 2. 环境探测与自愈逻辑
  assert.match(appJsx, /const checkAndHealWsl = useCallback/);
  assert.match(appJsx, /nativeCapabilities\.wsl\.checkEnvironment\(\)/);
  assert.match(appJsx, /nativeCapabilities\.wsl\.startService\('agentmirrord'\)/);

  // 3. 条件渲染保护：仅在 Windows 且本地未连接且非 idle 时展示引导卡片
  assert.match(appJsx, /isWindows && !anyDeviceOnline && wslState !== 'idle'/);
  assert.match(appJsx, /<WslBootstrapCard/);
});
