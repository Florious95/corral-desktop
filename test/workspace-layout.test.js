import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  createInitialWorkspace,
  createMultiWorkspace,
  createWorkspaceTab,
  switchWorkspaceTab,
  closeWorkspaceTab,
  openSessionInActiveTab,
  splitSessionInActiveTab,
  pinWorkspaceTab,
  reorderWorkspaceTabs,
  closeOtherWorkspaceTabs,
  closeRightWorkspaceTabs,
  getAllWorkspaceSessions,
  smartOpenSession,
  isBlankTab,
  closeWorkspacePane,
  focusWorkspacePane,
  getLeaves,
  findLeaf,
  removeNode,
  replaceLeaf,
  splitLeaf,
  dropNode,
  project,
  openSession,
  focusTab,
  splitSession,
  closeTab,
  closePane,
  pinTab,
  reorderTabs,
  closeOtherTabs,
  closeRightTabs,
  validateWorkspaceState,
  serializeWorkspace,
  deserializeWorkspace,
  migrateLegacyPanes,
  loadWorkspaceFromStorage,
  saveWorkspaceToStorage,
} from '../src/lib/workspaceLayout.js';

test('workspaceLayout: createInitialWorkspace returns default version 1 state', () => {
  const ws = createInitialWorkspace();
  assert.equal(ws.version, 1);
  assert.deepEqual(ws.tabs, []);
  assert.equal(ws.activeUid, null);
  assert.equal(ws.root, null);
  assert.equal(validateWorkspaceState(ws), true);
});

test('workspaceLayout: getLeaves and findLeaf traverse tree correctly', () => {
  const tree = {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'a' },
    second: {
      kind: 'split',
      axis: 'y',
      ratio: 0.5,
      first: { kind: 'leaf', uid: 'b' },
      second: { kind: 'leaf', uid: 'c' },
    },
  };

  assert.deepEqual(getLeaves(tree), ['a', 'b', 'c']);
  assert.equal(findLeaf(tree, 'a'), true);
  assert.equal(findLeaf(tree, 'b'), true);
  assert.equal(findLeaf(tree, 'c'), true);
  assert.equal(findLeaf(tree, 'd'), false);
  assert.equal(findLeaf(null, 'a'), false);
});

test('workspaceLayout: removeNode promotes sibling and naturally absorbs parent geometry', () => {
  const tree = {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'a' },
    second: {
      kind: 'split',
      axis: 'y',
      ratio: 0.4,
      first: { kind: 'leaf', uid: 'b' },
      second: { kind: 'leaf', uid: 'c' },
    },
  };

  // 移除 b：second 变为 c，内部 ratio 保留
  const afterB = removeNode(tree, 'b');
  assert.deepEqual(afterB, {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'a' },
    second: { kind: 'leaf', uid: 'c' },
  });

  // 再移除 a：仅剩 c，树坍缩为叶子 c
  const afterA = removeNode(afterB, 'a');
  assert.deepEqual(afterA, { kind: 'leaf', uid: 'c' });

  // 移除仅存的 c：返回 null
  const afterC = removeNode(afterA, 'c');
  assert.equal(afterC, null);
});

test('workspaceLayout: splitLeaf and replaceLeaf mutate nodes immutably', () => {
  const leaf = { kind: 'leaf', uid: 'a' };
  const split = splitLeaf(leaf, 'a', 'b', { axis: 'x', ratio: 0.5, insertAfter: true });
  assert.deepEqual(split, {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'a' },
    second: { kind: 'leaf', uid: 'b' },
  });

  const replaced = replaceLeaf(split, 'a', 'c');
  assert.deepEqual(replaced, {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'c' },
    second: { kind: 'leaf', uid: 'b' },
  });
});

test('workspaceLayout: dropNode atomic candidate tree reorganization', () => {
  const tree = {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'a' },
    second: { kind: 'leaf', uid: 'b' },
  };

  // 将 a 拖到 b 的右侧：二者调序为 b | a
  const dropped = dropNode(tree, 'a', 'b', 'right');
  assert.deepEqual(dropped, {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'b' },
    second: { kind: 'leaf', uid: 'a' },
  });

  // 将 a 拖到 b 的下方：b 在上，a 在下
  const droppedBottom = dropNode(tree, 'a', 'b', 'bottom');
  assert.deepEqual(droppedBottom, {
    kind: 'split',
    axis: 'y',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'b' },
    second: { kind: 'leaf', uid: 'a' },
  });

  // 自身拖向自身：无操作
  assert.equal(dropNode(tree, 'a', 'a', 'right'), tree);
});

test('workspaceLayout: project calculates exact pixel coordinates with zero cracks and zero overlap', () => {
  const rect = { x: 0, y: 0, w: 1000, h: 600 };
  const tree = {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'a' },
    second: {
      kind: 'split',
      axis: 'y',
      ratio: 0.5,
      first: { kind: 'leaf', uid: 'b' },
      second: { kind: 'leaf', uid: 'c' },
    },
  };

  const layout = project(tree, rect, 1);
  assert.deepEqual(Object.keys(layout).sort(), ['a', 'b', 'c']);

  // x 轴分割：usable = 1000 - 1 = 999; firstW = floor(999*0.5) = 499; secondW = 500
  assert.deepEqual(layout.a, { x: 0, y: 0, w: 499, h: 600 });

  // second 区域：x = 500, w = 500, h = 600
  // y 轴分割：usable = 600 - 1 = 599; firstH = floor(599*0.5) = 299; secondH = 300
  assert.deepEqual(layout.b, { x: 500, y: 0, w: 500, h: 299 });
  assert.deepEqual(layout.c, { x: 500, y: 300, w: 500, h: 300 });

  // 验证无缝贴合：a.w + gap + b.w = 499 + 1 + 500 = 1000
  assert.equal(layout.a.w + 1 + layout.b.w, 1000);
  // b.h + gap + c.h = 299 + 1 + 300 = 600
  assert.equal(layout.b.h + 1 + layout.c.h, 600);
});

test('workspaceLayout: openSession and focusTab lifecycle transitions', () => {
  let ws = createInitialWorkspace();

  // 打开第一个会话：创建 root 叶子并激活
  ws = openSession(ws, 's1');
  assert.deepEqual(ws.tabs, [{ uid: 's1', pinned: false }]);
  assert.equal(ws.activeUid, 's1');
  assert.deepEqual(ws.root, { kind: 'leaf', uid: 's1' });

  // 再次打开 s1：已在树中，仅聚焦
  ws = focusTab(ws, 's1');
  assert.equal(ws.activeUid, 's1');

  // 打开新会话 s2：替换当前焦点叶子 s1，s1 仍保留在 tabs 中
  ws = openSession(ws, 's2');
  assert.deepEqual(ws.tabs, [{ uid: 's1', pinned: false }, { uid: 's2', pinned: false }]);
  assert.equal(ws.activeUid, 's2');
  assert.deepEqual(ws.root, { kind: 'leaf', uid: 's2' });

  // 切回 s1：替换焦点叶子为 s1
  ws = focusTab(ws, 's1');
  assert.equal(ws.activeUid, 's1');
  assert.deepEqual(ws.root, { kind: 'leaf', uid: 's1' });
});

test('workspaceLayout: splitSession creates binary splits and enforces unique visible leaves', () => {
  let ws = openSession(createInitialWorkspace(), 's1');

  // 在 s1 旁边向右分屏打开 s2
  ws = splitSession(ws, 's1', 's2', { axis: 'x', ratio: 0.5 });
  assert.equal(ws.activeUid, 's2');
  assert.deepEqual(getLeaves(ws.root), ['s1', 's2']);

  // 重复向右分屏打开已在舞台中的 s1：先从旧位置移除，保证单会话在舞台中绝对唯一
  ws = splitSession(ws, 's2', 's1', { axis: 'y', ratio: 0.5 });
  assert.equal(ws.activeUid, 's1');
  const leaves = getLeaves(ws.root);
  assert.equal(leaves.length, 2);
  assert.equal(new Set(leaves).size, 2);
});

test('workspaceLayout: closeTab and closePane cleanups', () => {
  let ws = openSession(createInitialWorkspace(), 's1');
  ws = splitSession(ws, 's1', 's2', { axis: 'x', ratio: 0.5 });
  ws = openSession(ws, 's3'); // s3 追加到 tabs 并替换当前焦点
  assert.equal(ws.tabs.length, 3);

  // closePane: 仅从舞台移除 s3，不从 tabs 移除
  ws = closePane(ws, 's3');
  assert.equal(ws.tabs.length, 3);
  assert.equal(findLeaf(ws.root, 's3'), false);

  // closeTab: 彻底关闭 s2
  ws = closeTab(ws, 's2');
  assert.equal(ws.tabs.some((t) => t.uid === 's2'), false);
  assert.equal(findLeaf(ws.root, 's2'), false);
});

test('workspaceLayout: pinTab preserves contiguous pinned prefix invariant', () => {
  let ws = createInitialWorkspace({
    tabs: [
      { uid: 's1', pinned: false },
      { uid: 's2', pinned: false },
      { uid: 's3', pinned: false },
    ],
    activeUid: 's1',
    root: { kind: 'leaf', uid: 's1' },
  });

  // 钉选 s2：移到最前
  ws = pinTab(ws, 's2', true);
  assert.deepEqual(ws.tabs, [
    { uid: 's2', pinned: true },
    { uid: 's1', pinned: false },
    { uid: 's3', pinned: false },
  ]);

  // 钉选 s3：移到 pinned 组末尾（s1 之前）
  ws = pinTab(ws, 's3', true);
  assert.deepEqual(ws.tabs, [
    { uid: 's2', pinned: true },
    { uid: 's3', pinned: true },
    { uid: 's1', pinned: false },
  ]);

  // 取消钉选 s2：移到未钉选区最前
  ws = pinTab(ws, 's2', false);
  assert.deepEqual(ws.tabs, [
    { uid: 's3', pinned: true },
    { uid: 's2', pinned: false },
    { uid: 's1', pinned: false },
  ]);
});

test('workspaceLayout: closeOtherTabs and closeRightTabs protect pinned items', () => {
  let ws = createInitialWorkspace({
    tabs: [
      { uid: 'p1', pinned: true },
      { uid: 'u1', pinned: false },
      { uid: 'u2', pinned: false },
      { uid: 'u3', pinned: false },
    ],
    activeUid: 'u2',
    root: { kind: 'leaf', uid: 'u2' },
  });

  // 关闭右侧：u3 被移除，p1, u1, u2 保留
  const rightClosed = closeRightTabs(ws, 'u2');
  assert.deepEqual(rightClosed.tabs.map((t) => t.uid), ['p1', 'u1', 'u2']);

  // 关闭其他：保留 pinned p1 与当前 u2，u1 和 u3 被关闭
  const othersClosed = closeOtherTabs(ws, 'u2');
  assert.deepEqual(othersClosed.tabs.map((t) => t.uid), ['p1', 'u2']);
});

test('workspaceLayout: reorderTabs keeps tabs ordered and preserves pinned invariant', () => {
  let ws = createInitialWorkspace({
    tabs: [
      { uid: 'p1', pinned: true },
      { uid: 'u1', pinned: false },
      { uid: 'u2', pinned: false },
    ],
    activeUid: 'u1',
    root: { kind: 'leaf', uid: 'u1' },
  });

  // 在未钉选区内调序 u1, u2
  ws = reorderTabs(ws, 1, 2);
  assert.deepEqual(ws.tabs.map((t) => t.uid), ['p1', 'u2', 'u1']);
});

test('workspaceLayout: validateWorkspaceState, serialize and deserialize with schema protection', () => {
  const valid = {
    version: 1,
    tabs: [{ uid: 's1', pinned: false }, { uid: 's2', pinned: true }],
    activeUid: 's1',
    root: {
      kind: 'split',
      axis: 'x',
      ratio: 0.5,
      first: { kind: 'leaf', uid: 's1' },
      second: { kind: 'leaf', uid: 's2' },
    },
  };
  assert.equal(validateWorkspaceState(valid), true);

  const serialized = serializeWorkspace(valid);
  assert.match(serialized, /"version":1/);
  const restored = deserializeWorkspace(serialized);
  assert.deepEqual(restored, valid);

  // 坏数据校验与反损坏边界
  assert.equal(validateWorkspaceState({ version: 2 }), false); // 未知版本
  assert.equal(validateWorkspaceState({ version: 1, tabs: [{ uid: 'dup' }, { uid: 'dup' }] }), false); // 重复 uid
  assert.equal(deserializeWorkspace('bad-json'), null);
});

test('workspaceLayout: migrateLegacyPanes creates 1/n ratio equal-width tree', () => {
  const legacy = ['a', 'b', 'c'];
  const migrated = migrateLegacyPanes(legacy, 'b');

  assert.equal(migrated.version, 1);
  assert.equal(migrated.activeUid, 'b');
  assert.deepEqual(migrated.tabs.map((t) => t.uid), ['a', 'b', 'c']);

  // 验证几何投影下三者绝对等宽（1000px 宽度，0 gap）
  const layout = project(migrated.root, { x: 0, y: 0, w: 900, h: 600 }, 0);
  assert.equal(layout.a.w, 300);
  assert.equal(layout.b.w, 300);
  assert.equal(layout.c.w, 300);
});

test('workspaceLayout: multi-workspace tabs with plus button lifecycle and isolation', () => {
  // 1. 默认初始状态：只有 1 个初始 Tab
  let mw = createMultiWorkspace();
  assert.equal(mw.version, 2);
  assert.equal(mw.tabs.length, 1);
  assert.equal(mw.tabs[0].root, null);
  assert.equal(mw.tabs[0].activeUid, null);

  // 2. 核心变革：在 Tab 1 中点击会话，仅在 Tab 1 内部打开，Tab 数量绝不增加！
  mw = openSessionInActiveTab(mw, 'agent-1');
  assert.equal(mw.tabs.length, 1, 'Clicking session must NOT add a new tab to TabBar');
  assert.equal(mw.activeUid, 'agent-1');
  assert.deepEqual(getLeaves(mw.root), ['agent-1']);

  // 再次点击另一个会话：在 Tab 1 内部替换当前窗格，Tab 数量仍为 1
  mw = openSessionInActiveTab(mw, 'agent-2');
  assert.equal(mw.tabs.length, 1, 'Switching session must NOT add a new tab to TabBar');
  assert.equal(mw.activeUid, 'agent-2');
  assert.deepEqual(getLeaves(mw.root), ['agent-2']);

  // 3. 在 Tab 1 内部向右分屏：Tab 1 组装多分屏网格，Tab 数量仍为 1
  mw = splitSessionInActiveTab(mw, 'agent-2', 'agent-3', 'right');
  assert.equal(mw.tabs.length, 1, 'Splitting session must NOT add a new tab to TabBar');
  assert.deepEqual(getLeaves(mw.root), ['agent-2', 'agent-3']);

  // 4. 点击【+】加号新建工作台：新建 Tab 2 并自动聚焦，Tab 2 初始为空白
  mw = createWorkspaceTab(mw);
  assert.equal(mw.tabs.length, 2, 'Clicking plus button creates a new tab');
  assert.equal(mw.activeTabId, mw.tabs[1].id);
  assert.equal(mw.root, null, 'New tab starts blank');
  assert.equal(mw.activeUid, null);

  // 5. 在 Tab 2 中点击会话：仅在 Tab 2 中打开，完全不影响 Tab 1！
  mw = openSessionInActiveTab(mw, 'agent-4');
  assert.equal(mw.tabs.length, 2);
  assert.equal(mw.activeUid, 'agent-4');
  assert.deepEqual(getLeaves(mw.root), ['agent-4']);

  // 6. 切换回 Tab 1：Tab 1 的分屏状态（agent-2 | agent-3）完好无损秒级恢复！
  mw = switchWorkspaceTab(mw, mw.tabs[0].id);
  assert.equal(mw.activeTabId, mw.tabs[0].id);
  assert.deepEqual(getLeaves(mw.root), ['agent-2', 'agent-3'], 'Tab 1 split panes preserved completely');

  // 7. 切到 Tab 2：Tab 2 的会话（agent-4）完好无损！
  mw = switchWorkspaceTab(mw, mw.tabs[1].id);
  assert.equal(mw.activeTabId, mw.tabs[1].id);
  assert.deepEqual(getLeaves(mw.root), ['agent-4']);

  // 8. 关闭 Tab 2：关闭后自动激活 Tab 1
  mw = closeWorkspaceTab(mw, mw.tabs[1].id);
  assert.equal(mw.tabs.length, 1);
  assert.equal(mw.activeTabId, mw.tabs[0].id);
  assert.deepEqual(getLeaves(mw.root), ['agent-2', 'agent-3']);

  // 9. 关闭最后一个 Tab：自动重置为一个初始空白 Tab（tabs 永不为空）
  mw = closeWorkspaceTab(mw, mw.tabs[0].id);
  assert.equal(mw.tabs.length, 1);
  assert.equal(mw.root, null);
});

test('workspaceLayout: multi-workspace v2 serialization and v1 backward compatibility', () => {
  // 1. v2 序列化与反序列化
  let mw = createMultiWorkspace();
  mw = openSessionInActiveTab(mw, 'a1');
  mw = createWorkspaceTab(mw, { name: '自定义工作台' });
  mw = openSessionInActiveTab(mw, 'a2');

  const serialized = serializeWorkspace(mw);
  assert.match(serialized, /"version":2/);
  assert.match(serialized, /自定义工作台/);

  const restored = deserializeWorkspace(serialized);
  assert.equal(restored.version, 2);
  assert.equal(restored.tabs.length, 2);
  assert.equal(validateWorkspaceState(restored), true);

  // 2. v1 向后兼容：deserializeWorkspace 保持 v1 结构，loadWorkspaceFromStorage 自动升级为 v2 多工作台并在 Tab 1 承载
  const v1Json = JSON.stringify({
    version: 1,
    tabs: [{ uid: 'legacy-session', pinned: false }],
    activeUid: 'legacy-session',
    root: { kind: 'leaf', uid: 'legacy-session' },
  });
  const fromV1 = deserializeWorkspace(v1Json);
  assert.equal(fromV1.version, 1);
  assert.equal(fromV1.activeUid, 'legacy-session');

  const mockStorage = {
    getItem: (k) => (k === 'am.workspace.v1' ? v1Json : null),
    setItem: () => {},
  };
  const fromStorage = loadWorkspaceFromStorage(mockStorage);
  assert.equal(fromStorage.version, 2);
  assert.equal(fromStorage.tabs.length, 1);
  assert.equal(fromStorage.activeUid, 'legacy-session');
  assert.deepEqual(getLeaves(fromStorage.root), ['legacy-session']);
});

test('workspaceLayout: equal columns 1:1:1 balancing eliminates 211 / 112 splits', () => {
  // 1. 初始为两列 A | B (各 50%)
  const twoCols = {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'A' },
    second: { kind: 'leaf', uid: 'B' },
  };

  // 2. 拖拽 C 到 B 的右侧追加第 3 列 -> 必须均分 1:1:1（消灭 2:1:1 或 1:1:2）
  const threeCols = dropNode(twoCols, 'C', 'B', 'right');
  assert.deepEqual(getLeaves(threeCols), ['A', 'B', 'C']);

  // 验证几何投影：在 902px 宽度舞台下，3 列宽度绝对等宽（各 300px）
  const layout3 = project(threeCols, { x: 0, y: 0, w: 902, h: 600 }, 1);
  assert.equal(layout3.A.w, 300, 'Column A must be exactly 300px in 1:1:1');
  assert.equal(layout3.B.w, 300, 'Column B must be exactly 300px in 1:1:1');
  assert.equal(layout3.C.w, 300, 'Column C must be exactly 300px in 1:1:1');

  // 3. 继续追加第 4 列 D 到 C 的右侧 -> 4 列必须绝对均等 1:1:1:1（各 25%）
  const fourCols = dropNode(threeCols, 'D', 'C', 'right');
  assert.deepEqual(getLeaves(fourCols), ['A', 'B', 'C', 'D']);
  const layout4 = project(fourCols, { x: 0, y: 0, w: 1003, h: 600 }, 1);
  assert.equal(layout4.A.w, 250);
  assert.equal(layout4.B.w, 250);
  assert.equal(layout4.C.w, 250);
  assert.equal(layout4.D.w, 250);

  // 4. 将新列插在中间（例如在 A 和 B 之间插入 E）：同样全局保持均分
  const insertedMid = dropNode(twoCols, 'E', 'A', 'right');
  assert.deepEqual(getLeaves(insertedMid), ['A', 'E', 'B']);
  const layoutMid = project(insertedMid, { x: 0, y: 0, w: 902, h: 600 }, 1);
  assert.equal(layoutMid.A.w, 300);
  assert.equal(layoutMid.E.w, 300);
  assert.equal(layoutMid.B.w, 300);
});

test('workspaceLayout: three iron laws - dedup jump, preview slot, blank-tab commit', () => {
  // 1. 初始创建多工作台：包含一个空白 Tab 1
  let mw = createMultiWorkspace();
  assert.equal(mw.tabs.length, 1);
  assert.equal(isBlankTab(mw.tabs[0]), true);

  // 2. 第三铁律：当前激活 Tab 为空白卡，点击未打开会话 s1 -> 成功固化入驻到 Tab 1，转为常驻 Tab
  mw = smartOpenSession(mw, 's1');
  assert.equal(mw.tabs.length, 1);
  assert.equal(mw.activeUid, 's1');
  assert.deepEqual(getLeaves(mw.root), ['s1']);
  assert.equal(isBlankTab(mw.tabs[0]), false);
  assert.equal(mw.previewUid, null);

  // 3. 第二铁律：当前激活 Tab 已绑定会话（非空白）！
  // 用户在左侧点击未打开的会话 s2：
  // -> 激活【虚空接纳槽（previewUid: 's2'）】：右侧主工作区立刻呈现 s2 终端供操作！
  // -> 但上方已固化的 TabBar 绝不被修改、绝不被替换，绝对不增加常驻 Tab 挤占位置！
  mw = smartOpenSession(mw, 's2');
  assert.equal(mw.tabs.length, 1, 'TabBar must NOT append a permanent tab');
  assert.equal(mw.tabs[0].activeUid, 's1', 'Tab 1 bound session must remain untouched');
  assert.deepEqual(getLeaves(mw.tabs[0].root), ['s1'], 'Tab 1 root must remain s1');
  assert.equal(mw.previewUid, 's2', 'Must enter scratch/preview slot');
  assert.equal(mw.activeUid, 's2', 'Active pane must show s2 in workspace');
  assert.deepEqual(getLeaves(mw.root), ['s2'], 'Stage must project s2 terminal');

  // 4. 连续快速点击未打开会话 s3：虚空槽即时切换至 s3，TabBar 依然稳如泰山！
  mw = smartOpenSession(mw, 's3');
  assert.equal(mw.tabs.length, 1, 'TabBar count remains 1');
  assert.equal(mw.previewUid, 's3');
  assert.equal(mw.activeUid, 's3');
  assert.deepEqual(getLeaves(mw.root), ['s3']);

  // 5. 第一铁律：全局唯一性与自动导航跳转！
  // 此时在虚空预览槽（正在预览 s3）点击已经在 Tab 1 中打开过的 s1：
  // -> 必须立刻清空虚空槽，自动跳转回 Tab 1，并将焦点定位至 s1 窗格！
  mw = smartOpenSession(mw, 's1');
  assert.equal(mw.activeTabId, mw.tabs[0].id, 'Must navigate back to Tab 1');
  assert.equal(mw.previewUid, null, 'Preview slot cleared');
  assert.equal(mw.activeUid, 's1', 'Focus restored to s1');
  assert.deepEqual(getLeaves(mw.root), ['s1']);

  // 6. 第三铁律：用户点击【+】显式新增空白选项卡 Tab 2！
  mw = createWorkspaceTab(mw);
  assert.equal(mw.tabs.length, 2);
  assert.equal(mw.activeTabId, mw.tabs[1].id);
  assert.equal(isBlankTab(mw.tabs[1]), true);
  assert.equal(mw.previewUid, null);

  // 此时在当前空白 Tab 2 上点击未打开过的 s2：
  // -> 成功【固化入驻】到 Tab 2，Tab 2 转为非空白常驻 Tab！
  mw = smartOpenSession(mw, 's2');
  assert.equal(mw.tabs.length, 2, 'Tab 2 is now committed');
  assert.equal(mw.activeTabId, mw.tabs[1].id);
  assert.equal(mw.activeUid, 's2');
  assert.deepEqual(getLeaves(mw.tabs[1].root), ['s2']);
  assert.equal(isBlankTab(mw.tabs[1]), false);
  assert.equal(mw.previewUid, null);

  // 7. 在 Tab 2 内部进行多分屏 (s2 | s3)
  mw = splitSessionInActiveTab(mw, 's2', 's3', 'right');
  assert.deepEqual(getLeaves(mw.root), ['s2', 's3']);
  assert.equal(mw.activeUid, 's3');

  // 8. 第一铁律在多分屏下的验证：
  // 切换回 Tab 1 (仅含 s1)，此时点击多分屏中的 s3：
  // -> 必须自动跨 Tab 导航跳转到 Tab 2，并聚焦到 s3 窗格！绝不重复打开！
  mw = switchWorkspaceTab(mw, mw.tabs[0].id);
  assert.equal(mw.activeTabId, mw.tabs[0].id);
  assert.equal(mw.activeUid, 's1');

  mw = smartOpenSession(mw, 's3');
  assert.equal(mw.activeTabId, mw.tabs[1].id, 'Must navigate across tabs to Tab 2 where s3 lives');
  assert.equal(mw.activeUid, 's3', 'Must focus the s3 pane inside Tab 2 split tree');
  assert.deepEqual(getLeaves(mw.root), ['s2', 's3']);
});

test('workspaceLayout: closing all panes in a tab restores isBlank status', () => {
  let mw = createMultiWorkspace();
  mw = smartOpenSession(mw, 's1');
  assert.equal(isBlankTab(mw.tabs[0]), false);

  // 关闭该窗格
  mw = closeWorkspacePane(mw, 's1');
  assert.equal(isBlankTab(mw.tabs[0]), true);

  // 变为空白卡后，再次点击 s2 可以重新填入
  mw = smartOpenSession(mw, 's2');
  assert.equal(mw.activeUid, 's2');
  assert.equal(isBlankTab(mw.tabs[0]), false);
});

test('workspaceLayout: closeWorkspacePane persists to tabs[activeTab].root in v2 and rebalances columns', () => {
  // 1. 构建 4 列均分分屏
  let mw = createMultiWorkspace();
  mw = openSessionInActiveTab(mw, 'col-1');
  mw = splitSessionInActiveTab(mw, 'col-1', 'col-2', 'right');
  mw = splitSessionInActiveTab(mw, 'col-2', 'col-3', 'right');
  mw = splitSessionInActiveTab(mw, 'col-3', 'col-4', 'right');

  const curTab = mw.tabs.find((t) => t.id === mw.activeTabId);
  assert.equal(getLeaves(curTab.root).length, 4);

  // 2. 关闭第 1 列 col-1
  mw = closeWorkspacePane(mw, 'col-1');

  // 验证 DOM / top-level root 与 tabs[activeTab].root 同步更新
  assert.deepEqual(getLeaves(mw.root), ['col-2', 'col-3', 'col-4']);
  const updatedTab = mw.tabs.find((t) => t.id === mw.activeTabId);
  assert.deepEqual(getLeaves(updatedTab.root), ['col-2', 'col-3', 'col-4'], 'tabs[activeTab].root must be synchronized');

  // 验证均分重新平衡为 1:1:1
  const layout = project(mw.root, { x: 0, y: 0, w: 902, h: 600 }, 1);
  assert.equal(layout['col-2'].w, 300);
  assert.equal(layout['col-3'].w, 300);
  assert.equal(layout['col-4'].w, 300);

  // 3. 验证 v2 本地持久化与反序列化后绝不复现被删除的列
  const serialized = serializeWorkspace(mw);
  assert.equal(serialized.includes('col-1'), false, 'Deleted pane must not exist in serialized v2');
  const restored = deserializeWorkspace(serialized);
  assert.deepEqual(getLeaves(restored.root), ['col-2', 'col-3', 'col-4']);
  const restoredTab = restored.tabs.find((t) => t.id === restored.activeTabId);
  assert.deepEqual(getLeaves(restoredTab.root), ['col-2', 'col-3', 'col-4']);
});

test('workspaceLayout: focusWorkspacePane and ghost/duplicate tab elimination', () => {
  // 1. 初始化多工作台，打开单会话 s1
  let mw = createMultiWorkspace();
  mw = smartOpenSession(mw, 's1');
  assert.equal(mw.tabs.length, 1);
  assert.equal(mw.activeUid, 's1');

  // 2. 模拟快速点击右侧终端窗格：focusWorkspacePane 仅激活当前窗格，tabs.length 绝不增加，绝不生成幽灵 Tab
  const prevTabsLen = mw.tabs.length;
  mw = focusWorkspacePane(mw, 's1');
  assert.equal(mw.tabs.length, prevTabsLen, 'Must not append any ghost tab');
  assert.equal(mw.activeUid, 's1');

  // 3. 构建多分屏 (s1 | s2)
  mw = splitSessionInActiveTab(mw, 's1', 's2', 'right');
  assert.equal(mw.tabs.length, 1);
  assert.deepEqual(getLeaves(mw.root), ['s1', 's2']);
  assert.equal(mw.activeUid, 's2');

  // 4. 点击窗格 s1：focusWorkspacePane 切换焦点至 s1，tabs 结构完全保持不变
  mw = focusWorkspacePane(mw, 's1');
  assert.equal(mw.tabs.length, 1);
  assert.equal(mw.activeUid, 's1');
  assert.deepEqual(getLeaves(mw.root), ['s1', 's2']);

  // 5. 再次点击同一焦点 s1：原状态直接返回（引用一致性）
  const same = focusWorkspacePane(mw, 's1');
  assert.strictEqual(same, mw);

  // 6. 防穿透：在 v2 模式下即使外部误调 openSession，也会安全委派至 smartOpenSession，绝不产生扁平幽灵 Tab
  let redirected = openSession(mw, 's3');
  assert.equal(redirected.tabs.length, mw.tabs.length, 'TabBar must NOT append a permanent tab');
  assert.equal(redirected.previewUid, 's3', 'Unopened session opens in preview slot');
  assert.deepEqual(getLeaves(redirected.tabs[0].root), ['s1', 's2'], 'Tab 1 split tree remains intact');
  assert.equal(redirected.tabs.some((t) => !t.root && !t.activeUid), false, 'Must never create empty ghost tab');
});
