import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { DeviceManager } from '../src/core/devices.js';

test('SpacesList renders dual-column badges: working sessions (green when >0, grey when 0) and total sessions', async () => {
  const spacesListJsx = await readFile(new URL('../src/components/sidebar/SpacesList.jsx', import.meta.url), 'utf8');
  const sidebarCss = await readFile(new URL('../src/components/sidebar/sidebar.css', import.meta.url), 'utf8');
  const sidebarJsx = await readFile(new URL('../src/components/sidebar/Sidebar.jsx', import.meta.url), 'utf8');

  // SpaceRow 必须具备双列徽标容器
  assert.match(spacesListJsx, /className="spaces-row-counts"/);
  assert.match(spacesListJsx, /spaces-count-working/);
  assert.match(spacesListJsx, /spaces-count-total/);

  // workingCount 条件判断：> 0 呈现 is-working / is-active，=== 0 呈现 is-idle / is-zero
  assert.match(spacesListJsx, /workingCount \?\? 0\) > 0/);
  assert.match(spacesListJsx, /is-working is-active/);
  assert.match(spacesListJsx, /is-idle is-zero/);

  // 全量行常驻实时：All Spaces、收藏与各个目录空间行均传递 workingCount 与 count
  assert.match(spacesListJsx, /name="All Spaces"[\s\S]*?count=\{allCount\}[\s\S]*?workingCount=\{allWorkingCount\}/);
  assert.match(spacesListJsx, /name="收藏"[\s\S]*?count=\{favCount\}[\s\S]*?workingCount=\{favWorkingCount\}/);
  assert.match(spacesListJsx, /workingCount=\{workingCount\}/);

  // CSS 样式保障：绿色与灰色切换，tabular-nums 数字等宽，右对齐并列
  assert.match(sidebarCss, /\.spaces-row-counts\s*\{[^}]*display:\s*inline-flex;[^}]*align-items:\s*center;/);
  assert.match(sidebarCss, /\.spaces-count-working\.is-working[\s\S]*?color:\s*var\(--green/);
  assert.match(sidebarCss, /\.spaces-count-working\.is-idle[\s\S]*?color:\s*var\(--text-muted\)/);
  assert.match(sidebarCss, /\.spaces-count-total[\s\S]*?color:\s*var\(--text-muted\)/);

  // Sidebar 正确派发全局统计数字
  assert.match(sidebarJsx, /allWorkingCount=\{allWorkingCount/);
  assert.match(sidebarJsx, /favWorkingCount=\{favWorkingCount/);
});

test('TabBar breathing lamp decoupled from sidebar: persists working status across folder navigation', async () => {
  const tabBarJsx = await readFile(new URL('../src/components/chrome/TabBar.jsx', import.meta.url), 'utf8');
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');
  const devicesJs = await readFile(new URL('../src/core/devices.js', import.meta.url), 'utf8');

  // DeviceManager 全局直通状态模型
  assert.match(devicesJs, /get globalSessionStatus\(\)/);
  assert.match(devicesJs, /getSessionStatus\(uid\)/);

  // App.jsx 纯净直通 workspaces 模型
  assert.match(appJsx, /const workingCount = sessions\.filter\(\(s\) => s\.state === 'working' \|\| s\.status === 'working'\)\.length;/);

  // TabBar 实时感知工作状态联动
  assert.match(tabBarJsx, /a\?\.state === 'working' \|\| a\?\.status === 'working'/);
});

test('terminal viewport enforces bottom-left alignment for cross-device mobile consistency', async () => {
  const terminalCss = await readFile(new URL('../src/components/terminal/terminal.css', import.meta.url), 'utf8');
  const terminalPaneJsx = await readFile(new URL('../src/components/terminal/TerminalPane.jsx', import.meta.url), 'utf8');

  // .terminalpane-host 声明 position: relative; overflow: hidden;
  assert.match(terminalCss, /\.terminalpane-host\s*\{[^}]*position:\s*relative;/);
  assert.match(terminalCss, /\.terminalpane-host\s*\{[^}]*overflow:\s*hidden;/);

  // .terminalpane-host > .xterm 实施 root bottom-left 物理底锚，清除 max-height 钳制
  assert.match(terminalCss, /\.terminalpane-host > \.xterm\s*\{[^}]*position:\s*absolute;/);
  assert.match(terminalCss, /\.terminalpane-host > \.xterm\s*\{[^}]*left:\s*0;/);
  assert.match(terminalCss, /\.terminalpane-host > \.xterm\s*\{[^}]*bottom:\s*0;/);
  assert.match(terminalCss, /\.terminalpane-host > \.xterm\s*\{[^}]*width:\s*max-content;/);
  assert.match(terminalCss, /\.terminalpane-host > \.xterm\s*\{[^}]*max-height:\s*none;/);

  // DOM 上具有 data-alignment="bottom-left" 标记
  assert.match(terminalPaneJsx, /data-alignment="bottom-left"/);
});

test('context menu provides "Reflow to Window" (适应当前窗口) and dispatches active reflow', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');
  const terminalPaneJsx = await readFile(new URL('../src/components/terminal/TerminalPane.jsx', import.meta.url), 'utf8');
  const iconsJsx = await readFile(new URL('../src/lib/icons.jsx', import.meta.url), 'utf8');

  // 图标组件 ReflowIcon 导出
  assert.match(iconsJsx, /export function ReflowIcon/);

  // Tab 右键菜单与 Pane 右键菜单均包含 "适应当前窗口"
  assert.match(appJsx, /key: 'reflow',\s*label: '适应当前窗口'/);
  assert.match(appJsx, /handleReflowTab\(menu\.id\)/);
  assert.match(appJsx, /handleReflowPane\(menu\.id\)/);

  // 点击触发 terminal:reflow 事件通知
  assert.match(appJsx, /window\.dispatchEvent\(new CustomEvent\('terminal:reflow'/);

  // TerminalPane 监听并在触发时以 immediate + sync 测量并走正规受控通道
  assert.match(terminalPaneJsx, /window\.addEventListener\('terminal:reflow', handleReflow\)/);
  assert.match(terminalPaneJsx, /viewRef\.current\.fit\(\{\s*immediate:\s*true,\s*sync:\s*true\s*\}\)/);
  assert.match(terminalPaneJsx, /sendIfNeeded\(\{\s*type:\s*'subscribe'/);
  assert.match(terminalPaneJsx, /clientRef\.current\?\.subscribe/);
});

test('runtime simulation: switching spaces maintains global session status and TabBar working lamp', async () => {
  const dm = new DeviceManager({
    storage: { getItem: () => null, setItem: () => {}, removeItem: () => {} },
  });

  const client = {
    unsubscribeLevel2: () => {},
    workspaces: [
      {
        cwd: '/path/projectA',
        session_count: 2,
        sessions: [
          { ref: 'sess-1', name: 'Task 1', activity: 'working', provider: 'codex' },
          { ref: 'sess-2', name: 'Task 2', status: 'idle', provider: 'cursor' },
        ],
      },
      {
        cwd: '/path/projectB',
        session_count: 1,
        sessions: [
          { ref: 'sess-3', name: 'Other task', status: 'idle', provider: 'pi' },
        ],
      },
    ],
  };
  dm._devices = [{ id: 'dev1', checked: true, name: 'Local' }];
  dm._clients.set('dev1', client);

  // 全局直通模型已记录该会话的真实工作状态（无需点击即可获取）
  const status1 = dm.getSessionStatus('dev1::sess-1');
  assert.equal(status1?.status, 'working');
  assert.equal(status1?.provider, 'codex');

  // 侧栏切换到 projectB（更新 _level2）
  dm._level2.set('dev1', { cwd: '/path/projectB', seq: null, sessions: new Map(), lastSeen: 0 });

  // 验收铁律检验：即便侧栏切到了任何其他目录，sess-1 的全局状态依然稳定直通为 working！
  const statusAfterSwitch = dm.getSessionStatus('dev1::sess-1');
  assert.equal(statusAfterSwitch?.status, 'working');

  // 即使执行全局退订，直通模型也全天候常驻保持
  dm.unsubscribeLevel2();
  assert.equal(dm.getSessionStatus('dev1::sess-1')?.status, 'working');
});
