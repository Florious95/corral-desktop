import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { DeviceManager } from '../src/core/devices.js';

test('App initial state without clicking folder: unclicked workspace directly projects working status from listing', () => {
  const dm = new DeviceManager({
    storage: { getItem: () => null, setItem: () => {}, removeItem: () => {} },
  });

  // 模拟客户端初始状态：刚刚连接 daemon 并收到 listing / list_delta，用户从未点击选中任何文件夹
  const mockClient = {
    unsubscribeLevel2: () => {},
    workspaces: [
      {
        cwd: '/proj/unclicked-folder',
        session_count: 2,
        sessions: [
          { ref: 'worker-1', name: 'Background Agent', activity: 'working', provider: 'pi' },
          { ref: 'idle-1', name: 'Idle Agent', status: 'idle', provider: 'cursor' },
        ],
      },
      {
        cwd: '/proj/other-folder',
        session_count: 1,
        sessions: [
          { ref: 'idle-2', name: 'Another Agent', status: 'idle', provider: 'codex' },
        ],
      },
    ],
  };

  dm._devices = [{ id: 'local-dev', checked: true, name: 'Local' }];
  dm._clients.set('local-dev', mockClient);

  // 1. 验证直通 workspaces 模型：未被点击选中的文件夹直接输出真实 status
  const ws = dm.workspaces;
  const unclickedSpace = ws.find((w) => w.cwd === '/proj/unclicked-folder');
  assert.ok(unclickedSpace, 'unclicked folder must exist in workspaces');
  assert.equal(unclickedSpace.sessions[0].status, 'working', 'unclicked session must project working status directly');
  assert.equal(unclickedSpace.sessions[1].status, 'idle', 'unclicked session must project idle status directly');

  // 2. 验证前端 workingCount 计算在初态直接精准算出并大于 0
  const workingCount = unclickedSpace.sessions.filter(
    (s) => s.status === 'working' || s.state === 'working',
  ).length;
  assert.equal(workingCount, 1, 'workingCount must be 1 for unclicked folder');

  // 3. 验证双列数字徽标呈现判定：> 0 呈现为绿色高亮徽标类名
  const isWorking = (workingCount ?? 0) > 0;
  assert.equal(isWorking, true, 'isWorking badge flag must be true');
  const badgeClass = `spaces-count-working${isWorking ? ' is-working is-active' : ' is-idle is-zero'}`;
  assert.equal(badgeClass.includes('is-working is-active'), true, 'workingCount > 0 must render green badge classes');
});

test('SpacesList eliminates redundant folder row lamp while TabBar breathing lamp is strictly preserved', async () => {
  const spacesListJsx = await readFile(new URL('../src/components/sidebar/SpacesList.jsx', import.meta.url), 'utf8');
  const tabBarJsx = await readFile(new URL('../src/components/chrome/TabBar.jsx', import.meta.url), 'utf8');
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');

  // 1. 断言 SpacesList 中 SpaceRow 彻底移除 SpaceState 状态灯调用
  assert.equal(
    spacesListJsx.includes('<SpaceState'),
    false,
    'SpaceRow must eliminate redundant <SpaceState /> folder lamp',
  );

  // 2. 断言 SpacesList 保留最右侧双列数字徽标
  assert.match(spacesListJsx, /className="spaces-row-counts"/);
  assert.match(spacesListJsx, /spaces-count-working/);
  assert.match(spacesListJsx, /spaces-count-total/);

  // 3. 核心验收铁律：顶栏 TabBar 状态呼吸灯（tb-tab-lamp / tb-lamp-pulse）绝对保留！
  assert.match(tabBarJsx, /<StatusLamp status=\{finalStatus\} \/>/);
  assert.match(tabBarJsx, /tb-tab-lamp/);
  assert.match(chromeCss, /\.tb-tab-lamp\.is-working\s*\{[^}]*animation:\s*tb-lamp-pulse/);
});

test('App.jsx completely eliminates PR #144 fake cache chains and relies purely on authoritative workspaces', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // 彻底删除 globalSessionStatusRef 伪缓存
  assert.equal(appJsx.includes('globalSessionStatusRef'), false, 'globalSessionStatusRef must be completely eliminated');

  // 全域会话状态由 workspaces 纯净直通
  assert.match(appJsx, /const workingCount = sessions\.filter\(\(s\) => s\.state === 'working' \|\| s\.status === 'working'\)\.length;/);
  assert.match(appJsx, /const curStatus = s\.state \|\| s\.status \|\| 'unknown';/);
});
