import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import {
  createMultiWorkspace,
  createWorkspaceTab,
  switchWorkspaceTab,
  smartOpenSession,
  focusWorkspacePane,
  getLeaves,
} from '../src/lib/workspaceLayout.js';

test('P0 regression: clicking preview stage pane does NOT contaminate Tab 1 activeUid nor create duplicate tabs', () => {
  const A = 'device-1::/dir-a\x1f%1';
  const B = 'device-1::/dir-b\x1f%2';

  const titleA = 'Agent Alpha (A)';
  const titleB = 'Agent Beta (B)';

  const agentsByUid = new Map([
    [A, { key: A, title: titleA, deviceName: 'Mac' }],
    [B, { key: B, title: titleB, deviceName: 'Mac' }],
  ]);

  function tabIdentity(tab) { return tab.id || tab.uid; }
  function tabOf(state, id = state.activeTabId) { return state.tabs.find((tab) => tabIdentity(tab) === id); }

  function getTabBarTitles(state) {
    return state.tabs.map((tab) => {
      const leaves = tab.root && typeof tab.root === 'object'
        ? getLeaves(tab.root)
        : (tab.activeUid ? [tab.activeUid] : (tab.uid ? [tab.uid] : []));
      const effectiveActiveUid = (leaves.length > 0 && tab.activeUid && leaves.includes(tab.activeUid))
        ? tab.activeUid
        : (leaves[0] || tab.activeUid || tab.uid);
      const agent = effectiveActiveUid ? agentsByUid.get(effectiveActiveUid) : agentsByUid.get(tab.uid);
      const activeTitle = agent ? agent.title : (effectiveActiveUid || tab.uid);
      return tab.name || (leaves.length > 1 ? `${activeTitle} (${leaves.length})` : activeTitle);
    });
  }

  // Step 1: 创建多工作台初始状态，新建空白 Tab 1
  let state = createMultiWorkspace();
  assert.equal(state.tabs.length, 1);
  assert.equal(tabOf(state).isBlank, true);

  // Step 2: 侧栏点击 A，会话 A 正式固化入驻 Tab 1
  state = smartOpenSession(state, A);
  assert.equal(state.previewUid, null);
  assert.deepEqual(getLeaves(tabOf(state).root), [A]);
  assert.equal(tabOf(state).activeUid, A);
  assert.equal(getTabBarTitles(state)[0], titleA);

  // Step 3: 侧栏点击未打开过的会话 B，进入虚空接纳槽（previewUid = B）
  // 按照第二铁律：右侧立刻呈现 B 供操作，顶栏 Tab 1 稳如泰山（仍为 A）
  state = smartOpenSession(state, B);
  assert.equal(state.previewUid, B);
  assert.deepEqual(getLeaves(state.root), [B], 'Stage shows preview B');
  assert.deepEqual(getLeaves(tabOf(state).root), [A], 'Tab 1 root remains A');
  assert.equal(tabOf(state).activeUid, A, 'Tab 1 activeUid remains A');
  assert.equal(getTabBarTitles(state)[0], titleA, 'TabBar Tab 1 remains title A');

  // Step 4: 用户在 Stage / 终端 B 上点击鼠标，触发 focusWorkspacePane(B)
  // 核心修复检验：由于 B 属于 previewUid 且并非当前 Tab 1 的成员，
  // focusWorkspacePane 严格禁止污染当前常驻 Tab 1！
  const beforeFocusTab1 = { ...tabOf(state) };
  state = focusWorkspacePane(state, B);

  // 严密断言：Tab 1 的 activeUid 严格保持为 A，绝不被 preview B 脑裂篡改！
  assert.deepEqual(getLeaves(tabOf(state).root), [A]);
  assert.equal(tabOf(state).activeUid, A, 'Tab 1 activeUid MUST NOT be overwritten by preview B');
  assert.equal(tabOf(state).id, beforeFocusTab1.id);
  assert.equal(getTabBarTitles(state)[0], titleA, 'Tab 1 title MUST remain title A');

  // Step 5: 用户点击 "+" 新建 Tab 2
  state = createWorkspaceTab(state);
  const tab2Id = state.activeTabId;
  assert.notEqual(tab2Id, 'tab-1');
  assert.equal(state.previewUid, null, 'Creating tab clears preview');
  assert.equal(tabOf(state, 'tab-1').activeUid, A, 'Tab 1 activeUid is purely A');
  assert.deepEqual(getLeaves(tabOf(state, 'tab-1').root), [A]);
  assert.equal(tabOf(state, tab2Id).isBlank, true, 'Tab 2 is blank');

  // Step 6: 此时当前处于空白 Tab 2，用户在侧栏再次点击 B
  // 按照第三铁律：B 成功固化入驻 Tab 2！
  state = smartOpenSession(state, B);
  assert.equal(state.previewUid, null);
  assert.deepEqual(getLeaves(tabOf(state, 'tab-1').root), [A], 'Tab 1 still holds A');
  assert.equal(tabOf(state, 'tab-1').activeUid, A, 'Tab 1 activeUid is A');
  assert.deepEqual(getLeaves(tabOf(state, tab2Id).root), [B], 'Tab 2 committed B');
  assert.equal(tabOf(state, tab2Id).activeUid, B, 'Tab 2 activeUid is B');

  // 核心终验断言：顶栏 TabBar 分别呈现 titleA 与 titleB，绝对不出现两个同名的 B！
  const titles = getTabBarTitles(state);
  assert.equal(titles[0], titleA, 'Tab 1 must display title A');
  assert.equal(titles[1], titleB, 'Tab 2 must display title B');
  assert.notEqual(titles[0], titles[1], 'Must NEVER produce duplicate tab names!');

  // 后续步骤：用户点击切回 Tab 1
  state = switchWorkspaceTab(state, 'tab-1');
  assert.equal(state.activeTabId, 'tab-1');
  assert.deepEqual(getLeaves(state.root), [A], 'Stage content returns to A');
  assert.equal(tabOf(state).activeUid, A, 'Tab 1 activeUid remains A');
  assert.equal(getTabBarTitles(state)[0], titleA);
  assert.equal(getTabBarTitles(state)[1], titleB);
});

test('source code guards: focusWorkspacePane, handleFocusPane, SplitPanes and TabBar protection', async () => {
  const layoutJs = await readFile(new URL('../src/lib/workspaceLayout.js', import.meta.url), 'utf8');
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');
  const splitPanesJsx = await readFile(new URL('../src/components/terminal/SplitPanes.jsx', import.meta.url), 'utf8');
  const tabBarJsx = await readFile(new URL('../src/components/chrome/TabBar.jsx', import.meta.url), 'utf8');

  // 1. workspaceLayout.js: focusWorkspacePane 具备真实成员守卫
  assert.match(layoutJs, /if\s*\(state\.previewUid && state\.previewUid === uid\)\s*\{\s*return state;\s*\}/);
  assert.match(layoutJs, /const isMember = currentTab\.root\s*\?\s*!*findLeaf\(currentTab\.root, uid\)/);

  // 2. App.jsx: handleFocusPane 拦截 previewUid 点击
  assert.match(appJsx, /if\s*\(prev\?\.previewUid && prev\.previewUid === uid\)\s*\{\s*return prev;\s*\}/);

  // 3. SplitPanes.jsx: 预览窗格不触发 onFocusPane
  assert.match(splitPanesJsx, /if\s*\(uid !== previewUid && onFocusPane\)\s*\{\s*onFocusPane\(uid\);\s*\}/);

  // 4. TabBar.jsx: effectiveActiveUid 优先校验真实存在的 root 树叶子节点
  assert.match(tabBarJsx, /const effectiveActiveUid = \(leaves\.length > 0 && tab\.activeUid && leaves\.includes\(tab\.activeUid\)\)/);
});
