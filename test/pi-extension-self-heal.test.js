import assert from 'node:assert/strict';
import { rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

const extensionPath = new URL('../src-tauri/resources/nodeprobe-pi-activity.js', import.meta.url).href;

test('Pi activity extension recreates a missing socket without losing working state', {
  skip: process.platform === 'win32' && 'Pi runs in WSL; filesystem sockets require a Unix host',
}, () => {
  // A short relative path also stays within the Unix socket pathname limit.
  const dir = `.pi-heal-${process.pid}`;
  rmSync(dir, { recursive: true, force: true });
  const script = String.raw`
    import assert from 'node:assert/strict';
    import { createConnection } from 'node:net';
    import { existsSync, readFileSync, unlinkSync } from 'node:fs';
    const { default: extension } = await import(process.env.EXTENSION_PATH);
    const handlers = new Map();
    extension({ on(event, handler) { handlers.set(event, handler); } });
    const ctx = { sessionManager: { getSessionName: () => 'issue-234' } };
    const read = () => JSON.parse(readFileSync(process.env.NODEPROBE_PI_ACTIVITY_DIR + '/' + process.pid + '.json', 'utf8'));
    const challenge = (path) => new Promise((resolve, reject) => {
      const socket = createConnection(path);
      let data = '';
      socket.on('data', (chunk) => { data += chunk; });
      socket.on('error', reject);
      socket.on('end', () => resolve(JSON.parse(data)));
      socket.on('connect', () => socket.end(JSON.stringify({ challenge: 'heal' }) + '\n'));
    });
    await handlers.get('session_start')({}, ctx);
    await handlers.get('agent_start')({});
    const record = read();
    assert.equal(record.activity, 'working');
    unlinkSync(record.socket_path);
    assert.equal(existsSync(record.socket_path), false);
    await new Promise((resolve) => setTimeout(resolve, 1200));
    assert.equal(existsSync(record.socket_path), true);
    const reply = await challenge(record.socket_path);
    assert.equal(reply.activity, 'working');
    await handlers.get('session_shutdown')({});
    assert.equal(existsSync(record.socket_path), false);
  `;
  try {
    const result = spawnSync(process.execPath, ['--input-type=module', '-e', script], {
      cwd: process.cwd(),
      env: { ...process.env, EXTENSION_PATH: extensionPath, NODEPROBE_PI_ACTIVITY_DIR: dir },
      encoding: 'utf8',
      timeout: 5000,
    });
    assert.equal(result.status, 0, result.stderr || result.stdout);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
