#!/usr/bin/env node
// t.sweep runner. write_paths 不含 scripts/：从夹具复制一份，给每行补上完整 dump()。
// ⛔ 不改产品码。跳过自检 WS 改写，避免污染 10 轮真数据。
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const wt = join(here, '../../..');
const src = readFileSync(join(wt, 'scripts/garble-sweep.mjs'), 'utf8');

const patched = src
  .replace(
    'return rowFromDump({ round, uid, protoRef: proto, dump, timedOut });',
    `const row = rowFromDump({ round, uid, protoRef: proto, dump, timedOut });
  row.dump = {
    seq: dump.seq ?? null,
    dropped: dump.dropped ?? 0,
    length: dump.length ?? (dump.events || []).length,
    events: dump.events || [],
    settle: dump.settle || {},
  };
  return row;`,
  )
  .replace('skipSelfCheck: false', 'skipSelfCheck: true')
  .replace(
    "join(WT, '.team/nodes/garble/sweep-sample.jsonl')",
    "join(WT, '.team/nodes/garble/sweep-full.jsonl')",
  )
  .replace(
    'const DEFAULT_APP_ROOT = resolve(WT, \'../wt-inst\');',
    'const DEFAULT_APP_ROOT = WT;',
  )
  .replace(
    'console.error(`sweep rows=${sampleRows.length} sessions=${agents.length} rounds=${opt.rounds} out=${opt.out}`);',
    "console.error(`[sweep] rows=${sampleRows.length} sessions=${agents.length} rounds=${opt.rounds} out=${opt.out}`);",
  )
  .replace(
    'for (let round = 1; round <= opt.rounds; round++) {\n      for (const ag of agents) {',
    "for (let round = 1; round <= opt.rounds; round++) {\n      console.error(`[sweep] round ${round}/${opt.rounds} sessions=${agents.length}`);\n      for (const ag of agents) {",
  );

const outJs = join(here, '_sweep-patched.mjs');
writeFileSync(outJs, patched);
mkdirSync(here, { recursive: true });

const child = spawn(process.execPath, [
  outJs,
  '--rounds', '10',
  '--timeout-ms', '5000',
  '--skip-self-check',
  '--port', '1447',
  '--cdp', '9343',
  '--app-root', wt,
  '--out', join(here, 'sweep-full.jsonl'),
], { cwd: wt, stdio: 'inherit' });

child.on('exit', (code) => process.exit(code ?? 1));
