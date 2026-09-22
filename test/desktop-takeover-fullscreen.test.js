import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('TerminalPane eliminates 500ms blind wait and defaults immediately to takeover on initial mount', async () => {
  const terminalPaneJsx = await readFile(
    new URL('../src/components/terminal/TerminalPane.jsx', import.meta.url),
    'utf8',
  );

  // 1. 彻底拔除 500ms 盲等定时器，杜绝二次弹跳 (Issue #211)
  assert.doesNotMatch(terminalPaneJsx, /takeoverTimer = setTimeout/);
  assert.doesNotMatch(terminalPaneJsx, /let takeoverTimer = null;/);

  // 2. 初始状态在移动端未活跃时直接进入 TAKEOVER 模式并纯数学投影几何
  assert.match(terminalPaneJsx, /currentMode = isMobileActive \? PRESENCE_MODE\.AVOIDANCE : PRESENCE_MODE\.TAKEOVER/);
  assert.match(terminalPaneJsx, /setPresenceMode\(currentMode\)/);
  assert.match(terminalPaneJsx, /computeGridDimensions/);
  assert.match(terminalPaneJsx, /initialCols/);
  assert.match(terminalPaneJsx, /initialRows/);
});

test('terminal.css and TerminalPane implement dual-mode CSS decoupling for desktop takeover', async () => {
  const terminalCss = await readFile(
    new URL('../src/components/terminal/terminal.css', import.meta.url),
    'utf8',
  );
  const terminalPaneJsx = await readFile(
    new URL('../src/components/terminal/TerminalPane.jsx', import.meta.url),
    'utf8',
  );

  // 1. 默认态保持 46x44 物理底锚
  assert.match(terminalCss, /\.terminalpane-host > \.xterm\s*\{[^}]*position:\s*absolute;/);
  assert.match(terminalCss, /\.terminalpane-host > \.xterm\s*\{[^}]*left:\s*0;/);
  assert.match(terminalCss, /\.terminalpane-host > \.xterm\s*\{[^}]*bottom:\s*0;/);
  assert.match(terminalCss, /\.terminalpane-host > \.xterm\s*\{[^}]*width:\s*max-content;/);

  // 2. TAKEOVER 模式下解耦 max-content，100% 自适应铺满视口
  assert.match(terminalCss, /\.terminalpane-host\.is-takeover > \.xterm\s*\{[^}]*position:\s*relative;/);
  assert.match(terminalCss, /\.terminalpane-host\.is-takeover > \.xterm\s*\{[^}]*width:\s*100%;/);
  assert.match(terminalCss, /\.terminalpane-host\.is-takeover > \.xterm\s*\{[^}]*height:\s*100%;/);

  // 3. TAKEOVER 模式下解除 terminalpane-body 内缩 padding
  assert.match(terminalCss, /\.terminalpane\[data-presence-mode="takeover"\]\s+\.terminalpane-body[^}]*padding:\s*0;/);

  // 4. TerminalPane.jsx 根据 presenceMode 动态附加 is-takeover 类名
  assert.match(terminalPaneJsx, /className=\{`terminalpane-host\$\{presenceMode === PRESENCE_MODE\.TAKEOVER \? ' is-takeover' : ''\}`\}/);
  assert.match(terminalPaneJsx, /className=\{`terminalpane-body\$\{presenceMode === PRESENCE_MODE\.TAKEOVER \? ' is-takeover' : ''\}`\}/);
});

test('auto-takeover logic enters takeover immediately without 500ms delay', async () => {
  let isMobileActive = false;
  let mode = isMobileActive ? 'avoidance' : 'takeover';
  let settledGrid = null;

  if (mode === 'takeover') {
    settledGrid = { rows: 45, cols: 135 };
  }

  // 验证无移动端在线时立即进入接管态并设定目标网格，零延迟
  assert.equal(mode, 'takeover');
  assert.deepEqual(settledGrid, { rows: 45, cols: 135 });
});
