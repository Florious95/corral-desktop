// One-shot stats for SWEEP-REPORT. No root-cause. Prints JSON to stdout.
import { createReadStream, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const file = join(here, 'sweep-full.jsonl');

const REQUIRED_TYPES = [
  'activate', 'subscribe', 'unsubscribe', 'listing', 'list_delta',
  'snapshot', 'delta', 'scrollback', 'fit', 'term_resize', 'resize_up',
  'write_snapshot', 'write_delta', 'garble_label', 'conn_state',
  'ready_replay', 'reconnect',
];

function pct(sorted, p) {
  if (!sorted.length) return null;
  const i = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[i];
}
function sum(a) { return a.reduce((x, y) => x + y, 0); }
function mean(a) { return a.length ? sum(a) / a.length : null; }
function median(a) {
  if (!a.length) return null;
  const s = [...a].sort((x, y) => x - y);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}
function dist(vals) {
  const a = vals.filter((v) => typeof v === 'number' && Number.isFinite(v));
  const s = [...a].sort((x, y) => x - y);
  return {
    n: a.length,
    missing: vals.length - a.length,
    mean: mean(s),
    median: median(s),
    p95: pct(s, 95),
    min: s[0] ?? null,
    max: s[s.length - 1] ?? null,
  };
}

const rows = [];
for await (const line of createInterface({ input: createReadStream(file) })) {
  if (line.trim()) rows.push(JSON.parse(line));
}

const typeCounts = Object.fromEntries(REQUIRED_TYPES.map((t) => [t, 0]));
const typeRows = Object.fromEntries(REQUIRED_TYPES.map((t) => [t, 0]));
let dumpMissing = 0;
let dumpNoEvents = 0;

const byRef = new Map();
for (const r of rows) {
  const ref = r.session_ref || `unknown:${r.session_uid}`;
  if (!byRef.has(ref)) {
    byRef.set(ref, {
      ref,
      n: 0,
      garbled: 0,
      nullLabel: 0,
      reasons: new Map(),
      local: [],
      listing: [],
      settle: [],
      click_to_sub: [],
      sub_to_snap: [],
      snap_to_last_resize: [],
      last_resize_to_stable: [],
      t_sub_sent: [],
      t_snap_first: [],
      t_last_resize: [],
      t_stable: [],
    });
  }
  const g = byRef.get(ref);
  g.n += 1;
  if (r.garbled === true) {
    g.garbled += 1;
    for (const reason of r.reasons || []) g.reasons.set(reason, (g.reasons.get(reason) || 0) + 1);
    g.local.push(`${r.local_cols}x${r.local_rows}`);
    g.listing.push(`${r.listing_cols}x${r.listing_rows}`);
  }
  if (r.garbled == null) g.nullLabel += 1;
  g.settle.push(r.settle_ms);
  g.click_to_sub.push(r.click_to_sub);
  g.sub_to_snap.push(r.sub_to_snap);
  g.snap_to_last_resize.push(r.snap_to_last_resize);
  g.last_resize_to_stable.push(r.last_resize_to_stable);
  g.t_sub_sent.push(r.t_sub_sent);
  g.t_snap_first.push(r.t_snap_first);
  g.t_last_resize.push(r.t_last_resize);
  g.t_stable.push(r.t_stable);

  const dump = r.dump;
  if (!dump || !Array.isArray(dump.events)) {
    dumpMissing += 1;
    continue;
  }
  if (dump.events.length === 0) dumpNoEvents += 1;
  const seen = new Set();
  for (const ev of dump.events) {
    if (typeCounts[ev.type] != null) typeCounts[ev.type] += 1;
    seen.add(ev.type);
  }
  for (const t of seen) {
    if (typeRows[t] != null) typeRows[t] += 1;
  }
}

const sessions = [...byRef.values()].sort((a, b) => b.garbled - a.garbled || a.ref.localeCompare(b.ref));
const all = {
  settle_ms: dist(rows.map((r) => r.settle_ms)),
  click_to_sub: dist(rows.map((r) => r.click_to_sub)),
  sub_to_snap: dist(rows.map((r) => r.sub_to_snap)),
  snap_to_last_resize: dist(rows.map((r) => r.snap_to_last_resize)),
  last_resize_to_stable: dist(rows.map((r) => r.last_resize_to_stable)),
};

const out = {
  rows: rows.length,
  rounds: new Set(rows.map((r) => r.round)).size,
  sessions: sessions.length,
  dumpMissing,
  dumpNoEvents,
  typeCounts,
  typeRows,
  all,
  sessions,
  garbled_true: rows.filter((r) => r.garbled === true).length,
  garbled_false: rows.filter((r) => r.garbled === false).length,
  garbled_null: rows.filter((r) => r.garbled == null).length,
};

writeFileSync(join(here, 'sweep-stats.json'), JSON.stringify(out, (k, v) => {
  if (v instanceof Map) return Object.fromEntries(v);
  if (typeof v === 'number' && Number.isFinite(v)) return Math.round(v * 1000) / 1000;
  return v;
}, 2));

console.error(`stats sessions=${sessions.length} rows=${rows.length} dumpMissing=${dumpMissing}`);
