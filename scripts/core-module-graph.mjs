// Inspect Vite's resolved product graph, not strings in a compressed bundle.
import assert from 'node:assert/strict';
import { build } from 'vite';

const modules = new Set();
await build({ build: { write: false }, plugins: [{
  name: 'core-module-graph',
  generateBundle() { for (const id of this.getModuleIds()) modules.add(id); },
}] });
const direct = [...modules].filter(id => id.includes('/deps/corral-core/web/js/')).sort();
console.log(JSON.stringify({ direct, copied: [...modules].filter(id => id.includes('/vendor/agentmirror/')) }, null, 2));
for (const name of ['client', 'protocol', 'binary', 'scrollback']) {
  assert.ok(direct.some(id => id.endsWith(`/${name}.js`)), `product graph must include core ${name}`);
}
assert.ok(![...modules].some(id => id.includes('/vendor/agentmirror/')), 'product graph must not include copied core');
