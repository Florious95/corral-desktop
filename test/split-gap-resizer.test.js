import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import {
  SPLIT_GAP_PX,
  MIN_PANE_W,
  MIN_PANE_H,
  projectLayout,
  project,
  getSubtreeMinSize,
  computeSplitRatioFromCoord,
  computeSplitRatioFromDelta,
  updateNodeRatio,
  updateSplitRatio,
  createMultiWorkspace,
  serializeWorkspace,
  deserializeWorkspace,
} from '../src/lib/workspaceLayout.js';

test('Issue #271: SPLIT_GAP_PX is exactly 6 and projectLayout generates gap-exact geometry and resizers', () => {
  assert.equal(SPLIT_GAP_PX, 6, 'Shared split gap must be exactly 6px');

  const rect = { x: 0, y: 0, w: 1000, h: 600 };
  const singleTree = { kind: 'leaf', uid: 'pane-single' };
  const singleResult = projectLayout(singleTree, rect, SPLIT_GAP_PX);

  // Single pane: no resizers, edge-to-edge
  assert.equal(singleResult.resizers.length, 0);
  assert.deepEqual(singleResult.panes['pane-single'], { x: 0, y: 0, w: 1000, h: 600 });

  // Two horizontal panes (x-axis split):
  const twoPanesTree = {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'left' },
    second: { kind: 'leaf', uid: 'right' },
  };

  const twoResult = projectLayout(twoPanesTree, rect, SPLIT_GAP_PX);
  assert.equal(twoResult.resizers.length, 1);

  const leftPane = twoResult.panes.left;
  const rightPane = twoResult.panes.right;
  const resizer = twoResult.resizers[0];

  // usable = 1000 - 6 = 994; first = floor(994 * 0.5) = 497; second = 497
  assert.deepEqual(leftPane, { x: 0, y: 0, w: 497, h: 600 });
  assert.deepEqual(resizer.rect, { x: 497, y: 0, w: 6, h: 600 });
  assert.deepEqual(rightPane, { x: 503, y: 0, w: 497, h: 600 });
  assert.equal(resizer.axis, 'x');
  assert.equal(resizer.path, 'root');

  // Verify gap continuity: left.right == resizer.left, resizer.right == right.left
  assert.equal(leftPane.x + leftPane.w, resizer.rect.x);
  assert.equal(resizer.rect.x + resizer.rect.w, rightPane.x);
  assert.equal(rightPane.x + rightPane.w, rect.w);

  // Two vertical panes (y-axis split):
  const vTree = {
    kind: 'split',
    axis: 'y',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'top' },
    second: { kind: 'leaf', uid: 'bottom' },
  };
  const vResult = projectLayout(vTree, rect, SPLIT_GAP_PX);
  assert.equal(vResult.resizers.length, 1);
  const topPane = vResult.panes.top;
  const bottomPane = vResult.panes.bottom;
  const vResizer = vResult.resizers[0];

  // usable = 600 - 6 = 594; first = floor(594 * 0.5) = 297; second = 297
  assert.deepEqual(topPane, { x: 0, y: 0, w: 1000, h: 297 });
  assert.deepEqual(vResizer.rect, { x: 0, y: 297, w: 1000, h: 6 });
  assert.deepEqual(bottomPane, { x: 0, y: 303, w: 1000, h: 297 });
  assert.equal(vResizer.axis, 'y');
});

test('Issue #272: updateNodeRatio and updateSplitRatio update specific split ratios without mutating unrelated nodes', () => {
  // Tree: left | (top / bottom)
  const tree = {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'left' },
    second: {
      kind: 'split',
      axis: 'y',
      ratio: 0.5,
      first: { kind: 'leaf', uid: 'top' },
      second: { kind: 'leaf', uid: 'bottom' },
    },
  };

  // 1. Update root ratio
  const updatedRoot = updateNodeRatio(tree, [], 0.65);
  assert.equal(updatedRoot.ratio, 0.65);
  assert.equal(updatedRoot.second.ratio, 0.5, 'Child split ratio must remain unchanged');

  // 2. Update child split ratio
  const updatedChild = updateNodeRatio(tree, ['second'], 0.35);
  assert.equal(updatedChild.ratio, 0.5, 'Root ratio must remain unchanged');
  assert.equal(updatedChild.second.ratio, 0.35);

  // 3. updateSplitRatio updates active tab root and state.root cleanly
  let mw = createMultiWorkspace({
    tabs: [
      { id: 'tab-1', uid: 'tab-1', root: tree, activeUid: 'left' },
      { id: 'tab-2', uid: 'tab-2', root: { kind: 'leaf', uid: 'other' }, activeUid: 'other' },
    ],
    activeTabId: 'tab-1',
  });

  mw = updateSplitRatio(mw, { tabId: 'tab-1', path: 'root', ratio: 0.72 });
  const activeTab = mw.tabs.find((t) => t.id === 'tab-1');
  assert.equal(activeTab.root.ratio, 0.72);
  assert.equal(mw.root.ratio, 0.72);

  // tab-2 must not be affected
  const otherTab = mw.tabs.find((t) => t.id === 'tab-2');
  assert.equal(otherTab.root.kind, 'leaf');
});

test('Issue #272: customized split ratios survive serialization and persistence round-trip', () => {
  const tree = {
    kind: 'split',
    axis: 'x',
    ratio: 0.68,
    first: { kind: 'leaf', uid: 'pane-a' },
    second: { kind: 'leaf', uid: 'pane-b' },
  };

  const mw = createMultiWorkspace({
    tabs: [{ id: 'tab-1', uid: 'tab-1', root: tree, activeUid: 'pane-a' }],
    activeTabId: 'tab-1',
  });

  const serialized = serializeWorkspace(mw);
  const deserialized = deserializeWorkspace(serialized);

  assert.equal(deserialized.root.ratio, 0.68, 'Ratio must survive serialization');
  const restoredTab = deserialized.tabs.find((t) => t.id === 'tab-1');
  assert.equal(restoredTab.root.ratio, 0.68, 'Tab root ratio must survive serialization');
});

test('Issue #271 & #272: SplitPanes component and terminal.css source contracts', async () => {
  const [splitPanesJsx, terminalCss, appJsx] = await Promise.all([
    readFile(new URL('../src/components/terminal/SplitPanes.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/components/terminal/terminal.css', import.meta.url), 'utf8'),
    readFile(new URL('../src/App.jsx', import.meta.url), 'utf8'),
  ]);

  // 1. SplitPanes declares 6px gap and renders resizer handles
  assert.match(splitPanesJsx, /SPLIT_GAP_PX/);
  assert.match(splitPanesJsx, /className=\{`split-resizer/);
  assert.match(splitPanesJsx, /role="separator"/);
  assert.match(splitPanesJsx, /data-axis=\{r\.axis\}/);
  assert.match(splitPanesJsx, /setPointerCapture/);
  assert.match(splitPanesJsx, /releasePointerCapture/);

  // 2. CSS declares split-resizer with col-resize and row-resize and 6px dimension
  assert.match(terminalCss, /\.split-resizer\[data-axis="x"\]\s*\{[^}]*cursor:\s*col-resize;[^}]*width:\s*6px;/);
  assert.match(terminalCss, /\.split-resizer\[data-axis="y"\]\s*\{[^}]*cursor:\s*row-resize;[^}]*height:\s*6px;/);
  assert.match(terminalCss, /\.split-resizer:hover::after/);

  // 3. App passes onSplitResize callback to SplitPanes with cross-tab fence
  assert.match(appJsx, /handleSplitResize/);
  assert.match(appJsx, /updateSplitRatio/);
  assert.match(appJsx, /onSplitResize=\{handleSplitResize\}/);
  assert.match(appJsx, /if\s*\(tabId\s*&&\s*prev\.activeTabId\s*&&\s*tabId\s*!==\s*prev\.activeTabId\)\s*\{\s*return\s*prev;\s*\}/);
});

test('PR #274 精修 1: handleResizerPointerMove 零强制重排 (Layout Thrashing 消除)', async () => {
  const splitPanesJsx = await readFile(
    new URL('../src/components/terminal/SplitPanes.jsx', import.meta.url),
    'utf8'
  );

  // 提取 handleResizerPointerMove 函数体
  const moveMatch = splitPanesJsx.match(/const handleResizerPointerMove = useCallback\([\s\S]*?\}, \[[^\]]*\]\);/);
  assert.ok(moveMatch, 'handleResizerPointerMove must exist');
  const moveBody = moveMatch[0];

  // 严禁在 pointermove 过程中调用 getBoundingClientRect()
  assert.doesNotMatch(
    moveBody,
    /getBoundingClientRect/,
    'handleResizerPointerMove must NEVER call getBoundingClientRect() (zero forced reflow)'
  );

  // pointerdown 一次性缓存 stageLeft / stageTop
  assert.match(
    splitPanesJsx,
    /stageLeft:\s*stageRect\.left,\s*stageTop:\s*stageRect\.top/,
    'handleResizerPointerDown must cache stageLeft and stageTop once'
  );
});

test('PR #274 精修 2: getSubtreeMinSize 递归叶子下限保护三列及垂直嵌套不被压瘪', () => {
  // 1. 三列横向嵌套：A | (B | C)
  const threeColsTree = {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'col-A' },
    second: {
      kind: 'split',
      axis: 'x',
      ratio: 0.5,
      first: { kind: 'leaf', uid: 'col-B' },
      second: { kind: 'leaf', uid: 'col-C' },
    },
  };

  // 单叶宽度必须 >= 120px
  assert.equal(getSubtreeMinSize(threeColsTree.first, 'x', 6), 120);

  // 内层包含 2 片叶子，总最小宽度 = 120 + 6 + 120 = 246px
  const secondMinW = getSubtreeMinSize(threeColsTree.second, 'x', 6);
  assert.equal(secondMinW, 246);

  // projectLayout 携带 minFirst 和 minSecond
  const layout = projectLayout(threeColsTree, { x: 0, y: 0, w: 1000, h: 600 }, 6);
  assert.equal(layout.resizers.length, 2);
  const outerResizer = layout.resizers[0];
  assert.equal(outerResizer.minFirst, 120);
  assert.equal(outerResizer.minSecond, 246);

  // 当把外层 resizer 拖至极限 (maxFirst = 1000 - 6 - 246 = 748) 时，内层两叶均保持 >= 120px
  const squeezedTree = {
    ...threeColsTree,
    ratio: 748 / (1000 - 6),
  };
  const squeezedLayout = projectLayout(squeezedTree, { x: 0, y: 0, w: 1000, h: 600 }, 6);
  assert.ok(squeezedLayout.panes['col-A'].w >= 120, 'Col A >= 120px');
  assert.ok(squeezedLayout.panes['col-B'].w >= 120, 'Col B >= 120px (never 57px!)');
  assert.ok(squeezedLayout.panes['col-C'].w >= 120, 'Col C >= 120px (never 58px!)');

  // 2. 垂直嵌套：A | (B / C)
  const verticalNestedTree = {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'left' },
    second: {
      kind: 'split',
      axis: 'y',
      ratio: 0.5,
      first: { kind: 'leaf', uid: 'top' },
      second: { kind: 'leaf', uid: 'bottom' },
    },
  };

  const vSubtreeMinH = getSubtreeMinSize(verticalNestedTree.second, 'y', 6);
  assert.equal(vSubtreeMinH, 60 + 6 + 60, 'Vertical two-leaf subtree min height = 126px');

  const vLayout = projectLayout(verticalNestedTree, { x: 0, y: 0, w: 1000, h: 600 }, 6);
  const innerResizer = vLayout.resizers.find((r) => r.axis === 'y');
  assert.ok(innerResizer);
  assert.equal(innerResizer.minFirst, 60);
  assert.equal(innerResizer.minSecond, 60);
});

test('PR #274 精修 3 & 4: 跨 Tab 误写阻断与 Escape 键即时取消拖拽', async () => {
  const splitPanesJsx = await readFile(
    new URL('../src/components/terminal/SplitPanes.jsx', import.meta.url),
    'utf8'
  );

  // 1. 跨 Tab 锁定与检测
  assert.match(splitPanesJsx, /startTabId\s*=\s*activeTabId/);
  assert.match(splitPanesJsx, /resizerDragRef\.current\.startTabId\s*!==\s*activeTabId/);
  assert.match(splitPanesJsx, /startTabId\s*&&\s*currentActiveId\s*&&\s*startTabId\s*!==\s*currentActiveId/);

  // 2. 支持 Escape 键即时取消拖拽
  assert.match(splitPanesJsx, /e\.key\s*===\s*'Escape'/);
  assert.match(splitPanesJsx, /cancelDrag\(\)/);
  assert.match(splitPanesJsx, /window\.addEventListener\('keydown',\s*handleKeyDown,\s*true\)/);
});

test('PR #274 终极微调 1: pointerup 松手终态坐标参与最后一次计算', async () => {
  const splitPanesJsx = await readFile(
    new URL('../src/components/terminal/SplitPanes.jsx', import.meta.url),
    'utf8'
  );

  // 提取 handleResizerPointerUp 函数体
  const upMatch = splitPanesJsx.match(/const handleResizerPointerUp = useCallback\([\s\S]*?\}, \[[^\]]*\]\);/);
  assert.ok(upMatch, 'handleResizerPointerUp must exist');
  const upBody = upMatch[0];

  // pointerup 必须读取事件自身的 clientX / clientY 并参与最终计算
  assert.match(
    upBody,
    /clientCoord\s*=\s*isX\s*\?\s*e\.clientX\s*:\s*e\.clientY/,
    'handleResizerPointerUp must read e.clientX / e.clientY from release event'
  );
  assert.match(
    upBody,
    /computeSplitRatioFromDelta\s*\(\s*drag\.resizer,\s*clientCoord,\s*drag\.startCoord,\s*drag\.startFirstPx,\s*drag\.startRatio,\s*SPLIT_GAP_PX\s*\)/,
    'handleResizerPointerUp must compute finalRatio from release coordinates before submitting'
  );
});

test('PR #274 终极微调 2: 1200px 舞台拖至极限严格 >= 120px (零 119px 舍入误差)', () => {
  // 模拟 1200px 舞台两分屏，极限拖拽至最左侧
  const stageRect = { x: 0, y: 0, w: 1200, h: 600 };
  const tree = {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'pane-left' },
    second: { kind: 'leaf', uid: 'pane-right' },
  };

  const initialLayout = projectLayout(tree, stageRect, 6);
  const resizer = initialLayout.resizers[0];
  assert.ok(resizer);

  // 1. 模拟指针拖拽到极端左侧 (clientX = 50, stageLeft = 0)
  const ratioAtLeftLimit = computeSplitRatioFromCoord(resizer, 50, 0, 6);
  // 可用宽度 1200 - 6 = 1194; 门限 120px
  // 120 / 1194 = 0.1005025... 四舍五入会变成 0.1005 (1194 * 0.1005 = 119.997 -> floor 119px)
  // computeSplitRatioFromCoord 必须向上取整为 0.1006，确保 Math.floor 结果严格 >= 120
  assert.ok(ratioAtLeftLimit >= 120 / (1200 - 6), 'Ratio must be at least 120 / 1194');
  const computedFirstSize = Math.floor((1200 - 6) * ratioAtLeftLimit);
  assert.ok(computedFirstSize >= 120, `computedFirstSize (${computedFirstSize}) must be strictly >= 120px`);

  // 2. 将此极限 ratio 代入 projectLayout，验证最终渲染像素绝对不出现 119px
  const limitTree = { ...tree, ratio: ratioAtLeftLimit };
  const limitLayout = projectLayout(limitTree, stageRect, 6);
  assert.ok(
    limitLayout.panes['pane-left'].w >= 120,
    `pane-left width (${limitLayout.panes['pane-left'].w}) must be strictly >= 120px (never 119px!)`
  );
  assert.ok(
    limitLayout.panes['pane-right'].w >= 120,
    `pane-right width (${limitLayout.panes['pane-right'].w}) must be strictly >= 120px`
  );

  // 3. 模拟即便传入历史遗留的 0.1005 欠切比例，projectLayout 内部兜底依然强制恢复至 >= 120px
  const legacyUnderflowTree = { ...tree, ratio: 0.1005 };
  const legacyLayout = projectLayout(legacyUnderflowTree, stageRect, 6);
  assert.ok(
    legacyLayout.panes['pane-left'].w >= 120,
    `Legacy underflow ratio 0.1005 must be clamped to >= 120px by projectLayout (got ${legacyLayout.panes['pane-left'].w})`
  );
  assert.ok(
    legacyLayout.panes['pane-right'].w >= 120,
    `pane-right must remain >= 120px (got ${legacyLayout.panes['pane-right'].w})`
  );
});

test('PR #274 终极攻坚 1: 原地点击与轴向正交移动零漂移保护（R4 终审 1）', async () => {
  const splitPanesJsx = await readFile(
    new URL('../src/components/terminal/SplitPanes.jsx', import.meta.url),
    'utf8'
  );

  // 1. pointerdown 记录轴向起点坐标与第一块像素宽度
  assert.match(splitPanesJsx, /startX\s*=\s*e\.clientX/);
  assert.match(splitPanesJsx, /startY\s*=\s*e\.clientY/);
  assert.match(splitPanesJsx, /startCoord\s*=\s*isX\s*\?\s*startX\s*:\s*startY/);
  assert.match(splitPanesJsx, /startFirstPx\s*=\s*isX\s*\?\s*\(resizer\.rect\.x\s*-\s*resizer\.parentRect\.x\)/);

  // 2. pointerup 仅在整数像素产生真实改变 (changed === true && finalRatio !== startRatio) 时才提交
  assert.match(
    splitPanesJsx,
    /if\s*\(changed\s*&&\s*finalRatio\s*!==\s*startRatio\s*&&\s*onSplitResize\)/
  );

  // 3. 算法验证：模拟在 6px 手柄左边缘 0.5px 处按下，沿垂直方向移动 20px（水平位移严格为 0）
  const stageRect = { x: 0, y: 0, w: 1000, h: 600 };
  const tree = {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'pane-left' },
    second: { kind: 'leaf', uid: 'pane-right' },
  };
  const layout = projectLayout(tree, stageRect, 6);
  const resizer = layout.resizers[0];
  assert.ok(resizer);

  // 手柄 x = 497..503, 按在 497.5px 处
  const pressX = resizer.rect.x + 0.5;
  const startFirstPx = resizer.rect.x - resizer.parentRect.x; // 497
  assert.equal(startFirstPx, 497);

  // 只在 Y 轴移动 20px，X 轴 currentX 仍为 pressX（delta = 0）
  const orthoMove = computeSplitRatioFromDelta(resizer, pressX, pressX, startFirstPx, 0.5, 6);
  assert.equal(orthoMove.changed, false, 'Perpendicular move must report changed: false');
  assert.equal(orthoMove.ratio, 0.5, 'Perpendicular move must strictly preserve 0.5 (zero 0.4982 drift)');
  assert.equal(orthoMove.firstPx, 497);

  // 真实水平移动 10px
  const realMove = computeSplitRatioFromDelta(resizer, pressX + 10, pressX, startFirstPx, 0.5, 6);
  assert.equal(realMove.changed, true);
  assert.equal(realMove.firstPx, 507);
  assert.notEqual(realMove.ratio, 0.5);
  // 验证反算投影为精确 507px
  assert.equal(Math.floor((1000 - 6) * realMove.ratio), 507);
});

test('PR #274 终极攻坚 2 & R4 终审 2: 外部 root 突变即时清理活动手势与预览（取消过期预览）', async () => {
  const splitPanesJsx = await readFile(
    new URL('../src/components/terminal/SplitPanes.jsx', import.meta.url),
    'utf8'
  );

  // 1. 窗口 Resize 监听取消手势
  assert.match(splitPanesJsx, /window\.addEventListener\('resize',\s*handleWindowResize\)/);

  // 2. 舞台自身 ResizeObserver 尺寸突变取消手势
  assert.match(
    splitPanesJsx,
    /if\s*\(prev\.w\s*===\s*w\s*&&\s*prev\.h\s*===\s*h\)\s*return\s*prev;\s*if\s*\(resizerDragRef\.current\)\s*\{\s*cancelDrag\(\);\s*\}/
  );

  // 3. 外部 root / activeTabId / previewUid 变化即时调用 cancelDrag 取消手势
  assert.match(
    splitPanesJsx,
    /useEffect\(\(\)\s*=>\s*\{[\s\S]*?drag\.startRoot\s*&&\s*effectiveRoot\s*&&\s*drag\.startRoot\s*!==\s*effectiveRoot[\s\S]*?cancelDrag\(\);[\s\S]*?\}\s*,\s*\[effectiveRoot,\s*activeTabId,\s*previewUid,\s*tabs,\s*cancelDrag\]\)/
  );

  // 4. 渲染期同步判定 isDraggingStale，确保 root 变化当帧即刻恢复真实 root，零过期预览残留
  assert.match(
    splitPanesJsx,
    /isDraggingStale\s*=\s*Boolean\([\s\S]*?drag\.startRoot\s*&&\s*effectiveRoot\s*&&\s*drag\.startRoot\s*!==\s*effectiveRoot/
  );
  assert.match(
    splitPanesJsx,
    /currentTree\s*=\s*\(localPreviewRoot\s*&&\s*!isDraggingStale\)\s*\?\s*localPreviewRoot\s*:\s*effectiveRoot/
  );
  assert.match(
    splitPanesJsx,
    /activeResizerPath\s*===\s*r\.path\s*&&\s*!isDraggingStale/
  );
});

test('PR #274 终极攻坚 3: 拖拽期间根树漂移保护（Root Drift Guard）', () => {
  const initialRoot = {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'pane-1' },
    second: { kind: 'leaf', uid: 'pane-2' },
  };

  const ws = createMultiWorkspace({
    tabs: [{ id: 'tab-1', uid: 'tab-1', root: initialRoot, activeUid: 'pane-1' }],
    activeTabId: 'tab-1',
  });

  const tabRoot = ws.tabs[0].root;
  assert.ok(tabRoot);

  // 1. 根树一致时，允许安全更新
  const normalUpdated = updateSplitRatio(ws, {
    tabId: 'tab-1',
    path: 'root',
    ratio: 0.65,
    startRoot: tabRoot,
  });
  assert.equal(normalUpdated.root.ratio, 0.65);

  // 2. 根树被外部改变（如关闭分屏或新分屏）产生漂移时，坚决拒绝污染新树
  const driftedRoot = {
    kind: 'split',
    axis: 'y',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'pane-1' },
    second: { kind: 'leaf', uid: 'pane-3' },
  };
  const wsWithDriftedTree = {
    ...ws,
    tabs: [{ id: 'tab-1', uid: 'tab-1', root: driftedRoot, activeUid: 'pane-1' }],
    root: driftedRoot,
  };

  const rejectedUpdate = updateSplitRatio(wsWithDriftedTree, {
    tabId: 'tab-1',
    path: 'root',
    ratio: 0.72,
    startRoot: tabRoot, // 试图用旧树手势写入新树
  });

  // 必须完全原样返回，新树未受任何污染
  assert.equal(rejectedUpdate, wsWithDriftedTree);
  assert.equal(rejectedUpdate.root.ratio, 0.5);
});

test('PR #274 R5 终审 1: 拖拽手柄拉出后移回初始坐标，预览即刻复原回起点状态', async () => {
  const splitPanesJsx = await readFile(
    new URL('../src/components/terminal/SplitPanes.jsx', import.meta.url),
    'utf8'
  );

  // 1. handleResizerPointerMove 不因为 changed === false 提前拦截回退到起点的预览更新
  assert.match(
    splitPanesJsx,
    /if\s*\(firstPx\s*===\s*drag\.currentFirstPx\)\s*return;/
  );

  // 2. 移回起点 (firstPx === drag.startFirstPx) 时，将预览恢复为 baseRoot
  assert.match(
    splitPanesJsx,
    /const updated = \(firstPx === drag\.startFirstPx\)\s*\?\s*drag\.baseRoot\s*:\s*updateNodeRatio/
  );
});

test('PR #274 R5 终审 2: 狭窄舞台空间不足时零位移/微小手势严格保留原始 ratio (零 0.3279 截断)', () => {
  // 构造三列极端狭窄舞台：总宽度仅 300px，而三列叶子最小尺寸需求为 120 + 6 + 120 + 6 + 120 = 378px
  const narrowRect = { x: 0, y: 0, w: 300, h: 600 };
  const tree = {
    kind: 'split',
    axis: 'x',
    ratio: 0.5,
    first: { kind: 'leaf', uid: 'col-A' },
    second: {
      kind: 'split',
      axis: 'x',
      ratio: 0.5,
      first: { kind: 'leaf', uid: 'col-B' },
      second: { kind: 'leaf', uid: 'col-C' },
    },
  };

  const layout = projectLayout(tree, narrowRect, 6);
  const outerResizer = layout.resizers[0];
  assert.ok(outerResizer);
  // minFirst = 120, minSecond = 246 -> sumMin = 366 > usable (294)
  assert.ok(outerResizer.parentRect.w - 6 < outerResizer.minFirst + outerResizer.minSecond);

  // 在零位移或微小移动时计算 ratio
  const startFirstPx = outerResizer.rect.x - outerResizer.parentRect.x;
  const zeroMove = computeSplitRatioFromDelta(outerResizer, 100, 100, startFirstPx, 0.5, 6);

  // 绝不能被截断计算为 120 / 366 = 0.3279！必须严格保留 0.5，且 changed 为 false
  assert.equal(zeroMove.ratio, 0.5, 'Must preserve original ratio 0.5 in narrow stage (never 0.3279!)');
  assert.equal(zeroMove.changed, false, 'Changed must be false so no resize action is committed');
});
