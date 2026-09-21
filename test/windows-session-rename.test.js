import { test } from 'node:test';
import assert from 'node:assert/strict';
import { DeviceManager } from '../src/core/devices.js';
import { isSameSpaceKey, normalizeCwd } from '../src/lib/wslPath.js';

test('isSameSpaceKey accurately identifies Windows drive path and WSL POSIX path equivalence', () => {
  assert.equal(
    isSameSpaceKey('local::C:\\Users\\AlaudaLancy', 'local::/mnt/c/Users/AlaudaLancy'),
    true,
    'Windows drive path and WSL POSIX mount path must match',
  );
  assert.equal(
    isSameSpaceKey('local::c:/users/alaudalancy/repo', 'local::/mnt/c/users/alaudalancy/repo'),
    true,
    'Forward-slash Windows path must match WSL POSIX path',
  );
  assert.equal(
    isSameSpaceKey('local::\\\\wsl.localhost\\Ubuntu\\home\\foo', 'local::/home/foo'),
    true,
    'WSL UNC path and Linux home path must match',
  );
  assert.equal(
    isSameSpaceKey('local::/mnt/c/Users/AlaudaLancy', 'local::/mnt/c/Users/AlaudaLancy'),
    true,
    'Identical POSIX paths must match',
  );
  assert.equal(
    isSameSpaceKey('all', 'all'),
    true,
    'Virtual all spaces key must match',
  );
  assert.equal(
    isSameSpaceKey('all', 'fav'),
    false,
    'Different virtual spaces must not match',
  );
  assert.equal(
    isSameSpaceKey('dev1::/mnt/c/code', 'dev2::/mnt/c/code'),
    false,
    'Different devices with same path must never match',
  );
  assert.equal(
    isSameSpaceKey('local::/mnt/c/code1', 'local::/mnt/c/code2'),
    false,
    'Different paths on same device must not match',
  );
});

test('DeviceManager updates session name on list_delta changed_sessions in WSL environment', async () => {
  const events = { models: [] };
  const dm = new DeviceManager({
    storage: null,
    autoLocal: false,
    modelDebounceMs: 10,
    wsFactory: () => ({ readyState: 0, close() {}, send() {} }),
    onModelChange: (ws) => events.models.push(ws),
  });

  const devId = dm.addDevice({ name: 'Local', url: 'ws://127.0.0.1:9900/ws', token: 'test-token' });
  dm.connectAll();

  const client = dm._clients.get(devId);
  assert.ok(client, 'client must be spawned');

  const sessionRef = '/tmp/tmux-1000/ta-test\u001f%0';
  const initialListing = {
    req_id: 1,
    seq: 1,
    workspaces: [
      {
        cwd: '/mnt/c/Users/AlaudaLancy',
        session_count: 1,
        sessions: [
          {
            ref: sessionRef,
            name: 'my-initial-task',
            cwd: '/mnt/c/Users/AlaudaLancy',
            title: '',
            rows: 24,
            cols: 80,
            status: 'idle',
            provider: 'pi',
          },
        ],
      },
    ],
  };

  // 1. 模拟收到首帧 listing
  client.buildFromListing(initialListing);
  dm._onFrame(devId, 'listing', initialListing);

  // 等待 modelDebounce
  await new Promise((resolve) => setTimeout(resolve, 30));

  let currentWs = dm.workspaces;
  assert.equal(currentWs.length, 1);
  assert.equal(currentWs[0].sessions.length, 1);
  assert.equal(currentWs[0].sessions[0].name, 'my-initial-task');
  assert.equal(currentWs[0].sessions[0].rows, 24);
  assert.equal(currentWs[0].sessions[0].cols, 80);

  // 2. 模拟 5090 物理机收据：收到真实的 list_delta changed_sessions 重命名推送
  const deltaPayload = {
    seq: 2,
    changed_sessions: [
      {
        ref: sessionRef,
        name: 'my-renamed-task-2',
        cwd: '/mnt/c/Users/AlaudaLancy',
        title: '',
      },
    ],
  };

  client.applyDelta(deltaPayload);
  dm._onFrame(devId, 'list_delta', deltaPayload);

  await new Promise((resolve) => setTimeout(resolve, 30));

  currentWs = dm.workspaces;
  assert.equal(currentWs.length, 1);
  const updatedSession = currentWs[0].sessions[0];
  assert.equal(updatedSession.name, 'my-renamed-task-2', 'Session name must update to renamed title');
  assert.equal(updatedSession.rows, 24, 'Session rows must be preserved across delta');
  assert.equal(updatedSession.cols, 80, 'Session cols must be preserved across delta');

  // 3. 验证空间匹配：无论用户当前选中的是 Windows 盘符路径还是 WSL 路径，均能准确关联
  const winSelected = `${devId}::C:\\Users\\AlaudaLancy`;
  const posixSelected = `${devId}::/mnt/c/Users/AlaudaLancy`;
  const spaceKey = currentWs[0].spaceKey;

  assert.equal(isSameSpaceKey(spaceKey, winSelected), true, 'Space must match Windows drive key');
  assert.equal(isSameSpaceKey(spaceKey, posixSelected), true, 'Space must match POSIX key');
});
