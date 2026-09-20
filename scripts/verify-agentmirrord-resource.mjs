import { readFileSync, statSync } from 'node:fs';
import { resolve } from 'node:path';

const resource = resolve('src-tauri/resources/agentmirrord-linux-amd64');
const stat = statSync(resource, { throwIfNoEntry: false });
if (!stat?.isFile() || stat.size === 0) {
  throw new Error(`missing bundled Linux service: ${resource}`);
}

const header = readFileSync(resource, { encoding: null, flag: 'r' }).subarray(0, 20);
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

console.log(`Bundled agentmirrord is ready (${stat.size} bytes).`);
