import { readdirSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const root = fileURLToPath(new URL('..', import.meta.url));
const testDir = join(root, 'test');

const files = readdirSync(testDir)
  .filter((file) => file.endsWith('.test.js'))
  .sort()
  .map((file) => join('test', file));

if (files.length === 0) {
  console.error('No test files found in test directory');
  process.exit(1);
}

const extraArgs = process.argv.slice(2);
const child = spawn(process.execPath, ['--test', ...extraArgs, ...files], {
  cwd: root,
  stdio: 'inherit',
});

child.on('error', (err) => {
  console.error('Failed to spawn test runner:', err);
  process.exit(1);
});

child.on('exit', (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
  } else {
    process.exit(code ?? 0);
  }
});
