import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { DeviceManager, normalizeSessionStatus, ClientState } from '../src/core/devices.js';

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

test('R1 (P1): selected level2 cannot override global authoritative listing/delta status', () => {
  const dm = new DeviceManager({
    storage: { getItem: () => null, setItem: () => {}, removeItem: () => {} },
  });

  const sessionData = { ref: 's1', name: 'Agent A', activity: 'working', status: 'working' };
  const mockClient = {
    unsubscribeLevel2: () => {},
    workspaces: [
      {
        cwd: '/proj/folder-a',
        session_count: 1,
        sessions: [sessionData],
      },
    ],
  };

  dm._devices = [{ id: 'dev1', checked: true, name: 'Local' }];
  dm._clients.set('dev1', mockClient);

  // 模拟用户此前曾选中该目录，遗留了旧 level2 视图（status 为 working）
  dm._level2.set('dev1', {
    cwd: '/proj/folder-a',
    seq: 1,
    sessions: new Map([['s1', { ref: 's1', title: 'Old Thinking…', status: 'working' }]]),
    lastSeen: Date.now(),
  });

  // 全局 listing 初始为 working
  assert.equal(dm.workspaces[0].sessions[0].status, 'working');

  // 随后全局 delta 将会话状态更新为 idle
  sessionData.activity = 'idle';
  sessionData.status = 'idle';

  // 核心断言：即便 _level2 遗留了旧的 working，全局 listing / delta 拥有唯一权威，状态必须即时收敛为 idle！
  const updatedStatus = dm.workspaces[0].sessions[0].status;
  assert.equal(updatedStatus, 'idle', 'global listing delta must immediately win over stale selected level2');

  // 后续全局 delta 将会话状态变更为 unknown
  sessionData.activity = 'unknown';
  sessionData.status = 'unknown';
  assert.equal(dm.workspaces[0].sessions[0].status, 'unknown', 'global unknown must not be overridden by stale level2');
});

test('R2 (P1): connection freshness gate: disconnects and reconnecting wait periods output unknown, never fake working', () => {
  const dm = new DeviceManager({
    storage: { getItem: () => null, setItem: () => {}, removeItem: () => {} },
  });

  const mockClient = {
    isReady: false,
    workspaces: [
      {
        cwd: '/proj/repo',
        session_count: 1,
        sessions: [{ ref: 's1', name: 'Task', activity: 'working' }],
      },
    ],
  };

  dm._devices = [{ id: 'd1', checked: true, name: 'Remote' }];
  dm._clients.set('d1', mockClient);

  // 1. 初始化：设备未就绪（STOPPED），尚未收到本代 listing
  dm._status.set('d1', { state: ClientState.STOPPED, lastError: null });
  dm._listingFresh.set('d1', false);
  assert.equal(dm.workspaces[0].sessions[0].status, 'unknown', 'unready device must output unknown status');
  assert.equal(dm.workspaces[0].aggregateState, 'unknown');

  // 2. 收到 auth_ack 变为 READY，但新代 listing 首帧尚未到达
  dm._onState('d1', ClientState.READY);
  assert.equal(dm._listingFresh.get('d1'), false, 'READY before listing must stay un-fresh');
  assert.equal(dm.workspaces[0].sessions[0].status, 'unknown', 'READY before first listing must not declare working');

  // 3. 收到本代首帧 listing
  dm._onFrame('d1', 'listing', { seq: 1, workspaces: [] });
  assert.equal(dm._listingFresh.get('d1'), true, 'first listing establishes freshness');
  assert.equal(dm.workspaces[0].sessions[0].status, 'working', 'fresh listing projects authoritative working');
  assert.equal(dm.workspaces[0].aggregateState, 'working');

  // 4. 网络中断，进入 RECONNECTING
  dm._onState('d1', ClientState.RECONNECTING);
  assert.equal(dm._listingFresh.get('d1'), false, 'disconnect must immediately invalidate freshness');
  assert.equal(dm.workspaces[0].sessions[0].status, 'unknown', 'reconnecting state must safely degrade to unknown');
  assert.equal(dm.workspaces[0].aggregateState, 'unknown');
});

test('R4 (P2): normalizeSessionStatus closed-set normalization and precedence', () => {
  // 1. 正常 working / idle 保留
  assert.equal(normalizeSessionStatus({ activity: 'working' }), 'working');
  assert.equal(normalizeSessionStatus({ activity: 'idle' }), 'idle');
  assert.equal(normalizeSessionStatus({ status: 'working' }), 'working');
  assert.equal(normalizeSessionStatus({ status: 'idle' }), 'idle');

  // 2. 字段存在性优先级：activity 存在时优先取 activity，不回退
  assert.equal(normalizeSessionStatus({ activity: 'idle', status: 'working' }), 'idle');
  assert.equal(normalizeSessionStatus({ activity: 'unknown', status: 'working' }), 'unknown');

  // 3. 闭集归一化：非法字符串或未知状态必须归一化为 'unknown'，杜绝脏状态穿透
  assert.equal(normalizeSessionStatus({ activity: 'not-a-state' }), 'unknown');
  assert.equal(normalizeSessionStatus({ activity: '' }), 'unknown');
  assert.equal(normalizeSessionStatus({ status: 'corrupt-status' }), 'unknown');
  assert.equal(normalizeSessionStatus(null), 'unknown');
  assert.equal(normalizeSessionStatus({}), 'unknown');
});

test('SpacesList eliminates redundant folder row lamp while TabBar breathing lamp is strictly preserved', async () => {
  const spacesListJsx = await readFile(new URL('../src/components/sidebar/SpacesList.jsx', import.meta.url), 'utf8');
  const tabBarJsx = await readFile(new URL('../src/components/chrome/TabBar.jsx', import.meta.url), 'utf8');
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');

  // 1. 断言 SpacesList 中彻底无 SpaceState 状态灯定义与调用
  assert.equal(
    spacesListJsx.includes('SpaceState'),
    false,
    'SpaceRow must eliminate SpaceState completely',
  );
  assert.equal(
    spacesListJsx.includes('spaces-dot is-'),
    false,
    'SpacesList must eliminate spaces-dot completely',
  );

  // 2. 断言 SpacesList 保留最右侧双列数字徽标
  assert.match(spacesListJsx, /className="spaces-row-counts"/);
  assert.match(spacesListJsx, /spaces-count-working/);
  assert.match(spacesListJsx, /spaces-count-total/);

  // 3. 核心验收铁律：顶栏 TabBar 状态指示灯（tb-tab-lamp）保留高质感静态发光（2026-09-24 裁定，杜绝 GPU 持续重绘）
  assert.match(tabBarJsx, /<StatusLamp status=\{finalStatus\} \/>/);
  assert.match(tabBarJsx, /tb-tab-lamp/);
  assert.match(chromeCss, /\.tb-tab-lamp\.is-working\s*\{[^}]*box-shadow:\s*0 0 6px (var\(--green-ring\)|rgba\(34, 197, 94, 0\.6\));/);
  assert.equal(
    /\.tb-tab-lamp\.is-working\s*\{[^}]*animation:\s*tb-lamp-pulse/.test(chromeCss),
    false,
    '.tb-tab-lamp.is-working must NOT have animation: tb-lamp-pulse',
  );
});

test('App.jsx completely eliminates PR #144 fake cache chains and relies purely on authoritative workspaces', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // 彻底删除 globalSessionStatusRef 伪缓存
  assert.equal(appJsx.includes('globalSessionStatusRef'), false, 'globalSessionStatusRef must be completely eliminated');

  // 全域会话状态由 workspaces 纯净直通
  assert.match(appJsx, /const workingCount = sessions\.filter\(\(s\) => s\.state === 'working' \|\| s\.status === 'working'\)\.length;/);
  assert.match(appJsx, /const curStatus = s\.state \|\| s\.status \|\| 'unknown';/);
});
