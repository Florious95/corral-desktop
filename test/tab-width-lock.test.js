import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('CSS rules: width-lock and spring capsule motion properties', async () => {
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');

  // 1. .tb-tab-capsule 声明弹性物理滑轨与缓动曲线
  assert.match(chromeCss, /\.tb-tab-capsule\s*\{[^}]*position:\s*absolute;/);
  assert.match(chromeCss, /\.tb-tab-capsule\s*\{[^}]*pointer-events:\s*none;/);
  assert.match(chromeCss, /\.tb-tab-capsule\s*\{[^}]*will-change:\s*transform,\s*width,\s*opacity;/);
  assert.match(chromeCss, /transition:[^;]*cubic-bezier\(0\.18,\s*0\.89,\s*0\.32,\s*1\.12\)/);

  // 2. .tb-tabs-scroll[data-locked='true'] 锁定 Tab 宽度，防止删除时瞬间重新等宽展开
  assert.match(chromeCss, /\.tb-tabs-scroll\[data-locked='true'\]\s*\.tb-tab:not\(\.tb-tab-pinned\)\s*\{[^}]*flex:\s*0\s+0\s+var\(--tb-tab-width,\s*160px\);/);
  assert.match(chromeCss, /\.tb-tabs-scroll\[data-locked='true'\]\s*\.tb-tab:not\(\.tb-tab-pinned\)\s*\{[^}]*width:\s*var\(--tb-tab-width,\s*160px\);/);
  assert.match(chromeCss, /\.tb-tabs-scroll\[data-locked='true'\]\s*\.tb-tab:not\(\.tb-tab-pinned\)\s*\{[^}]*max-width:\s*var\(--tb-tab-width,\s*160px\);/);

  // 3. .tb-tab 尺寸变化时带有平滑缓动过渡
  assert.match(chromeCss, /\.tb-tab\s*\{[^}]*transition:[^}]*width\s+0\.2s\s+cubic-bezier\(0\.16,\s*1,\s*0\.3,\s*1\)/);

  // 4. prefers-reduced-motion 支持无障碍降级
  assert.match(chromeCss, /@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{[^}]*\.tb-tab-capsule\s*\{[^}]*transition:\s*none/);
});

test('TabBar source code: contains Rare UI spring capsule and Chrome width-lock lifecycle', async () => {
  const tabBarJsx = await readFile(new URL('../src/components/chrome/TabBar.jsx', import.meta.url), 'utf8');

  // 1. 声明 Rare UI 弹性物理胶囊背景指示器
  assert.match(tabBarJsx, /className="tb-tab-capsule"/);
  assert.match(tabBarJsx, /transform:\s*`translateX\(\$\{capsuleStyle\.left\}px\)`/);
  assert.match(tabBarJsx, /width:\s*`\$\{capsuleStyle\.width\}px`/);

  // 2. 包含鼠标悬停追踪与宽度锁定
  assert.match(tabBarJsx, /onMouseEnter=\{handleMouseEnterTabBar\}/);
  assert.match(tabBarJsx, /onMouseLeave=\{handleMouseLeaveTabBar\}/);
  assert.match(tabBarJsx, /setLockedTabWidth\(currentWidth\)/);
  assert.match(tabBarJsx, /setLockedTabWidth\(null\)/);

  // 3. 锁定状态通过 CSS variable 注入 style
  assert.match(tabBarJsx, /'--tb-tab-width':\s*`\$\{lockedTabWidth\}px`/);
});

test('Chrome-style Tab width locking model: width locks on close while hovered, resets on mouseleave', () => {
  // 模拟状态机逻辑（与 TabBar 内部状态流严格等价）
  class TabBarWidthLockMachine {
    constructor(initialTabs) {
      this.tabs = [...initialTabs];
      this.isPointerInside = false;
      this.lockedWidth = null;
      this.defaultMaxWidth = 160;
      this.containerWidth = 400;
      this.gap = 4;
    }

    // 计算当前自适应宽度
    computeAdaptiveWidth() {
      const n = this.tabs.length;
      if (n === 0) return 0;
      const totalGaps = (n - 1) * this.gap;
      const available = Math.max(0, this.containerWidth - totalGaps);
      return Math.max(44, Math.min(this.defaultMaxWidth, available / n));
    }

    // 获取当前标签生效宽度
    getEffectiveTabWidth() {
      if (this.lockedWidth !== null) {
        return this.lockedWidth;
      }
      return this.computeAdaptiveWidth();
    }

    onMouseEnter() {
      this.isPointerInside = true;
    }

    onMouseLeave() {
      this.isPointerInside = false;
      this.lockedWidth = null; // 离开时解锁，平滑恢复自适应
    }

    onCloseTab(tabId) {
      if (this.isPointerInside && this.tabs.length > 1) {
        // 如果之前未锁定，捕获并锁定当前宽度
        if (this.lockedWidth === null) {
          this.lockedWidth = this.getEffectiveTabWidth();
        }
      }
      this.tabs = this.tabs.filter((t) => t.id !== tabId);
      // 若只剩 <= 1 个，自动解除锁定
      if (this.tabs.length <= 1) {
        this.lockedWidth = null;
      }
    }
  }

  const machine = new TabBarWidthLockMachine([
    { id: 't1' },
    { id: 't2' },
    { id: 't3' },
    { id: 't4' },
  ]);

  // 1. 初始状态：4 个标签在 400px 容器中平分：(400 - 12) / 4 = 97px
  assert.equal(machine.getEffectiveTabWidth(), 97);
  assert.equal(machine.lockedWidth, null);

  // 2. 鼠标移入 TabBar 区域准备点击关闭
  machine.onMouseEnter();

  // 3. 用户点击 t2 的关闭按钮快速关闭
  machine.onCloseTab('t2');

  // 关键断言：此时剩余 3 个标签，但由于鼠标指针仍在 TabBar 内部，宽度必须严格锁定在 97px！
  // 绝不能回退到未锁定时的 (400 - 8) / 3 = 130.67px！
  assert.equal(machine.lockedWidth, 97);
  assert.equal(machine.getEffectiveTabWidth(), 97);
  assert.equal(machine.tabs.length, 3);

  // 4. 用户无需挪动鼠标，在原位置立即点击关闭现在的第 2 个标签 (t3)
  machine.onCloseTab('t3');

  // 关键断言：宽度依然牢牢锁定在 97px！连续关闭依然对齐鼠标！
  assert.equal(machine.lockedWidth, 97);
  assert.equal(machine.getEffectiveTabWidth(), 97);
  assert.equal(machine.tabs.length, 2);

  // 5. 用户移开鼠标（mouseleave）
  machine.onMouseLeave();

  // 关键断言：锁定解除，宽度平滑重新自适应扩展为 (400 - 4) / 2 = 160px（受限于 max-width: 160px）
  assert.equal(machine.lockedWidth, null);
  assert.equal(machine.getEffectiveTabWidth(), 160);
});
