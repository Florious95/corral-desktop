import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdir } from 'node:fs/promises';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DEFAULT_LAUNCHERS } from '../src/core/providers.js';
import { DeviceManager } from '../src/core/devices.js';
import { assertIssueReceipt } from '../scripts/windows-web-mac-mcp-gate.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));

async function sourceFiles(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...await sourceFiles(path));
    else if (/\.(css|js|jsx)$/.test(entry.name)) out.push(path);
  }
  return out;
}

let source;
async function allSource() {
  if (!source) {
    const files = await sourceFiles(join(root, 'src'));
    source = (await Promise.all(files.map(async (path) => (
      `\n/* ${relative(root, path)} */\n${await import('node:fs/promises').then(({ readFile }) => readFile(path, 'utf8'))}`
    )))).join('\n');
  }
  return source;
}

function assertSettingKey(text, key) {
  assert.match(text, new RegExp(`['"]${key.replace('.', '\\.') }['"]|\\b${key.replace('.', '\\.') }\\b`), `missing observable setting key ${key}`);
}

test('#191 close notice is time-bounded and resets when focus changes', async () => {
  const text = await allSource();
  assert.match(text, /(?:agent|Agent)\s*已关闭/);
  assert.match(text, /(?:2500|2\.5\s*\*\s*1000)/, 'close notice must use a 2.5 second deadline');
  assert.match(text, /setTimeout\s*\(/, 'close notice must be cleared by a timer');
  assert.match(text, /(?:activeKey|activePane|activeTab)[\s\S]{0,240}(?:setToastMsg|set.*Notice|set.*Status)\s*\(\s*null/);
});

test('#193 terminal typography settings are observable, bounded, persisted, and fitted live', async () => {
  const text = await allSource();
  assertSettingKey(text, 'terminal.fontFamily');
  assertSettingKey(text, 'terminal.fontSize');
  assert.match(text, /chr-setting-font-family|aria-label=[{"'][^"']*font family/i);
  assert.match(text, /chr-setting-font-size|aria-label=[{"'][^"']*font size/i);
  assert.match(text, /fontFamily/);
  assert.match(text, /fontSize/);
  assert.match(text, /(?:Math\.min\s*\(\s*24|24\s*[,)]).*?(?:Math\.max\s*\(\s*10|10\s*[,)]|clamp\s*\(\s*10)/s, 'font size must be clamped to 10px–24px');
  assert.match(text, /term\.options\.fontFamily|options\s*\.\s*fontFamily/);
  assert.match(text, /term\.options\.fontSize|options\s*\.\s*fontSize/);
  assert.match(text, /\.fit\s*\(/, 'typography updates must refit active terminals');
});

test('#194 Tab rename exposes edit, cancel, lock, and reset behavior', async () => {
  const text = await allSource();
  assert.match(text, /chr-tab-title-input/);
  assert.match(text, /data-title-locked/);
  assert.match(text, /onDoubleClick/);
  assert.match(text, /(?:Escape|key\s*===\s*['"]Esc)/);
  assert.match(text, /(?:isCustomTitle|titleLocked)/);
  assert.match(text, /(?:恢复自动标题|Reset Title|resetTitle)/i);
  assert.match(text, /list_delta|changed_sessions|window.*rename/i);
});

test('#195 directory tracking defaults off, persists, and scrolls the selected path into view', async () => {
  const text = await allSource();
  assertSettingKey(text, 'directoryTracking');
  assert.match(text, /chr-setting-dir-tracking|aria-label=[{"'][^"']*(?:directory tracking|目录跟踪)/i);
  assert.match(text, /directoryTracking\s*:\s*false|useState\s*\(\s*false\s*\)/);
  assert.match(text, /scrollIntoView\s*\(\s*\{[\s\S]{0,120}block\s*:\s*['"]nearest['"]/);
  assert.match(text, /expanded\s*[:=]\s*true|set.*Expanded/);
});

test('#196 terminal viewport reserves exactly 5px and fit measures the content box without overflow', async () => {
  const text = await allSource();
  const terminalCss = text.match(/\/\* src\/components\/terminal\/terminal\.css \*\/[\s\S]*/)?.[0] || text;
  const paneRule = terminalCss.match(/\.terminalpane\s*\{([^}]*)\}/)?.[1] || '';
  assert.match(paneRule, /padding\s*:\s*5px\s*;/, 'terminalpane must reserve 5px on all sides');
  assert.match(paneRule, /box-sizing\s*:\s*border-box\s*;/);
  assert.match(text, /clientWidth/);
  assert.match(text, /clientHeight/);
  assert.match(text, /Math\.floor\s*\(\s*w\s*\/\s*cell\.w\s*\)/);
  assert.match(text, /Math\.floor\s*\(\s*h\s*\/\s*cell\.h\s*\)/);
});

test('#187 Pi launcher is advertised and create payload keeps provider and bypass fields', () => {
  const pi = DEFAULT_LAUNCHERS.find((launcher) => launcher.provider === 'pi');
  assert.deepEqual(pi, { provider: 'pi', display_name: 'Pi', supports_bypass: true });

  const sent = [];
  const dm = new DeviceManager({
    storage: null,
    seedDevices: [{ id: 'local', name: 'Local', url: 'ws://127.0.0.1:9900/ws', token: '' }],
    autoLocal: false,
  });
  dm._clients.set('local', {
    isReady: true,
    createAgent(payload) { sent.push(payload); return 7; },
  });
  assert.deepEqual(dm.createAgent({
    deviceId: 'local', workspace: '/work', anchorRef: 'default\\x1f%0',
    provider: 'pi', name: 'pi task', bypass: true,
  }), { deviceId: 'local', reqId: 7 });
  assert.deepEqual(sent, [{
    workspace: '/work', anchor_ref: 'default\\x1f%0', provider: 'pi', name: 'pi task', bypass: true,
  }]);
});

test('#188 default and private tmux sockets coexist in one workspace without overwrite', () => {
  const dm = new DeviceManager({
    storage: null,
    seedDevices: [{ id: 'local', name: 'Local', url: 'ws://127.0.0.1:9900/ws', token: '' }],
    autoLocal: false,
  });
  dm._clients.set('local', {
    isReady: true,
    workspaces: [{
      cwd: '/work/project', session_count: 2, aggregate_state: 'idle',
      sessions: [
        { ref: '/tmp/tmux-1000/default\\x1f%0', name: 'default-agent', cwd: '/work/project', status: 'idle', provider: 'pi' },
        { ref: '/tmp/tmux-1000/ta-private\\x1f%1', name: 'private-agent', cwd: '/work/project', status: 'working', provider: 'pi' },
      ],
    }],
  });
  dm._status.set('local', { state: 'ready' });
  dm._listingFresh.set('local', true);
  const sessions = dm.workspaces[0]?.sessions || [];
  assert.equal(dm.workspaces.length, 1);
  assert.equal(sessions.length, 2);
  assert.deepEqual(sessions.map((session) => session.ref), [
    '/tmp/tmux-1000/default\\x1f%0', '/tmp/tmux-1000/ta-private\\x1f%1',
  ]);
  assert.equal(new Set(sessions.map((session) => session.uid)).size, 2);
});

test('MCP issue gate rejects padding, overflow, console errors, and drag jitter', () => {
  assert.doesNotThrow(() => assertIssueReceipt({
    issues: { viewport: { paddingIsFive: true, noOverflow: true }, consoleErrors: [] },
    drag: { pointerCaptureReleased: true, maxWidthDelta: 1 },
  }));
  assert.throws(
    () => assertIssueReceipt({ issues: { viewport: { paddingIsFive: false } } }),
    (error) => error.details?.failures?.some((failure) => failure.includes('5px')),
  );
  assert.throws(
    () => assertIssueReceipt({ issues: { viewport: { noOverflow: false } } }),
    (error) => error.details?.failures?.some((failure) => failure.includes('overflow')),
  );
  assert.throws(
    () => assertIssueReceipt({ issues: { consoleErrors: ['boom'] } }),
    (error) => error.details?.failures?.some((failure) => failure.includes('CONSOLE')),
  );
  assert.throws(
    () => assertIssueReceipt({ drag: { pointerCaptureReleased: false } }),
    (error) => error.details?.failures?.some((failure) => failure.includes('pointer capture')),
  );
  assert.throws(
    () => assertIssueReceipt({ drag: { maxWidthDelta: 3 } }),
    (error) => error.details?.failures?.some((failure) => failure.includes('jitter')),
  );
});

export { allSource };
