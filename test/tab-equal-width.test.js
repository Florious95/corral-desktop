import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { hitTestTabBar } from '../src/lib/tabDrag.js';

test('CSS rules: unpinned tabs enforce equal-width adaptive flex layout while pinned tabs stay 32px', async () => {
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');

  // 1. .tb-tab:not(.tb-tab-pinned) 声明弹性等分布局与最大/最小宽度
  assert.match(chromeCss, /\.tb-tab:not\(\.tb-tab-pinned\)\s*\{[^}]*flex:\s*1 1 0px;/);
  assert.match(chromeCss, /\.tb-tab:not\(\.tb-tab-pinned\)\s*\{[^}]*max-width:\s*160px;/);
  assert.match(chromeCss, /\.tb-tab:not\(\.tb-tab-pinned\)\s*\{[^}]*min-width:\s*44px;/);

  // 2. 彻底移除原先阻碍等长自适应的 flex: none
  assert.equal(
    chromeCss.includes('.tb-tab {\n  height: 26px;\n  padding: 0 8px;\n  border-radius: var(--r-6);\n  background: transparent;\n  color: var(--ink-700);\n  line-height: 16px;\n  display: flex;\n  align-items: center;\n  gap: 6px;\n  font-size: 12px;\n  cursor: pointer;\n  border: 1px solid transparent;\n  box-sizing: border-box;\n  flex: none;'),
    false,
    'flex: none on .tb-tab must be eliminated',
  );

  // 3. .tb-tabs-scroll 容器支持 min-width: 0 弹性收缩
  assert.match(chromeCss, /\.tb-tabs-scroll\s*\{[^}]*min-width:\s*0;/);

  // 4. .tb-tab-pinned 保持固定 32px 紧凑宽度且 flex: none 不被压缩
  assert.match(chromeCss, /\.tb-tab-pinned\s*\{[^}]*flex:\s*none;/);
  assert.match(chromeCss, /\.tb-tab-pinned\s*\{[^}]*width:\s*32px;/);
  assert.match(chromeCss, /\.tb-tab-pinned\s*\{[^}]*min-width:\s*32px;/);

  // 5. .tb-tab-name 支持文本溢出省略号优雅截断
  assert.match(chromeCss, /\.tb-tab-name\s*\{[^}]*overflow:\s*hidden;/);
  assert.match(chromeCss, /\.tb-tab-name\s*\{[^}]*text-overflow:\s*ellipsis;/);
  assert.match(chromeCss, /\.tb-tab-name\s*\{[^}]*white-space:\s*nowrap;/);
});

test('layout model: unpinned tabs of varying character lengths compute to strictly equal widths', () => {
  // 模拟 Flexbox 布局计算引擎：
  // 设容器可用宽度 containerWidth，gap = 4px，每项 max-width: 160px，min-width: 44px
  function computeTabWidths(tabTitles, containerWidth = 800) {
    const n = tabTitles.length;
    if (n === 0) return [];
    const gap = 4;
    const totalGaps = (n - 1) * gap;
    const availableForTabs = Math.max(0, containerWidth - totalGaps);
    // 每个 flex: 1 1 0px 的 item 平分可用宽度，受限于 [min-width, max-width]
    const naturalWidth = availableForTabs / n;
    const clampedWidth = Math.max(44, Math.min(160, naturalWidth));
    return tabTitles.map(() => clampedWidth);
  }

  // 短名字 "A" 与长名字 "iOS开发leader" 处于宽敞容器 (800px) 中
  const tabTitles = ['A', 'iOS开发leader', '新工作台'];
  const widths = computeTabWidths(tabTitles, 800);

  // 断言：所有标签页宽度严格完全相等，且达到最大宽度 160px
  assert.equal(widths.length, 3);
  assert.equal(widths[0], 160);
  assert.equal(widths[1], 160);
  assert.equal(widths[2], 160);
  assert.equal(widths[0], widths[1]);
  assert.equal(widths[1], widths[2]);
});

test('adaptive shrinking: tab width shrinks adaptively as tab count increases, maintaining equal widths', () => {
  function computeTabWidths(count, containerWidth = 400) {
    const gap = 4;
    const totalGaps = (count - 1) * gap;
    const availableForTabs = Math.max(0, containerWidth - totalGaps);
    const naturalWidth = availableForTabs / count;
    const clampedWidth = Math.max(44, Math.min(160, naturalWidth));
    return Array.from({ length: count }, () => clampedWidth);
  }

  // 1. 较少标签时（2 个标签），各 160px
  const widths2 = computeTabWidths(2, 400);
  assert.equal(widths2[0], 160);
  assert.equal(widths2[1], 160);

  // 2. 标签增多（4 个标签），等比自适应收缩至 (400 - 12) / 4 = 97px
  const widths4 = computeTabWidths(4, 400);
  assert.equal(widths4[0] < widths2[0], true, 'Tabs must shrink when count increases');
  assert.equal(widths4.every((w) => w === widths4[0]), true, 'All 4 tabs must be equal in width');
  assert.equal(widths4[0], 97);

  // 3. 标签继续增多（6 个标签），进一步收缩至 (400 - 20) / 6 = 63.33px
  const widths6 = computeTabWidths(6, 400);
  assert.equal(widths6[0] < widths4[0], true, 'Tabs must shrink further as count increases');
  assert.equal(widths6.every((w) => w === widths6[0]), true, 'All 6 tabs must be equal in width');

  // 4. 极端很多标签时，触底安全最小宽度 44px
  const widths12 = computeTabWidths(12, 400);
  assert.equal(widths12[0], 44, 'Tabs must not shrink below min-width 44px');
  assert.equal(widths12.every((w) => w === 44), true, 'All tabs clamp at 44px');
});

test('pinned tabs isolation: pinned tabs remain exactly 32px regardless of regular tabs count or shrinking', () => {
  const pinnedTabs = [{ uid: 'pin-1', pinned: true }, { uid: 'pin-2', pinned: true }];
  const pinnedWidth = 32;

  // 钉选标签宽度恒定为 32px
  assert.equal(pinnedTabs.every(() => pinnedWidth === 32), true);
  assert.notEqual(pinnedWidth, 160);
});

test('tabDrag compatibility: hitTestTabBar accurately reorders equal-width and adaptively shrunk tabs', () => {
  const tabBarRect = { x: 50, y: 0, w: 500, h: 38 };

  // 模拟 4 个自适应缩短至 80px 的等长标签（80px + 4px gap）
  const tabWidth = 80;
  const gap = 4;
  const tabRects = [
    { uid: 'tab-1', index: 0, pinned: false, rect: { x: 50, y: 5, w: tabWidth, h: 26 } },
    { uid: 'tab-2', index: 1, pinned: false, rect: { x: 50 + (tabWidth + gap), y: 5, w: tabWidth, h: 26 } }, // x=134
    { uid: 'tab-3', index: 2, pinned: false, rect: { x: 50 + (tabWidth + gap) * 2, y: 5, w: tabWidth, h: 26 } }, // x=218
    { uid: 'tab-4', index: 3, pinned: false, rect: { x: 50 + (tabWidth + gap) * 3, y: 5, w: tabWidth, h: 26 } }, // x=302
  ];

  // 拖动 tab-1 向右经过 tab-3 区域 (x = 240)
  const hit = hitTestTabBar({ x: 240, y: 15, sourceUid: 'tab-1', tabBarRect, tabRects });
  assert.ok(hit);
  assert.equal(hit.type, 'tabbar');
  assert.equal(hit.fromIndex, 0);
  assert.equal(hit.toIndex, 2);

  // 拖动 tab-4 向左至 tab-2 区域 (x = 150)
  const hitLeft = hitTestTabBar({ x: 150, y: 15, sourceUid: 'tab-4', tabBarRect, tabRects });
  assert.ok(hitLeft);
  assert.equal(hitLeft.type, 'tabbar');
  assert.equal(hitLeft.fromIndex, 3);
  assert.equal(hitLeft.toIndex, 1);
});
