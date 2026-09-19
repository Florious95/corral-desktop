import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

import { providerOf } from '../src/core/devices.js';
import {
  inferProvider,
  inferCanonicalProvider,
  normalizeProvider,
  DEFAULT_LAUNCHERS,
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

test('ProviderIcon maps full official provider suite from native assets without fake Greek letter pi', async () => {
  const providerIconJsx = await readFile(
    new URL('../src/components/sidebar/ProviderIcon.jsx', import.meta.url),
    'utf8',
  );

  // 1. 严禁包含手写的希腊字母 π 字符代码或伪劣自绘 SVG
  assert.doesNotMatch(providerIconJsx, /export function PiIcon/);
  assert.doesNotMatch(providerIconJsx, /<rect width="24" height="24"/);

  // 2. 必须引入官方正版资源
  assert.match(providerIconJsx, /import claudeCodeUrl from '.*provider_icon_claude_code\.svg';/);
  assert.match(providerIconJsx, /import codexUrl from '.*provider_icon_codex\.svg';/);
  assert.match(providerIconJsx, /import cursorUrl from '.*provider_icon_cursor\.svg';/);
  assert.match(providerIconJsx, /import grokUrl from '.*provider_grok\.png';/);
  assert.match(providerIconJsx, /import copilotUrl from '.*provider_copilot_color\.png';/);
  assert.match(providerIconJsx, /import piUrl from '.*provider_pi\.png';/);

  // 3. ICONS 映射表必须完整涵盖所有 6 大主流官方 Provider 及其别名
  assert.match(providerIconJsx, /claude_code:\s*\[claudeCodeUrl,\s*claudeCodeUrl\]/);
  assert.match(providerIconJsx, /codex:\s*\[codexUrl,\s*codexUrl\]/);
  assert.match(providerIconJsx, /cursor:\s*\[cursorUrl,\s*cursorUrl\]/);
  assert.match(providerIconJsx, /grok:\s*\[grokUrl,\s*grokUrl\]/);
  assert.match(providerIconJsx, /copilot:\s*\[copilotUrl,\s*copilotUrl\]/);
  assert.match(providerIconJsx, /pi:\s*\[piUrl,\s*piUrl\]/);
});

test('DEFAULT_LAUNCHERS and NewAgentDialog provide full provider selection fallback', async () => {
  const dialogJsx = await readFile(
    new URL('../src/components/chrome/NewAgentDialog.jsx', import.meta.url),
    'utf8',
  );

  // 1. 核心常量：DEFAULT_LAUNCHERS 必须包含全部 5 大官方主流 Provider
  assert.ok(Array.isArray(DEFAULT_LAUNCHERS));
  const providers = DEFAULT_LAUNCHERS.map((l) => l.provider);
  assert.ok(providers.includes('claude_code'));
  assert.ok(providers.includes('codex'));
  assert.ok(providers.includes('cursor'));
  assert.ok(providers.includes('grok'));
  assert.ok(providers.includes('pi'));

  // 2. NewAgentDialog 引入 DEFAULT_LAUNCHERS 并在未广告时自动兜底呈现
  assert.match(dialogJsx, /import\s*\{\s*DEFAULT_LAUNCHERS\s*\}\s*from/);
  assert.match(dialogJsx, /effectiveLaunchers/);
  assert.match(dialogJsx, /DEFAULT_LAUNCHERS/);
});

test('App.jsx intercepts close_session unsupported_type and removes session without 10s hang', async () => {
  const appJsx = await readFile(new URL('../src/App.jsx', import.meta.url), 'utf8');

  // 1. 维护 closePendingRef
  assert.match(appJsx, /const closePendingRef = useRef/);

  // 2. 在 onError 与 close_session_result 中拦截 unsupported_type
  assert.match(appJsx, /unsupported_type/);
  assert.match(appJsx, /服务端当前不支持远端销毁会话，已从工作台移出/);
  assert.match(appJsx, /removeSessionFromWorkspace/);
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
