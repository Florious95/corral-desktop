#!/usr/bin/env node
import { createReadStream, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const file = '/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-r2scan/.team/nodes/garble/sweep-full-2.jsonl';
const want = '/tmp/tmux-501/ta-a9fd5b7defbd\u001f%90';

const pos = [];
const neg = [];
const rl = createInterface({ input: createReadStream(file) });
for await (const line of rl) {
  if (!line.trim()) continue;
  const r = JSON.parse(line);
  if (r.session_ref !== want) continue;
  const slim = {
    garbled: r.garbled,
    round: r.round,
    settle_ms: r.settle_ms,
    click_to_sub: r.click_to_sub,
    sub_to_snap: r.sub_to_snap,
    host_cols: r.host_cols,
    host_rows: r.host_rows,
    listing_seq: r.listing_seq,
    local_cols: r.local_cols,
    local_rows: r.local_rows,
    max_line_chars: r.max_line_chars,
    max_line_has_wide: r.max_line_has_wide,
    events: (r.dump?.events || []).map((e) => {
      const o = { seq: e.seq, type: e.type };
      for (const k of Object.keys(e)) {
        if (['t', 'seq', 'type'].includes(k)) continue;
        o[k] = e[k];
      }
      o.t = e.t;
      return o;
    }),
  };
  if (r.garbled) pos.push(slim);
  else neg.push(slim);
}
writeFileSync(join(here, 'pair2-pos.json'), JSON.stringify(pos[0], null, 2));
writeFileSync(join(here, 'pair2-neg.json'), JSON.stringify(neg[0], null, 2));
console.error('pos rounds', pos.map((p) => p.round), 'neg', neg.map((p) => p.round));
console.error('pos0 bytes', pos[0].events.find((e) => e.type === 'snapshot'));
console.error('neg0 bytes', neg[0].events.find((e) => e.type === 'snapshot'));
console.error('pos0 label', pos[0].events.find((e) => e.type === 'garble_label'));
console.error('neg0 label', neg[0].events.find((e) => e.type === 'garble_label'));
console.error('pos0 sub', pos[0].events.find((e) => e.type === 'subscribe'));
console.error('neg0 sub', neg[0].events.find((e) => e.type === 'subscribe'));
