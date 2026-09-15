import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  createInitialWorkspace,
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
