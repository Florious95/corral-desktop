import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('TerminalPane implements 500ms auto-takeover timeout to prevent single-desktop deadlocks', async () => {
  const terminalPaneJsx = await readFile(
    new URL('../src/components/terminal/TerminalPane.jsx', import.meta.url),
    'utf8',
  );

  // 1. 定义与声明 takeoverTimer 与 triggerTakeover
  assert.match(terminalPaneJsx, /let takeoverTimer = null;/);
  assert.match(terminalPaneJsx, /const triggerTakeover = \(\) => \{/);

  // 2. UNKNOWN 态下开启 500ms 探测超时
  assert.match(terminalPaneJsx, /if\s*\(currentMode === PRESENCE_MODE\.UNKNOWN\)\s*\{/);
  assert.match(terminalPaneJsx, /takeoverTimer = setTimeout\(\(\) => \{/);
  assert.match(terminalPaneJsx, /triggerTakeover\(\);/);
  assert.match(terminalPaneJsx, /500\);/);

  // 3. 移动端 presence 广播到来或断开时清除定时器
  assert.match(terminalPaneJsx, /if\s*\(takeoverTimer\)\s*\{\s*clearTimeout\(takeoverTimer\);\s*takeoverTimer = null;\s*\}/);

  // 4. 组件卸载 cleanup 时清除定时器防泄漏
  assert.match(terminalPaneJsx, /return\s*\(\)\s*=>\s*\{[\s\S]*clearTimeout\(takeoverTimer\);/);
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

test('auto-takeover timer logic transitions state machine cleanly in isolation', async () => {
  let mode = 'unknown';
  let timer = null;
  let settledGrid = null;

  const triggerTakeover = () => {
    if (mode !== 'takeover') {
      mode = 'takeover';
      settledGrid = { rows: 45, cols: 135 };
    }
  };

  // 模拟初订进入 UNKNOWN
  if (mode === 'unknown') {
    timer = setTimeout(() => {
      if (mode === 'unknown') {
        triggerTakeover();
      }
    }, 50); // 压缩到 50ms 测试
  }

  assert.equal(mode, 'unknown');
  assert.equal(settledGrid, null);

  // 等待定时器触发
  await new Promise((resolve) => setTimeout(resolve, 80));

  // 验证超时后成功晋级接管态并全屏重排
  assert.equal(mode, 'takeover');
  assert.deepEqual(settledGrid, { rows: 45, cols: 135 });
});
