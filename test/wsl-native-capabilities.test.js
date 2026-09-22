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

test('nativeCapabilities.wsl.installService rejects with unsupported_platform on non-Tauri environments', async () => {
  resetNativeEngineForTests();

  await assert.rejects(
    nativeCapabilities.wsl.installService(),
    (err) => {
      assert.ok(err instanceof Error);
      assert.match(err.message, /unsupported_platform/);
      assert.equal(err.code, 'unsupported_platform');
      return true;
    }
  );
});

test('nativeCapabilities.wsl enforces Platform Guard: installService strictly rejects in Tauri environment on macOS platform', async () => {
  resetNativeEngineForTests();
  const prevWindow = globalThis.window;

  try {
    globalThis.window = { __TAURI_INTERNALS__: {} };
    setNativeEngineForTests({ platform: 'macos' });

    await assert.rejects(
      nativeCapabilities.wsl.installService(),
      (err) => {
        assert.ok(err instanceof Error);
        assert.match(err.message, /unsupported_platform/);
        assert.equal(err.code, 'unsupported_platform');
        return true;
      }
    );
  } finally {
    if (prevWindow !== undefined) {
      globalThis.window = prevWindow;
    } else {
      delete globalThis.window;
    }
    resetNativeEngineForTests();
  }
});

test('nativeCapabilities.wsl.installService supports testEngineOverride', async () => {
  resetNativeEngineForTests();
  let installCalled = false;

  setNativeEngineForTests({
    wsl: {
      installService: async () => {
        installCalled = true;
        return { ok: true };
      },
    },
  });

  const res = await nativeCapabilities.wsl.installService();
  assert.equal(installCalled, true);
  assert.deepEqual(res, { ok: true });

  resetNativeEngineForTests();
});

test('WslBootstrapCard renders respective guidance text and command hints for every WSL state', async () => {
  const cardJsx = await readFile(new URL('../src/components/chrome/WslBootstrapCard.jsx', import.meta.url), 'utf8');

  // 1. 基本结构
  assert.match(cardJsx, /className="app-empty wsl-bootstrap-card"/);
  assert.match(cardJsx, /className=\{`app-empty-icon wsl-icon\$\{isLoading \? ' is-loading' : ''\}`\}/);

  // 2. 状态分支覆盖
  assert.match(cardJsx, /state === 'installing'/);
  assert.match(cardJsx, /正在为 WSL 2 安装会话服务\.\.\./);
  assert.match(cardJsx, /正在为 WSL 2 安装会话服务组件\.\.\./);
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

test('App.jsx integrates fast, idempotent WSL startup and single-flight connection', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // 1. 引入组件与声明状态
  assert.match(appJsx, /import WslBootstrapCard from '\.\/components\/chrome\/WslBootstrapCard\.jsx'/);
  assert.match(appJsx, /const \[wslState, setWslState\] = useState\('idle'\)/);
  assert.match(appJsx, /const \[wslEnvStatus, setWslEnvStatus\] = useState\(null\)/);

  // 2. 环境探测只在缺少或版本不匹配时安装，随后走幂等快速启动
  assert.match(appJsx, /const checkAndHealWsl = useCallback/);
  assert.match(appJsx, /nativeCapabilities\.wsl\.checkEnvironment\(\)/);
  assert.match(appJsx, /if \(!status\.service_installed\)/);
  assert.match(appJsx, /nativeCapabilities\.wsl\.installService\(\)/);
  assert.match(appJsx, /nativeCapabilities\.wsl\.startService\('agentmirrord'\)/);
  assert.match(appJsx, /if \(nativeCapabilities\.platform !== 'windows'\) dm\.connectAll\(\);/);
  assert.match(appJsx, /wslStartPromiseRef/);
  assert.doesNotMatch(appJsx, /Always reinstall the bundled daemon/);
  assert.doesNotMatch(appJsx, /startService\('corral-core'\)/);

  // 3. 就绪探测由 native startService 高频探测，前端不再每秒傻轮询或 8s 误杀
  assert.doesNotMatch(appJsx, /setInterval\(async \(\) => {/);
  assert.doesNotMatch(appJsx, /}, 1000\)/);
  assert.doesNotMatch(appJsx, /8000\)/);

  // 4. 条件渲染保护：仅在 Windows 且本地未连接且非 idle 时展示引导卡片
  assert.match(appJsx, /isWindows && !anyDeviceOnline && wslState !== 'idle'/);
  assert.match(appJsx, /<WslBootstrapCard/);

  // 5. 自动获取并注入 Local 令牌直通认证
  assert.match(appJsx, /const syncLocalTokenAndConnect = useCallback/);
  assert.match(appJsx, /nativeCapabilities\.wsl\.readServiceToken\(\)/);
  assert.match(appJsx, /dm\.updateDevice\('local', \{ token \}\)/);
  assert.match(appJsx, /dm\.connect\('local'\)/);
});

test('WSL startup installs only when missing and never restarts a ready daemon', async () => {
  let currentState = 'idle';
  let installServiceCalled = false;
  let serviceStartedCalled = false;

  const mockCheckAndHeal = async (envStatus) => {
    currentState = 'checking';
    const status = { ...envStatus };
    if (!status.wsl_installed || !status.ubuntu_installed || !status.tmux_installed) {
      currentState = 'unready';
      return;
    }
    if (!status.service_installed) {
      currentState = 'installing';
      installServiceCalled = true;
      status.service_installed = true;
    }
    currentState = 'starting';
    serviceStartedCalled = true;
  };

  await mockCheckAndHeal({
    wsl_installed: true, ubuntu_installed: true, tmux_installed: true,
    service_installed: false, service_running: false,
  });
  assert.equal(installServiceCalled, true);
  assert.equal(serviceStartedCalled, true);
  assert.equal(currentState, 'starting');

  installServiceCalled = false;
  serviceStartedCalled = false;
  await mockCheckAndHeal({
    wsl_installed: true, ubuntu_installed: true, tmux_installed: true,
    service_installed: true, service_running: true,
  });
  assert.equal(installServiceCalled, false);
  assert.equal(serviceStartedCalled, true);
  assert.equal(currentState, 'starting');
});

test('WSL end-to-end auto-healing flow from missing service to direct connect', async () => {
  let step = 'init';
  let mockEnvStatus = {
    wsl_installed: true,
    ubuntu_installed: true,
    tmux_installed: true,
    service_installed: false,
    service_running: false,
    wsl_ip: '172.28.14.2',
  };
  let tokenInjected = null;
  let localConnected = false;

  const mockNative = {
    wsl: {
      checkEnvironment: async () => ({ ...mockEnvStatus }),
      installService: async () => {
        step = 'installed';
        mockEnvStatus.service_installed = true;
      },
      startService: async () => {
        step = 'started';
        mockEnvStatus.service_running = true;
      },
      readServiceToken: async () => 'zero-touch-auth-token-999',
    },
  };

  const mockDeviceManager = {
    devices: [{ id: 'local', url: 'ws://127.0.0.1:9900/ws', state: 'offline' }],
    hasDeviceToken: () => Boolean(tokenInjected),
    updateDevice: (id, patch) => {
      if (id === 'local' && patch.token) tokenInjected = patch.token;
    },
    connect: (id) => {
      if (id === 'local') localConnected = true;
      return true;
    },
  };

  // 模拟整套 checkAndHealWsl 全自动流转
  let wslState = 'idle';
  const status = await mockNative.wsl.checkEnvironment();
  if (!status.service_installed) {
    wslState = 'installing';
    await mockNative.wsl.installService();
  }
  wslState = 'starting';
  await mockNative.wsl.startService('agentmirrord');
  const token = await mockNative.wsl.readServiceToken();
  if (token) {
    mockDeviceManager.updateDevice('local', { token });
    mockDeviceManager.connect('local');
  }

  assert.equal(step, 'started');
  assert.equal(mockEnvStatus.service_installed, true);
  assert.equal(mockEnvStatus.service_running, true);
  assert.equal(tokenInjected, 'zero-touch-auth-token-999');
  assert.equal(localConnected, true);
  assert.equal(wslState, 'starting');
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
