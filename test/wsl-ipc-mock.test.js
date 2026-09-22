import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, chmod, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const root = new URL('../', import.meta.url);

async function readSources() {
  const rust = await readFile(new URL('src-tauri/src/wsl.rs', root), 'utf8');
  const main = await readFile(new URL('src-tauri/src/main.rs', root), 'utf8');
  const native = await readFile(new URL('src/core/nativeCapabilities.js', root), 'utf8');
  const script = rust.match(/const TOKEN_READ_SCRIPT: &str = r#"([\s\S]*?)"#;/)?.[1];
  assert.ok(script, 'TOKEN_READ_SCRIPT must remain extractable for the IPC harness');
  return { rust, main, native, script };
}

function runScript(script, env) {
  return spawnSync('/bin/sh', ['-c', script], {
    env: { ...process.env, HOME: env.home },
    encoding: 'utf8',
  });
}

async function fakeHomes() {
  const base = await mkdtemp(join(tmpdir(), 'agentmirror-wsl-ipc-'));
  const defaultHome = join(base, 'default');
  const ownerHome = join(base, 'home', 'alaudalancy');
  await mkdir(join(defaultHome, '.config', 'agentmirror'), { recursive: true });
  await mkdir(join(ownerHome, '.config', 'agentmirror'), { recursive: true });
  return { base, defaultHome, ownerHome };
}

test('Issue 217 Tier 1: WSL token bridge uses root and all user-home fallbacks', async () => {
  const { rust, main, native, script } = await readSources();
  assert.match(rust, /run_wsl\(&\["-d", distribution, "-u", "root", "-e", "sh", "-lc", script\]\)/);
  assert.match(rust, /head -c 257/);
  assert.match(script, /\$HOME\/\.config\/agentmirror\/token/);
  assert.match(script, /\/home\/\*\/\.config\/agentmirror\/token/);
  assert.match(script, /\/proc\/\$pid\/status/);
  assert.match(native, /invoke\('get_wsl_pairing_token'\)/);
  assert.match(native, /invoke\('read_wsl_service_token'\)/);
  assert.match(main, /wsl::get_wsl_pairing_token/);
});

test('Issue 217 Tier 1: token file under configured HOME is readable with 0600 mode', async () => {
  const { base, defaultHome } = await fakeHomes();
  const { script } = await readSources();
  try {
    const tokenPath = join(defaultHome, '.config', 'agentmirror', 'token');
    await writeFile(tokenPath, 'HOME-TOKEN-123\n', { mode: 0o600 });
    await chmod(tokenPath, 0o600);
    const result = runScript(script, { home: defaultHome });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'HOME-TOKEN-123\n');
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test('Issue 217 Tier 1: wrong default HOME falls through to another WSL user home', async () => {
  const { base, defaultHome, ownerHome } = await fakeHomes();
  const { script } = await readSources();
  try {
    const tokenPath = join(ownerHome, '.config', 'agentmirror', 'token');
    await writeFile(tokenPath, 'OWNER-TOKEN-456\n', { mode: 0o600 });
    await chmod(tokenPath, 0o600);
    const portableScript = script.replaceAll(
      '/home/*/.config/agentmirror/token',
      `${base}/home/*/.config/agentmirror/token`,
    ).replaceAll(
      '/root/.config/agentmirror/token',
      `${base}/root/.config/agentmirror/token`,
    );
    const result = runScript(portableScript, { home: defaultHome });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'OWNER-TOKEN-456\n');
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test('Issue 217 Tier 1: hot runner is fail-closed and never targets system installs', async () => {
  const script = await readFile(new URL('scripts/windows-5090-hot-runner.ps1', root), 'utf8');
  assert.match(script, /AllowTestCleanup/);
  assert.match(script, /Fail-closed/);
  assert.match(script, /Program Files/);
  assert.match(script, /Refusing a non-disposable test root/);
  assert.match(script, /Refusing to run an executable outside the disposable test root/);
  assert.match(script, /WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS/);
  assert.match(script, /windows-5090-startup-receipt\.mjs/);
  assert.match(script, /Stop-ExactServicePids/);
  assert.match(script, /tokenValuesOmitted = \$true/);
});
