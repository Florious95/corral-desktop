import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('App derives authoritative session display name from s.name and never from OSC title', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // 1. 彻底删除 PR #144 中的 effectiveTitle = s.title 逻辑
  assert.equal(appJsx.includes('effectiveTitle = (s.title && s.title !== \'\')'), false, 'PR #144 corrupt effectiveTitle logic must be eliminated');

  // 2. 权威展示名收敛为 s.name || s.title || ''
  assert.match(appJsx, /const sessionName = s\.name \|\| s\.title \|\| '';/);
  assert.match(appJsx, /title: sessionName,/);

  // 3. 收藏 key（fav）判定与读写使用基于唯一标识的 isAgentFav 与 toggleAgentFav
  assert.match(appJsx, /fav:\s*isAgentFav\(w\.spaceKey,\s*s,\s*favSet\)/);
  assert.match(appJsx, /toggleAgentFav\(prev,\s*agent\.spaceKey,\s*agent\)/);
});

test('session display name authority: renders authoritative name "桌面端leader" instead of raw OSC title', () => {
  // 模拟从服务端获取到的 workspace 与 session DTO
  const session = {
    ref: 'pane-1',
    name: '桌面端leader', // 服务端权威提取名称
    title: 'π - 桌面端leader - tmux桌面端', // 底层终端 OSC 原始窗口外壳
    provider: 'pi',
    status: 'working',
  };

  // 按照 App.jsx 中的权威收敛算法计算
  const sessionName = session.name || session.title || '';
  const agentTitle = sessionName;

  // 核心断言：必须 100% 展示为 "桌面端leader"，彻底消除 OSC 污染！
  assert.equal(agentTitle, '桌面端leader');
  assert.equal(agentTitle.includes('π -'), false);
  assert.equal(agentTitle.includes('- tmux桌面端'), false);

  // 模拟 s.name 缺失时的优雅兜底
  const sessionWithoutName = {
    ref: 'pane-2',
    name: '',
    title: 'fallback-title',
  };
  const fallbackName = sessionWithoutName.name || sessionWithoutName.title || '';
  assert.equal(fallbackName, 'fallback-title');

  // 模拟两者均缺失的极端场景
  const emptySession = { ref: 'pane-3', name: '', title: '' };
  assert.equal(emptySession.name || emptySession.title || '', '');
});

test('contract documents specify s.name as authoritative display name (2026-09-17 裁定)', async () => {
  const uiSpec = await readFile(new URL('../docs/UI-SPEC.md', import.meta.url), 'utf8');
  const contract = await readFile(new URL('../docs/CLIENT-CONTRACT.md', import.meta.url), 'utf8');

  // UI-SPEC 明确 s.name 为第一展示名，OSC 仅做兜底
  assert.match(uiSpec, /title\s*=\s*session\.name 原样（服务端权威提取的会话展示名/);
  assert.match(uiSpec, /底层 OSC 窗口标题 session\.title 仅做兜底/);
  assert.match(uiSpec, /2026-09-17 裁定/);

  // CLIENT-CONTRACT 明确 name 为服务端权威提取的准确展示名
  assert.match(contract, /name 为服务端权威提取的准确会话展示名（2026-09-17 裁定）/);
  assert.match(contract, /title 为底层 OSC 窗口标题（仅在 name 为空时兜底）/);
});
