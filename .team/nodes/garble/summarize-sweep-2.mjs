#!/usr/bin/env node
import { createReadStream, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import readline from 'node:readline';

const here = dirname(fileURLToPath(import.meta.url));
const jsonl = join(here, 'sweep-full-2.jsonl');

function paneOf(ref) {
  const m = String(ref || '').match(/%\d+/);
  return m ? m[0] : '?';
}
function sockOf(ref) {
  const s = String(ref || '');
  const m = s.match(/([^/\\]+)\u001f/);
  if (m) return m[1].slice(0, 16);
  const m2 = s.match(/tmux-\d+\/([^/\u001f]+)/);
  return m2 ? m2[1].slice(0, 16) : 'sess';
}
function keyOf(ref) {
  return `${sockOf(ref)} ${paneOf(ref)}`;
}

function nums(arr) {
  const a = arr.filter((x) => typeof x === 'number' && Number.isFinite(x)).sort((x, y) => x - y);
  if (!a.length) return { n: 0, mean: null, med: null, p95: null, min: null, max: null };
  const mean = a.reduce((s, x) => s + x, 0) / a.length;
  const med = a[Math.floor(a.length / 2)];
  const p95 = a[Math.min(a.length - 1, Math.floor(a.length * 0.95))];
  return { n: a.length, mean: +mean.toFixed(1), med: +med.toFixed(1), p95: +p95.toFixed(1), min: +a[0].toFixed(1), max: +a[a.length - 1].toFixed(1) };
}

const rows = [];
const rl = readline.createInterface({ input: createReadStream(jsonl) });
for await (const line of rl) {
  if (!line.trim()) continue;
  rows.push(JSON.parse(line));
}

const types = new Map();
let listingEv = 0;
let subWithHost = 0;
let subTotal = 0;
let labelChars = 0;
let dumpMissing = 0;
let tokenHits = 0;
const hostCols = new Map();
const bySess = new Map();

for (const r of rows) {
  if (!r.dump || !Array.isArray(r.dump.events)) dumpMissing += 1;
  const blob = JSON.stringify(r);
  if (/token/i.test(blob) && /"token"\s*:/.test(blob)) tokenHits += 1;
  const ev = r.dump?.events || [];
  for (const e of ev) {
    types.set(e.type, (types.get(e.type) || 0) + 1);
    if (e.type === 'listing' || e.type === 'list_delta') listingEv += 1;
    if (e.type === 'subscribe') {
      subTotal += 1;
      if (e.host_cols != null) subWithHost += 1;
    }
    if (e.type === 'garble_label' && e.max_line_chars != null) labelChars += 1;
  }
  const k = keyOf(r.session_ref);
  if (!bySess.has(k)) {
    bySess.set(k, {
      key: k, n: 0, garbled: 0, none: 0, reasons: new Map(),
      settle: [], click: [], subsnap: [], snapresize: [], resizeStable: [],
      local: new Map(), host: new Map(),
      mlw: [], mchars: [], mwide: 0,
    });
  }
  const s = bySess.get(k);
  s.n += 1;
  if (r.garbled === true) s.garbled += 1;
  else if (r.garbled == null) s.none += 1;
  for (const rs of r.reasons || []) s.reasons.set(rs, (s.reasons.get(rs) || 0) + 1);
  if (typeof r.settle_ms === 'number') s.settle.push(r.settle_ms);
  if (typeof r.click_to_sub === 'number') s.click.push(r.click_to_sub);
  if (typeof r.sub_to_snap === 'number') s.subsnap.push(r.sub_to_snap);
  if (typeof r.snap_to_last_resize === 'number') s.snapresize.push(r.snap_to_last_resize);
  if (typeof r.last_resize_to_stable === 'number') s.resizeStable.push(r.last_resize_to_stable);
  if (r.local_cols && r.local_rows) {
    const g = `${r.local_rows}x${r.local_cols}`;
    s.local.set(g, (s.local.get(g) || 0) + 1);
  }
  const hc = r.host_cols ?? r.listing_cols;
  const hr = r.host_rows ?? r.listing_rows;
  if (hc != null) {
    const g = `${hr}x${hc}`;
    s.host.set(g, (s.host.get(g) || 0) + 1);
    hostCols.set(hc, (hostCols.get(hc) || 0) + 1);
  }
  const g = (ev.find((e) => e.type === 'garble_label') || {});
  if (g.max_line_width != null) s.mlw.push(g.max_line_width);
  if (r.max_line_chars != null) s.mchars.push(r.max_line_chars);
  if (r.max_line_has_wide === true) s.mwide += 1;
}

const allSettle = rows.map((r) => r.settle_ms);
const allClick = rows.map((r) => r.click_to_sub);
const allSub = rows.map((r) => r.sub_to_snap);
const allSnapR = rows.map((r) => r.snap_to_last_resize);
const allRS = rows.map((r) => r.last_resize_to_stable);

const garbledTrue = rows.filter((r) => r.garbled === true).length;
const garbledFalse = rows.filter((r) => r.garbled === false).length;
const garbledNull = rows.filter((r) => r.garbled == null).length;

const sess = [...bySess.values()].sort((a, b) => b.garbled - a.garbled || a.key.localeCompare(b.key));

const out = {
  rows: rows.length,
  sessions: bySess.size,
  dumpMissing,
  tokenHits,
  garbledTrue,
  garbledFalse,
  garbledNull,
  listingEv,
  subTotal,
  subWithHost,
  labelChars,
  types: Object.fromEntries([...types.entries()].sort()),
  hostCols: Object.fromEntries([...hostCols.entries()].sort((a, b) => b[1] - a[1])),
  settle: nums(allSettle),
  click_to_sub: nums(allClick),
  sub_to_snap: nums(allSub),
  snap_to_last_resize: nums(allSnapR),
  last_resize_to_stable: nums(allRS),
  sess: sess.map((s) => ({
    key: s.key,
    n: s.n,
    garbled: s.garbled,
    none: s.none,
    reasons: Object.fromEntries(s.reasons),
    local: Object.fromEntries(s.local),
    host: Object.fromEntries(s.host),
    settle: nums(s.settle),
    mlw_garbled: s.garbled ? [...new Set(rows.filter((r) => keyOf(r.session_ref) === s.key && r.garbled).map((r) => {
      const g = (r.dump?.events || []).find((e) => e.type === 'garble_label');
      return g?.max_line_width;
    }))].filter((x) => x != null) : [],
    mwide: s.mwide,
  })),
};

writeFileSync(join(here, 'sweep2-stats.json'), JSON.stringify(out, null, 2));
console.error(`rows=${out.rows} sess=${out.sessions} gT=${garbledTrue} gF=${garbledFalse} settle.n=${out.settle.n} host_on_sub=${subWithHost}/${subTotal} listingEv=${listingEv}`);
