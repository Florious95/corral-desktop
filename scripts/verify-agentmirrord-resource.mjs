import { readFileSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';

const resource = resolve('src-tauri/resources/agentmirrord-linux-amd64');
const stat = statSync(resource, { throwIfNoEntry: false });
if (!stat?.isFile() || stat.size === 0) {
  throw new Error(`missing bundled Linux service: ${resource}`);
}

const contents = readFileSync(resource, { encoding: null, flag: 'r' });
const header = contents.subarray(0, 20);
const isElf64LeX86 =
  header.length >= 20 &&
  header[0] === 0x7f &&
  header[1] === 0x45 &&
  header[2] === 0x4c &&
  header[3] === 0x46 &&
  header[4] === 2 &&
  header[5] === 1 &&
  header[18] === 0x3e &&
  header[19] === 0;
if (!isElf64LeX86) {
  throw new Error('bundled Linux service is not an ELF x86_64 executable');
}
// This is the exact go:embed input, not a separately maintained list of hashes.
const manifestBytes = readFileSync(resolve('src-tauri/resources/agentmirrord-nodeprobe-manifest.json'));
assert.ok(contents.includes(manifestBytes), 'daemon does not embed the accepted manifest bytes');
const manifest = JSON.parse(manifestBytes);
assert.equal(manifest.platform, 'linux/amd64');
const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');
const check = (name, coordinate) => {
  const bytes = readFileSync(resolve('src-tauri/resources', name));
  assert.equal(digest(bytes), coordinate.sha256, `${name} differs from daemon capability`);
  if (coordinate.size != null) assert.equal(bytes.length, coordinate.size, `${name} size differs`);
};
check('nodeprobe-linux-amd64', manifest.binary);
check('nodeprobe-pi-activity.js', manifest.pi_extension);
assert.equal(manifest.corpora.length, 2);
for (const [source, resourceName] of [
  ['tools/nodeprobe/fixtures/titles.tsv', 'nodeprobe-titles.tsv'],
  ['tools/nodeprobe/fixtures/providers.tsv', 'nodeprobe-providers.tsv'],
]) {
  const coordinate = manifest.corpora.find((item) => item.path === source);
  assert.ok(coordinate, `missing canonical corpus ${source}`);
  check(resourceName, coordinate);
}
const build = JSON.parse(readFileSync(resolve('src-tauri/resources/agentmirrord-build.json')));
assert.equal(build.repository, 'https://github.com/Florious95/corral-core');
assert.match(build.commit, /^[0-9a-f]{40}$/, 'expected an exact daemon source commit');
assert.match(build.tree, /^[0-9a-f]{40}$/, 'expected an exact daemon source tree');
assert.equal(digest(contents), build.sha256, 'daemon differs from recorded build');
assert.equal(contents.length, build.size, 'daemon size differs from recorded build');
console.log(`Bundled agentmirrord verified (${build.commit}, ${stat.size} bytes); all nodeprobe resources match.`);
