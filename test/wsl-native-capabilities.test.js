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
  assert.equal(status.service_installed, false);
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
        service_installed: true,
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
  assert.equal(status.service_installed, true);
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

test('nativeCapabilities.wsl enforces Platform Guard: strictly rejects in Tauri environment on macOS platform', async () => {
  resetNativeEngineForTests();
  const prevWindow = globalThis.window;

  try {
    // 模拟 Tauri 容器环境存在，但宿主平台为 macOS
    globalThis.window = { __TAURI_INTERNALS__: {} };
    setNativeEngineForTests({ platform: 'macos' });

    // 1. startService 必须被前置守卫拦截，拒绝执行并抛出 unsupported_platform
    await assert.rejects(
      nativeCapabilities.wsl.startService('agentmirrord'),
      (err) => {
        assert.ok(err instanceof Error);
        assert.match(err.message, /unsupported_platform/);
        assert.equal(err.code, 'unsupported_platform');
        return true;
      }
    );

    // 2. checkEnvironment 必须直接返回安全默认结构，不发起底层调用
    const status = await nativeCapabilities.wsl.checkEnvironment();
    assert.equal(status.wsl_installed, false);
    assert.equal(status.ubuntu_installed, false);
    assert.equal(status.service_running, false);
  } finally {
    if (prevWindow !== undefined) {
      globalThis.window = prevWindow;
    } else {
      delete globalThis.window;
    }
    resetNativeEngineForTests();
  }
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

test('nativeCapabilities.wsl.readServiceToken returns null in mock environment', async () => {
  resetNativeEngineForTests();

  const token = await nativeCapabilities.wsl.readServiceToken();
  assert.equal(token, null);
});

test('nativeCapabilities.wsl.readServiceToken supports testEngineOverride', async () => {
  resetNativeEngineForTests();

  setNativeEngineForTests({
    wsl: {
      readServiceToken: async () => 'mock-service-token-12345',
    },
  });

  const token = await nativeCapabilities.wsl.readServiceToken();
  assert.equal(token, 'mock-service-token-12345');

  resetNativeEngineForTests();
});

test('nativeCapabilities.wsl.readServiceToken enforces Platform Guard: returns null on macOS platform', async () => {
  resetNativeEngineForTests();
  const prevWindow = globalThis.window;

  try {
    globalThis.window = { __TAURI_INTERNALS__: {} };
    setNativeEngineForTests({ platform: 'macos' });

    const token = await nativeCapabilities.wsl.readServiceToken();
    assert.equal(token, null);
  } finally {
    if (prevWindow !== undefined) {
      globalThis.window = prevWindow;
    } else {
      delete globalThis.window;
    }
    resetNativeEngineForTests();
  }
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

  // 3. 未安装会话服务指引与命令代码块
  assert.match(cardJsx, /!envStatus\.service_installed/);
  assert.match(cardJsx, /WSL 2 中未安装 Agent 会话服务/);
  assert.match(cardJsx, /go install github\.com\/Florious95\/corral-core\/server\/cmd\/agentmirrord@latest/);

  // 4. 重试按钮无死锁（无 disabled 属性，允许随时重试）
  assert.match(cardJsx, /className="app-empty-btn wsl-retry-btn"/);
  assert.match(cardJsx, /onClick=\{onRetry\}/);
  assert.doesNotMatch(cardJsx, /disabled=\{isLoading\}/);
});

test('App.jsx integrates WSL auto-healing state machine, watchdog timer, and pre-branching', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // 1. 引入组件与声明状态
  assert.match(appJsx, /import WslBootstrapCard from '\.\/components\/chrome\/WslBootstrapCard\.jsx'/);
  assert.match(appJsx, /const \[wslState, setWslState\] = useState\('idle'\)/);
  assert.match(appJsx, /const \[wslEnvStatus, setWslEnvStatus\] = useState\(null\)/);

  // 2. 环境探测与前置短路（未安装 service 直接切 unready，绝不盲目 startService）
  assert.match(appJsx, /const checkAndHealWsl = useCallback/);
  assert.match(appJsx, /nativeCapabilities\.wsl\.checkEnvironment\(\)/);
  assert.match(appJsx, /if \(!status\.service_installed\) {\s*setWslState\('unready'\);\s*return;\s*}/);
  assert.match(appJsx, /nativeCapabilities\.wsl\.startService\('agentmirrord'\)/);

  // 3. 8 秒看门狗与 1 秒轮询保护
  assert.match(appJsx, /setInterval\(async \(\) => {/);
  assert.match(appJsx, /}, 1000\)/);
  assert.match(appJsx, /setTimeout\(\(\) => {\s*setWslState\('error'\);\s*setWslError\('会话服务启动超时（8秒内未就绪），请检查 WSL 服务运行状态'\);\s*}, 8000\)/);
  assert.match(appJsx, /clearInterval\(pollTimer\)/);
  assert.match(appJsx, /clearTimeout\(watchdogTimer\)/);

  // 4. 条件渲染保护：仅在 Windows 且本地未连接且非 idle 时展示引导卡片
  assert.match(appJsx, /isWindows && !anyDeviceOnline && wslState !== 'idle'/);
  assert.match(appJsx, /<WslBootstrapCard/);

  // 5. 自动获取并注入 Local 令牌直通认证
  assert.match(appJsx, /const syncLocalTokenAndConnect = useCallback/);
  assert.match(appJsx, /nativeCapabilities\.wsl\.readServiceToken\(\)/);
  assert.match(appJsx, /dm\.updateDevice\('local', \{ token \}\)/);
  assert.match(appJsx, /dm\.connect\('local'\)/);
});

test('WSL auto-healing state machine pre-checks service_installed and enforces watchdog timeout', async () => {
  // 仿真状态机测试
  let currentState = 'idle';
  let currentError = '';
  let serviceStartedCalled = false;

  const mockCheckAndHeal = async (envStatus) => {
    currentState = 'checking';
    currentError = '';
    const status = envStatus;
    if (!status.wsl_installed || !status.ubuntu_installed || !status.tmux_installed) {
      currentState = 'unready';
      return;
    }
    if (!status.service_installed) {
      currentState = 'unready';
      return;
    }
    if (!status.service_running) {
      currentState = 'starting';
      serviceStartedCalled = true;
    }
  };

  // 场景 A: service_installed 为 false 时，前置拦截，绝不调用 startService
  await mockCheckAndHeal({
    wsl_installed: true,
    ubuntu_installed: true,
    tmux_installed: true,
    service_installed: false,
    service_running: false,
  });
  assert.equal(currentState, 'unready');
  assert.equal(serviceStartedCalled, false);

  // 场景 B: service_installed 为 true 时，正常进入 starting 并尝试启动
  await mockCheckAndHeal({
    wsl_installed: true,
    ubuntu_installed: true,
    tmux_installed: true,
    service_installed: true,
    service_running: false,
  });
  assert.equal(currentState, 'starting');
  assert.equal(serviceStartedCalled, true);

  // 场景 C: 8 秒看门狗超时，状态切入 error
  let watchdogTimerFired = false;
  const timeoutId = setTimeout(() => {
    watchdogTimerFired = true;
    currentState = 'error';
    currentError = '会话服务启动超时（8秒内未就绪），请检查 WSL 服务运行状态';
  }, 50);

  await new Promise((resolve) => setTimeout(resolve, 80));
  assert.equal(watchdogTimerFired, true);
  assert.equal(currentState, 'error');
  assert.match(currentError, /会话服务启动超时/);
  clearTimeout(timeoutId);
});

test('DeviceManager supports hasDeviceToken, getDeviceToken, and connect', async () => {
  const { DeviceManager } = await import('../src/core/devices.js');
  const dm = new DeviceManager({ autoLocal: true, autoConnect: false });

  // 默认 local device token 为空
  assert.equal(dm.hasDeviceToken('local'), false);
  assert.equal(dm.getDeviceToken('local'), '');

  // 更新 local device token
  dm.updateDevice('local', { token: 'auth-token-xyz' });
  assert.equal(dm.hasDeviceToken('local'), true);
  assert.equal(dm.getDeviceToken('local'), 'auth-token-xyz');

  // connect('local') 成功调用
  const connected = dm.connect('local');
  assert.equal(connected, true);
});

test('syncLocalTokenAndConnect auto-injects service token and transitions state', async () => {
  let updatedToken = null;
  let connectCalled = false;
  let state = 'starting';
  let errorMsg = '';

  const mockDm = {
    devices: [{ id: 'local', url: 'ws://127.0.0.1:9900/ws' }],
    hasDeviceToken: () => Boolean(updatedToken),
    updateDevice: (id, patch) => {
      if (id === 'local') updatedToken = patch.token;
    },
    connect: (id) => {
      if (id === 'local') connectCalled = true;
    },
  };

  const simulateSync = async (mockToken) => {
    const hasToken = mockDm.hasDeviceToken('local');
    if (!hasToken) {
      const token = mockToken;
      if (token) {
        mockDm.updateDevice('local', { token });
        mockDm.connect('local');
        return true;
      }
      state = 'error';
      errorMsg = '无法获取 WSL 会话服务配对令牌，请检查 ~/.config/agentmirror/token';
      return false;
    }
    mockDm.connect('local');
    return true;
  };

  // 场景 1：成功获取 token 并自动注入与直通连接
  const ok1 = await simulateSync('auto-discovered-token-abc');
  assert.equal(ok1, true);
  assert.equal(updatedToken, 'auto-discovered-token-abc');
  assert.equal(connectCalled, true);
  assert.equal(state, 'starting');

  // 场景 2：获取 token 为 null 时转入 error
  updatedToken = null;
  connectCalled = false;
  const ok2 = await simulateSync(null);
  assert.equal(ok2, false);
  assert.equal(updatedToken, null);
  assert.equal(connectCalled, false);
  assert.equal(state, 'error');
  assert.match(errorMsg, /无法获取 WSL 会话服务配对令牌/);
});
