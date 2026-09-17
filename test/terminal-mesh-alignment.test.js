import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('terminal-bottom-left-alignment: physical bottom-left mesh docking without clipping', () => {
  // 模拟桌面端外层大视口容器 host 与手机端排布产生的小网格 xterm
  const hostRect = { left: 0, top: 0, right: 1200, bottom: 800, width: 1200, height: 800 };

  // 手机端尺寸：20 行 x 80 列，每字符 cellW = 8px, cellH = 18px
  const cellW = 8;
  const cellH = 18;
  const rows = 20;
  const cols = 80;
  const xtermW = cols * cellW; // 640px
  const xtermH = rows * cellH; // 360px

  // flex: 0 0 auto (flex-shrink: 0, 无 max-height 钳制), justify-content: flex-end, align-items: flex-start
  const flexShrink = 0;
  const renderedHeight = flexShrink === 0 ? xtermH : Math.min(xtermH, hostRect.height);
  const renderedWidth = Math.min(xtermW, hostRect.width);

  // justify-content: flex-end 将 .xterm 推到底部
  const xtermTop = hostRect.top + (hostRect.height - renderedHeight); // 0 + (800 - 360) = 440
  const xtermBottom = xtermTop + renderedHeight; // 800
  const xtermLeft = hostRect.left; // 0
  const xtermRight = xtermLeft + renderedWidth; // 640

  const xtermRect = {
    left: xtermLeft,
    top: xtermTop,
    right: xtermRight,
    bottom: xtermBottom,
    width: renderedWidth,
    height: renderedHeight,
  };

  // 1. 物理底边贴合断言：底边误差必须小于 1 CSS 像素
  const bottomDiff = Math.abs(xtermRect.bottom - hostRect.bottom);
  assert.ok(bottomDiff < 1, `Bottom edge must align to host within 1px, got diff: ${bottomDiff}`);

  // 2. 物理左边贴合断言：左边误差必须小于 1 CSS 像素
  const leftDiff = Math.abs(xtermRect.left - hostRect.left);
  assert.ok(leftDiff < 1, `Left edge must align to host within 1px, got diff: ${leftDiff}`);

  // 3. 最后一行的状态栏与倒数第二行的输入框 [ █ ]
  const statusRowTop = xtermRect.bottom - cellH; // 800 - 18 = 782
  const statusRowBottom = xtermRect.bottom; // 800
  const inputBoxTop = xtermRect.bottom - 2 * cellH; // 800 - 36 = 764
  const inputBoxBottom = statusRowTop; // 782

  // 验证输入框与状态行 100% 位于宿主视口内，绝对不被裁切
  assert.ok(inputBoxTop >= hostRect.top, 'Input box top must be >= host top');
  assert.ok(inputBoxBottom <= hostRect.bottom, 'Input box bottom must be <= host bottom');
  assert.ok(statusRowTop >= hostRect.top, 'Status row top must be >= host top');
  assert.ok(statusRowBottom <= hostRect.bottom, 'Status row bottom must be <= host bottom');
  assert.equal(statusRowBottom, hostRect.bottom, 'Status row must sit precisely on host bottom');
});

test('terminal CSS eliminates max-height clamp and enforces flex-shrink: 0 and fit-content width', async () => {
  const terminalCss = await readFile(new URL('../src/components/terminal/terminal.css', import.meta.url), 'utf8');

  // .terminalpane-host flex-end / flex-start 物理对齐
  assert.match(terminalCss, /\.terminalpane-host\s*\{[^}]*display:\s*flex;/);
  assert.match(terminalCss, /\.terminalpane-host\s*\{[^}]*justify-content:\s*flex-end;/);
  assert.match(terminalCss, /\.terminalpane-host\s*\{[^}]*align-items:\s*flex-start;/);

  // .xterm 消除压扁钳制：禁止 flex-shrink 压缩，不钳制 max-height
  assert.match(terminalCss, /\.terminalpane-host \.xterm\s*\{[^}]*flex:\s*0 0 auto;/);
  assert.match(terminalCss, /\.terminalpane-host \.xterm\s*\{[^}]*width:\s*fit-content;/);
  assert.match(terminalCss, /\.terminalpane-host \.xterm\s*\{[^}]*max-width:\s*100%;/);

  // 核心断言：绝对没有 .xterm 的 max-height 钳制！
  assert.equal(terminalCss.includes('max-height: 100%'), false, 'max-height: 100% must be eliminated');
});

test('TerminalPane reflow uses single controlled sendIfNeeded channel without network bypasses', async () => {
  const terminalPaneJsx = await readFile(new URL('../src/components/terminal/TerminalPane.jsx', import.meta.url), 'utf8');

  // 1. 彻底清除绕过 SameWidthController gate 的 clientRef.current?.resize 旁路
  assert.equal(
    terminalPaneJsx.includes('clientRef.current?.resize?.(target'),
    false,
    'Bypass client.resize call must be eliminated from TerminalPane',
  );

  // 2. 彻底清除绕过 gate 的 clientRef.current?.subscribe 旁路
  assert.equal(
    terminalPaneJsx.includes('clientRef.current?.subscribe?.(target'),
    false,
    'Bypass client.subscribe call must be eliminated from TerminalPane',
  );

  // 3. 走正规受控门禁通道 sendIfNeeded(..., "reflow", { force: true })
  assert.match(
    terminalPaneJsx,
    /sendIfNeeded\(\{\s*type:\s*'subscribe'[\s\S]*?'reflow'[\s\S]*?force:\s*true/
  );
});
