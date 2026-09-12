import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const sha = '05e234374a05aea092de6aabd9f928b3f9ddbbfc';
const path = 'deps/corral-core';
const git = (...args) => execFileSync('git', args, { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
try {
  if (!existsSync(`${root}/${path}/.git`)) throw new Error('dependency is missing');
  if (git('ls-files', '--stage', '--', path) !== `160000 ${sha} 0\t${path}`) throw new Error('gitlink differs from the pinned core SHA');
  if (git('-C', path, 'rev-parse', 'HEAD') !== sha) throw new Error('checkout differs from the pinned core SHA');
  if (git('-C', path, 'status', '--porcelain', '--untracked-files=all')) throw new Error('dependency has local changes');
  for (const name of ['client', 'protocol', 'binary', 'scrollback']) {
    if (!existsSync(`${root}/${path}/web/js/${name}.js`)) throw new Error(`missing web/js/${name}.js`);
  }
  console.log(`corral-core ${sha}: clean, direct source dependency ready`);
} catch (error) {
  console.error(`corral-core unavailable: ${error.message}. Run npm run core:init; preserve any local dependency edits before restoring the pinned checkout.`);
  process.exitCode = 1;
}
