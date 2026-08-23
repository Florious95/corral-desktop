#!/usr/bin/env node
// t.sweep2 runner. write_paths 只有 .team/nodes/garble/：复制夹具并补丁。
// ⛔ 不改产品码。#68 未合 main，Vite --app-root 指向含新埋点的 wt-deepen。
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const here = dirname(fileURLToPath(import.meta.url));
const wt = join(here, '../../..');
const deepen = resolveDeepen();
const src = readFileSync(join(wt, 'scripts/garble-sweep.mjs'), 'utf8');

function resolveDeepen() {
  return '/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-deepen';
}

const patched = src
  .replace(
    "const WT = join(here, '..');",
    "const WT = join(here, '../../..');",
  )
  .replace(
    'return rowFromDump({ round, uid, protoRef: proto, dump, timedOut });',
    `const row = rowFromDump({ round, uid, protoRef: proto, dump, timedOut });
  const events = dump.events || [];
  const sub = [...events].reverse().find((e) => e.type === 'subscribe' && e.ref === proto)
    || [...events].reverse().find((e) => e.type === 'subscribe');
  const g = lastGarble(events, proto);
  row.host_rows = sub && sub.host_rows != null ? sub.host_rows : null;
  row.host_cols = sub && sub.host_cols != null ? sub.host_cols : null;
  row.listing_seq = sub && sub.listing_seq != null ? sub.listing_seq : null;
  row.max_line_chars = g && g.max_line_chars != null ? g.max_line_chars : null;
  row.max_line_has_wide = g && g.max_line_has_wide != null ? g.max_line_has_wide : null;
  if (row.listing_cols == null && row.host_cols != null) row.listing_cols = row.host_cols;
  if (row.listing_rows == null && row.host_rows != null) row.listing_rows = row.host_rows;
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
    "join(WT, '.team/nodes/garble/sweep-full-2.jsonl')",
  )
  .replace(
    'const DEFAULT_APP_ROOT = resolve(WT, \'../wt-inst\');',
    `const DEFAULT_APP_ROOT = ${JSON.stringify(deepen)};`,
  )
  .replace(
    'if (snap && label) break;',
    'if (snap && label) { await sleep(120); break; }',
  )
  .replace(
    'console.error(`sweep rows=${sampleRows.length} sessions=${agents.length} rounds=${opt.rounds} out=${opt.out}`);',
    "console.error(`[sweep2] rows=${sampleRows.length} sessions=${agents.length} rounds=${opt.rounds} out=${opt.out} app=${opt.appRoot}`);",
  )
  .replace(
    'for (let round = 1; round <= opt.rounds; round++) {\n      for (const ag of agents) {',
    "for (let round = 1; round <= opt.rounds; round++) {\n      console.error(`[sweep2] round ${round}/${opt.rounds} sessions=${agents.length}`);\n      for (const ag of agents) {",
  );

const outJs = join(here, '_sweep2-patched.mjs');
writeFileSync(outJs, patched);
mkdirSync(here, { recursive: true });

const child = spawn(process.execPath, [
  outJs,
  '--rounds', '10',
  '--timeout-ms', '5000',
  '--skip-self-check',
  '--port', '1457',
  '--cdp', '9353',
  '--app-root', deepen,
  '--out', join(here, 'sweep-full-2.jsonl'),
], { cwd: wt, stdio: 'inherit' });

child.on('exit', (code) => process.exit(code ?? 1));
