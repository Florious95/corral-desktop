import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import { providerOf } from '../src/core/devices.js';
import {
  inferProvider,
  inferCanonicalProvider,
  normalizeProvider,
} from '../src/core/providers.js';

test('providerOf resolves "pi" accurately across absent, empty, and unknown server values', () => {
  // 核心断言：providerOf('pi') === 'pi'
  assert.equal(providerOf('pi'), 'pi');
  assert.equal(providerOf('pi', undefined), 'pi');
  assert.equal(providerOf('pi', null), 'pi');
  assert.equal(providerOf('pi', ''), 'pi');
  assert.equal(providerOf('pi', 'unknown'), 'pi');
  assert.equal(providerOf('pi-worker', 'unknown'), 'pi');
  assert.equal(providerOf('team_pi_node', 'unknown'), 'pi');
  assert.equal(providerOf('pi', 'pi'), 'pi');

  // 非 pi 会话保持既有权威与归一化语义
  assert.equal(providerOf('codex-run', undefined), 'codex');
  assert.equal(providerOf('codex-run', 'codex'), 'codex');
  assert.equal(providerOf('codex-run', 'unknown'), 'unknown');
  assert.equal(providerOf('random-task', undefined), 'unknown');
});

test('inferProvider accurately matches pi sessions without substring false-positives', () => {
  // 正确识别包含 pi 语义的会话名
  assert.equal(inferProvider('pi'), 'pi');
  assert.equal(inferProvider('PI'), 'pi');
  assert.equal(inferProvider('pi-0.85'), 'pi');
  assert.equal(inferProvider('my-pi-agent'), 'pi');
  assert.equal(inferProvider('task_pi_worker'), 'pi');
  assert.equal(inferCanonicalProvider('pi'), 'pi');
  assert.equal(normalizeProvider('pi'), 'pi');

  // 严禁误伤包含 pi 子串的普通单词
  assert.equal(inferProvider('copilot-task'), null);
  assert.equal(inferCanonicalProvider('copilot-task'), 'unknown');
  assert.equal(inferProvider('spin'), null);
  assert.equal(inferProvider('api-server'), null);
  assert.equal(inferProvider('opinion'), null);
  assert.equal(inferProvider('epic'), null);
});

test('ProviderIcon renders dedicated PiIcon SVG and prevents "U" fallback', async () => {
  const providerIconJsx = await readFile(
    new URL('../src/components/sidebar/ProviderIcon.jsx', import.meta.url),
    'utf8',
  );

  // 1. 必须导出或定义专用的 PiIcon 官方 SVG 几何组件
  assert.match(providerIconJsx, /export function PiIcon/);
  assert.match(providerIconJsx, /data-provider="pi"/);
  assert.match(providerIconJsx, /viewBox="0 0 24 24"/);

  // 2. 当 provider === 'pi' 时优先拦截并直接渲染 PiIcon
  assert.match(providerIconJsx, /if\s*\(provider\s*===\s*'pi'\)\s*\{\s*return\s*<PiIcon/);

  // 3. 验证结构：绝不让 pi 穿透走兜底首字母圆圈（防止渲染出 Unknown 的大写字母 'U'）
  const fallbackMatch = providerIconJsx.match(/provider\?\.\[0\]\?\.toUpperCase\(\)\s*\?\?\s*'\?'/);
  assert.ok(fallbackMatch, 'Fallback initial placeholder exists for genuinely unknown providers');

  // 4. 确保在 provider === 'pi' 分支返回之后才出现 fallback 代码
  const piBranchIndex = providerIconJsx.indexOf("provider === 'pi'");
  const fallbackIndex = providerIconJsx.indexOf('provider?.[0]?.toUpperCase()');
  assert.ok(piBranchIndex > 0 && fallbackIndex > piBranchIndex, 'pi branch must return before fallback');
});

test('fullscreen styles in app.css and chrome.css guarantee edge-to-edge immersive experience', async () => {
  const appCss = await readFile(new URL('../src/styles/app.css', import.meta.url), 'utf8');
  const chromeCss = await readFile(new URL('../src/components/chrome/chrome.css', import.meta.url), 'utf8');

  // 1. app.css: app-root.is-fullscreen 100% 贴合视口边缘，消除外边距与圆角
  assert.match(appCss, /\.app-root\.is-fullscreen\s*\{[^}]*width:\s*100vw;/);
  assert.match(appCss, /\.app-root\.is-fullscreen\s*\{[^}]*height:\s*100vh;/);
  assert.match(appCss, /\.app-root\.is-fullscreen\s*\{[^}]*margin:\s*0;/);
  assert.match(appCss, /\.app-root\.is-fullscreen\s*\{[^}]*padding:\s*0;/);
  assert.match(appCss, /\.app-root\.is-fullscreen\s*\{[^}]*border-radius:\s*0;/);

  // 2. app.css: 容器与舞台区域自适应贴合
  assert.match(appCss, /\.app-root\.is-fullscreen \.app-body\s*\{[^}]*width:\s*100%;/);
  assert.match(appCss, /\.app-root\.is-fullscreen \.app-body\s*\{[^}]*height:\s*100%;/);
  assert.match(appCss, /\.app-root\.is-fullscreen \.main-stage-container\s*\{[^}]*border-radius:\s*0;/);

  // 3. chrome.css: 全屏顶栏消除投影、边框，贴合视口顶边
  assert.match(chromeCss, /\.app-root\.is-fullscreen \.tb,/);
  assert.match(chromeCss, /\.app-root\.is-fullscreen \.tb-session-header,/);
  assert.match(chromeCss, /box-shadow:\s*none;/);
  assert.match(chromeCss, /border-radius:\s*0;/);
  assert.match(chromeCss, /border-top:\s*0;/);
});
