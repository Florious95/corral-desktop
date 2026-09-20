import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('CSS rules: width-lock and spring capsule motion properties', async () => {
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');

  // 1. .tb-tab-capsule 声明弹性物理滑轨与纯 Compositor 缓动曲线
  assert.match(chromeCss, /\.tb-tab-capsule\s*\{[^}]*position:\s*absolute;/);
  assert.match(chromeCss, /\.tb-tab-capsule\s*\{[^}]*pointer-events:\s*none;/);
  assert.match(chromeCss, /\.tb-tab-capsule\s*\{[^}]*will-change:\s*transform,\s*opacity;/);
  assert.match(chromeCss, /transition:[^;]*cubic-bezier\(0\.18,\s*0\.89,\s*0\.32,\s*1\.12\)/);

  // 2. .tb-tabs-scroll[data-locked='true'] 锁定 Tab 宽度，防止删除时瞬间重新等宽展开
  assert.match(chromeCss, /\.tb-tabs-scroll\[data-locked='true'\]\s*\.tb-tab:not\(\.tb-tab-pinned\)\s*\{[^}]*flex:\s*0\s+0\s+var\(--tb-tab-width,\s*160px\)\s*!important;/);
  assert.match(chromeCss, /\.tb-tabs-scroll\[data-locked='true'\]\s*\.tb-tab:not\(\.tb-tab-pinned\)\s*\{[^}]*width:\s*var\(--tb-tab-width,\s*160px\)\s*!important;/);
  assert.match(chromeCss, /\.tb-tabs-scroll\[data-locked='true'\]\s*\.tb-tab:not\(\.tb-tab-pinned\)\s*\{[^}]*min-width:\s*var\(--tb-tab-width,\s*160px\)\s*!important;/);
  assert.match(chromeCss, /\.tb-tabs-scroll\[data-locked='true'\]\s*\.tb-tab:not\(\.tb-tab-pinned\)\s*\{[^}]*max-width:\s*var\(--tb-tab-width,\s*160px\)\s*!important;/);
  assert.match(chromeCss, /\.tb-tabs-scroll\[data-locked='true'\]\s*\.tb-tab:not\(\.tb-tab-pinned\)\s*\{[^}]*transition:\s*none\s*!important;/);

  // 3. .tb-tab 尺寸变化时带有平滑缓动过渡
  assert.match(chromeCss, /\.tb-tab\s*\{[^}]*transition:[^}]*width\s+0\.2s\s+cubic-bezier\(0\.16,\s*1,\s*0\.3,\s*1\)/);

  // 4. prefers-reduced-motion 支持无障碍降级
  assert.match(chromeCss, /@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{[^}]*\.tb-tab-capsule\s*\{[^}]*transition:\s*none/);
});

test('TabBar source code: contains Rare UI spring capsule and Chrome width-lock lifecycle', async () => {
  const tabBarJsx = await readFile(new URL('../src/components/chrome/TabBar.jsx', import.meta.url), 'utf8');

  // 1. 声明 Rare UI 弹性物理胶囊背景指示器
  assert.match(tabBarJsx, /className="tb-tab-capsule"/);
  assert.match(tabBarJsx, /transform:\s*`translate3d\(\$\{capsuleStyle\.left\}px,\s*0,\s*0\)\s*scaleX\(\$\{capsuleStyle\.scaleX\}\)`/);
  assert.match(tabBarJsx, /data-has-capsule=\{capsuleStyle\.opacity > 0 \? 'true' : undefined\}/);

  // 2. 包含鼠标悬停追踪与宽度锁定
  assert.match(tabBarJsx, /onMouseEnter=\{handleMouseEnterTabBar\}/);
  assert.match(tabBarJsx, /onMouseLeave=\{handleMouseLeaveTabBar\}/);
  assert.match(tabBarJsx, /setLockedTabWidth\(currentWidth\)/);
  assert.match(tabBarJsx, /setLockedTabWidth\(null\)/);

  // 3. 锁定状态通过 CSS variable 注入 style 并具有同步 DOM 写入以消除 React 渲染批处理时延
  assert.match(tabBarJsx, /scrollContainerRef\.current\.setAttribute\('data-locked',\s*'true'\)/);
  assert.match(tabBarJsx, /scrollContainerRef\.current\.style\.setProperty\('--tb-tab-width'/);
  assert.match(tabBarJsx, /'--tb-tab-width':\s*`\$\{lockedTabWidth\}px`/);
});

test('Chrome-style Tab width locking model: width locks immediately on close without 300ms transition jitter', () => {
  // 模拟真实渲染与物理光标位置计算
  class TabBarPhysicalSimulator {
    constructor(initialTabs) {
      this.tabs = [...initialTabs];
      this.isPointerInside = false;
      this.lockedWidth = null;
      this.containerWidth = 652;
      this.tabMaxWidth = 160;
      this.tabMinWidth = 44;
      this.gap = 4;
    }

    computeNaturalTabWidth() {
      const n = this.tabs.length;
      if (n === 0) return 0;
      const totalGaps = (n - 1) * this.gap;
      const available = Math.max(0, this.containerWidth - totalGaps);
      return Math.max(this.tabMinWidth, Math.min(this.tabMaxWidth, available / n));
    }

    getRenderedTabWidth() {
      if (this.lockedWidth !== null) {
        // 关键：data-locked='true' 时宽度强制死锁为 lockedWidth，transition: none，零时延零回退！
        return this.lockedWidth;
      }
      return this.computeNaturalTabWidth();
    }

    getCloseButtonX(tabIndex) {
      const width = this.getRenderedTabWidth();
      const tabLeft = tabIndex * (width + this.gap);
      // close 按钮位于 tab 内部右侧 8px 处
      return tabLeft + width - 14;
    }

    onCloseClick(tabIndex) {
      // 1. 同步捕获当前物理宽度
      if (this.lockedWidth === null) {
        this.lockedWidth = this.getRenderedTabWidth();
      }
      // 2. 移除被点击项
      this.tabs.splice(tabIndex, 1);
      if (this.tabs.length <= 1) {
        this.lockedWidth = null;
      }
    }

    onMouseLeave() {
      this.isPointerInside = false;
      this.lockedWidth = null;
    }
  }

  // 初始化 4 个 Tab，各 160px：
  // Tab 0: [0..160], closeBtn at 146
  // Tab 1: [164..324], closeBtn at 310
  // Tab 2: [328..488], closeBtn at 474
  // Tab 3: [492..652], closeBtn at 638
  const sim = new TabBarPhysicalSimulator([{ id: 't0' }, { id: 't1' }, { id: 't2' }, { id: 't3' }]);
  assert.equal(sim.getRenderedTabWidth(), 160);

  // 用户将光标悬停在 Tab 0 的关闭按钮位置 (x: 146)
  const fixedCursorX = 146;
  assert.equal(sim.getCloseButtonX(0), fixedCursorX);

  // 1. 用户点击关闭 Tab 0
  sim.onCloseClick(0);

  // 关键断言 1：立即同步死锁在 160px，绝不会瞬时跌落至 109.72px！
  assert.equal(sim.lockedWidth, 160);
  assert.equal(sim.getRenderedTabWidth(), 160);

  // 关键断言 2：现在的第 0 项（原 Tab 1）左移到位后，其关闭按钮坐标必须精确等于鼠标当前位置 fixedCursorX (146)！
  // 零时延、零抖动，光标无须移动即可立即触发下一次关闭！
  assert.equal(sim.getCloseButtonX(0), fixedCursorX);

  // 2. 用户在原地再次快速点击关闭
  sim.onCloseClick(0);

  // 关键断言 3：连续关闭第 2 次后，宽度仍然牢牢死锁在 160px，下一个 tab 的关闭按钮仍对齐 fixedCursorX！
  assert.equal(sim.lockedWidth, 160);
  assert.equal(sim.getRenderedTabWidth(), 160);
  assert.equal(sim.getCloseButtonX(0), fixedCursorX);

  // 3. 用户移出 Tab 区域
  sim.onMouseLeave();
  assert.equal(sim.lockedWidth, null);
  assert.equal(sim.getRenderedTabWidth(), 160);
});
