#!/usr/bin/env node
// Mine dump.events (delivery A) vs garbled label. Does not use garble_label metrics as features.
import { createReadStream, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const file = join(here, 'sweep-full.jsonl');

function last(events, type, pred) {
  let hit = null;
  for (const e of events) {
    if (e.type !== type) continue;
    if (pred && !pred(e)) continue;
    hit = e;
  }
  return hit;
}
function first(events, type, pred) {
  for (const e of events) {
    if (e.type !== type) continue;
    if (pred && !pred(e)) continue;
    return e;
  }
  return null;
}
function all(events, type) {
  return events.filter((e) => e.type === type);
}

function feats(row) {
  const ev = row.dump?.events || [];
  const proto = row.session_ref;
  const sub = first(ev, 'subscribe', (e) => e.sent !== false);
  const snap = first(ev, 'snapshot');
  const ws = first(ev, 'write_snapshot');
  const fits = all(ev, 'fit');
  const resizes = all(ev, 'term_resize');
  const lastResize = resizes[resizes.length - 1] || null;
  const firstResize = resizes[0] || null;
  const resizeUps = all(ev, 'resize_up');
  const deltas = all(ev, 'delta');
  const unsub = all(ev, 'unsubscribe');
  const listD = all(ev, 'list_delta');
  const lastFit = fits[fits.length - 1] || null;
  const firstFit = fits[0] || null;

  const subCols = sub?.cols ?? null;
  const subRows = sub?.rows ?? null;
  const termCols = ws?.term_cols ?? lastFit?.term_cols ?? lastFit?.cols ?? null;
  const termRows = ws?.term_rows ?? lastFit?.term_rows ?? lastFit?.rows ?? null;
  const snapBytes = snap?.bytes ?? null;
  const writeBytes = ws?.bytes ?? null;
  const toCols = lastResize?.to_cols ?? null;
  const fromCols = firstResize?.from_cols ?? null;

  const snapT = snap?.t ?? null;
  const lastResizeT = lastResize?.t ?? null;
  const firstResizeT = firstResize?.t ?? null;
  const writeT = ws?.t_write ?? ws?.t ?? null;
  const subT = sub?.t ?? null;

  return {
    garbled: row.garbled === true,
    round: row.round,
    ref: proto,
    sub_cols: subCols,
    sub_rows: subRows,
    term_cols: termCols,
    term_rows: termRows,
    snap_bytes: snapBytes,
    write_bytes: writeBytes,
    n_fit: fits.length,
    n_term_resize: resizes.length,
    n_resize_up: resizeUps.length,
    n_delta: deltas.length,
    n_unsub: unsub.length,
    n_list_delta: listD.length,
    last_fit_cols: lastFit?.cols ?? null,
    last_fit_early: lastFit?.early_exit ?? null,
    last_fit_will_resize: lastFit?.will_resize ?? null,
    last_to_cols: toCols,
    first_from_cols: fromCols,
    snap_before_last_resize: snapT != null && lastResizeT != null ? snapT < lastResizeT : null,
    write_before_last_resize: writeT != null && lastResizeT != null ? writeT < lastResizeT : null,
    last_resize_before_snap: lastResizeT != null && snapT != null ? lastResizeT < snapT : null,
    first_resize_before_snap: firstResizeT != null && snapT != null ? firstResizeT < snapT : null,
    sub_eq_term: subCols != null && termCols != null ? subCols === termCols : null,
    sub_eq_last_to: subCols != null && toCols != null ? subCols === toCols : null,
    bytes_per_cell: snapBytes != null && termCols && termRows ? snapBytes / (termCols * termRows) : null,
    sub_sent: sub?.sent ?? null,
    resize_up_sent: resizeUps.some((e) => e.sent === true),
    resize_up_noop: resizeUps.some((e) => e.reason === 'geom_unchanged'),
    delta_bytes: deltas.reduce((s, e) => s + (e.bytes || 0), 0),
    click_to_sub: row.click_to_sub,
    sub_to_snap: row.sub_to_snap,
  };
}

const rows = [];
for await (const line of createInterface({ input: createReadStream(file) })) {
  if (line.trim()) rows.push(JSON.parse(line));
}
const F = rows.map(feats);
const P = F.filter((x) => x.garbled);
const N = F.filter((x) => !x.garbled);
console.error(`n=${F.length} pos=${P.length} neg=${N.length}`);

function evalRule(name, pred) {
  let tp = 0, fp = 0, tn = 0, fn = 0, unk = 0;
  for (const x of F) {
    const v = pred(x);
    if (v == null) { unk += 1; continue; }
    if (v && x.garbled) tp += 1;
    else if (v && !x.garbled) fp += 1;
    else if (!v && !x.garbled) tn += 1;
    else fn += 1;
  }
  const ok = fp === 0 && fn === 0 && unk === 0;
  return { name, tp, fp, tn, fn, unk, n: F.length, ok };
}

const rules = [];

// numeric thresholds on snap_bytes
const bytes = F.map((x) => x.snap_bytes).filter((v) => v != null).sort((a, b) => a - b);
const posB = P.map((x) => x.snap_bytes).filter((v) => v != null);
const negB = N.map((x) => x.snap_bytes).filter((v) => v != null);
const minP = Math.min(...posB);
const maxP = Math.max(...posB);
const minN = Math.min(...negB);
const maxN = Math.max(...negB);
console.error(`snap_bytes pos ${minP}..${maxP} neg ${minN}..${maxN}`);

rules.push(evalRule('snap_bytes > 8000', (x) => x.snap_bytes != null ? x.snap_bytes > 8000 : null));
rules.push(evalRule('snap_bytes > 12000', (x) => x.snap_bytes != null ? x.snap_bytes > 12000 : null));
rules.push(evalRule('bytes_per_cell > 4', (x) => x.bytes_per_cell != null ? x.bytes_per_cell > 4 : null));
rules.push(evalRule('bytes_per_cell > 3', (x) => x.bytes_per_cell != null ? x.bytes_per_cell > 3 : null));
rules.push(evalRule('bytes_per_cell > 2.5', (x) => x.bytes_per_cell != null ? x.bytes_per_cell > 2.5 : null));
rules.push(evalRule('n_delta === 0', (x) => x.n_delta === 0));
rules.push(evalRule('n_delta > 0', (x) => x.n_delta > 0));
rules.push(evalRule('n_term_resize >= 3', (x) => x.n_term_resize >= 3));
rules.push(evalRule('n_fit >= 4', (x) => x.n_fit >= 4));
rules.push(evalRule('last_resize_before_snap', (x) => x.last_resize_before_snap));
rules.push(evalRule('snap_before_last_resize', (x) => x.snap_before_last_resize));
rules.push(evalRule('sub_cols !== term_cols', (x) => x.sub_eq_term == null ? null : !x.sub_eq_term));
rules.push(evalRule('resize_up_noop', (x) => x.resize_up_noop));
rules.push(evalRule('sub_to_snap > 200', (x) => x.sub_to_snap != null ? x.sub_to_snap > 200 : null));
rules.push(evalRule('sub_to_snap > 250', (x) => x.sub_to_snap != null ? x.sub_to_snap > 250 : null));

// session-level: always-garbled sockets
const byRef = new Map();
for (const x of F) {
  if (!byRef.has(x.ref)) byRef.set(x.ref, { p: 0, n: 0 });
  if (x.garbled) byRef.get(x.ref).p += 1;
  else byRef.get(x.ref).n += 1;
}

// try snap_bytes threshold scan for 0 fp 0 fn
let best = { fp: 1e9, fn: 1e9, t: null };
for (let t = 0; t < 40000; t += 50) {
  const r = evalRule(`snap_bytes > ${t}`, (x) => x.snap_bytes > t);
  if (r.fp + r.fn < best.fp + best.fn) best = { ...r, t };
  if (r.ok) {
    console.error('PERFECT bytes', t, r);
  }
}
console.error('best bytes', best);

let bestC = { fp: 1e9, fn: 1e9, t: null };
for (let t = 1; t < 12; t += 0.05) {
  const r = evalRule(`bpc > ${t.toFixed(2)}`, (x) => x.bytes_per_cell > t);
  if (r.fp + r.fn < bestC.fp + bestC.fn) bestC = { ...r, t };
  if (r.ok) console.error('PERFECT bpc', t, r);
}
console.error('best bpc', bestC);

// combo: bytes and n_delta
for (const t of [4000, 5000, 6000, 7000, 8000, 9000, 10000, 11000, 12000, 15000, 20000]) {
  rules.push(evalRule(`snap_bytes>${t} && n_delta===0`, (x) => x.snap_bytes > t && x.n_delta === 0));
  rules.push(evalRule(`snap_bytes>${t} || n_delta===0`, (x) => x.snap_bytes > t || x.n_delta === 0));
}

const scored = rules.sort((a, b) => (a.fp + a.fn + a.unk) - (b.fp + b.fn + b.unk));
console.error('top rules');
for (const r of scored.slice(0, 15)) console.error(JSON.stringify(r));

// overlap of bytes ranges
const posSet = new Set(posB);
const overlap = negB.filter((b) => posB.some((p) => Math.abs(p - b) < 1));
console.error('exact byte overlap count', overlap.length);

// find pairs of pos/neg with identical A-features
const keyOf = (x) => JSON.stringify({
  sub_cols: x.sub_cols, term_cols: x.term_cols, snap_bytes: x.snap_bytes,
  n_fit: x.n_fit, n_term_resize: x.n_term_resize, n_delta: x.n_delta,
  last_resize_before_snap: x.last_resize_before_snap,
  sub_eq_term: x.sub_eq_term, n_resize_up: x.n_resize_up,
});
const buckets = new Map();
for (const x of F) {
  const k = keyOf(x);
  if (!buckets.has(k)) buckets.set(k, { p: 0, n: 0, ex: x });
  if (x.garbled) buckets.get(k).p += 1;
  else buckets.get(k).n += 1;
}
const mixed = [...buckets.values()].filter((b) => b.p && b.n);
console.error('mixed identical-A-feature buckets', mixed.length);
if (mixed[0]) console.error('example mixed', mixed[0].p, mixed[0].n, mixed[0].ex);

writeFileSync(join(here, 'analyze-mine.json'), JSON.stringify({
  n: F.length, pos: P.length, neg: N.length,
  snap_bytes: { minP, maxP, minN, maxN },
  best_bytes: best, best_bpc: bestC,
  top: scored.slice(0, 20),
  mixed_buckets: mixed.length,
  mixed_example: mixed[0] || null,
  byRef: Object.fromEntries([...byRef].map(([k, v]) => [k, v])),
}, null, 2));
