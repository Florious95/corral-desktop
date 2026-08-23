#!/usr/bin/env node
// t.analyze2: mine sweep-full-2.jsonl. Labeler metrics are not legal rules.
import { createReadStream, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const file = '/Volumes/nvme/Projects/tmux桌面端/.worktrees/wt-r2scan/.team/nodes/garble/sweep-full-2.jsonl';

function first(events, type, pred) {
  for (const e of events) {
    if (e.type !== type) continue;
    if (pred && !pred(e)) continue;
    return e;
  }
  return null;
}
function last(events, type, pred) {
  let hit = null;
  for (const e of events) {
    if (e.type !== type) continue;
    if (pred && !pred(e)) continue;
    hit = e;
  }
  return hit;
}
function all(events, type) {
  return events.filter((e) => e.type === type);
}

function feats(row) {
  const ev = row.dump?.events || [];
  const sub = first(ev, 'subscribe', (e) => e.sent !== false) || first(ev, 'subscribe');
  const snap = first(ev, 'snapshot');
  const ws = first(ev, 'write_snapshot');
  const fits = all(ev, 'fit');
  const resizes = all(ev, 'term_resize');
  const lastResize = resizes[resizes.length - 1] || null;
  const resizeUps = all(ev, 'resize_up');
  const deltas = all(ev, 'delta');
  const lastFit = fits[fits.length - 1] || null;
  const g = last(ev, 'garble_label');
  const fitPath = fits.map((f) => `${f.path || f.early_exit || '?'}:${f.cols}x${f.rows}`).join('>');

  const hostCols = sub?.host_cols ?? row.host_cols ?? null;
  const hostRows = sub?.host_rows ?? row.host_rows ?? null;
  const subCols = sub?.cols ?? null;
  const subRows = sub?.rows ?? null;
  const termCols = ws?.term_cols ?? null;
  const snapT = snap?.t ?? null;
  const lastResizeT = lastResize?.t ?? null;
  const firstUpAfterSnap = resizeUps.some((u) => snapT != null && u.t > snapT);

  return {
    garbled: row.garbled === true,
    round: row.round,
    ref: row.session_ref,
    host_cols: hostCols,
    host_rows: hostRows,
    listing_seq: sub?.listing_seq ?? row.listing_seq ?? null,
    sub_cols: subCols,
    sub_rows: subRows,
    host_ne_sub: hostCols != null && subCols != null && hostCols !== subCols,
    host_minus_sub: hostCols != null && subCols != null ? hostCols - subCols : null,
    term_cols: termCols,
    term_rows: ws?.term_rows ?? null,
    snap_bytes: snap?.bytes ?? null,
    n_fit: fits.length,
    n_term_resize: resizes.length,
    n_resize_up: resizeUps.length,
    n_delta: deltas.length,
    n_list_delta: all(ev, 'list_delta').length,
    n_listing: all(ev, 'listing').length,
    last_fit_cols: lastFit?.cols ?? null,
    last_resize_to: lastResize?.to_cols ?? null,
    resize_after_snap: firstUpAfterSnap,
    snap_before_last_resize: snapT != null && lastResizeT != null ? snapT < lastResizeT : null,
    click_to_sub: row.click_to_sub,
    sub_to_snap: row.sub_to_snap,
    settle_ms: row.settle_ms,
    fit_path: fitPath,
    // labeler (illegal as rule, recorded for tautology check)
    mlw: g?.max_line_width ?? null,
    overwide: g?.overwide_lines ?? null,
    box: g?.max_box_run ?? null,
    cup: g?.cup_clamped ?? null,
    mchars: g?.max_line_chars ?? row.max_line_chars ?? null,
    mwide: g?.max_line_has_wide ?? row.max_line_has_wide ?? null,
  };
}

function confusion(rows, pred) {
  let tp = 0, fp = 0, fn = 0, tn = 0;
  for (const r of rows) {
    const y = r.garbled;
    const yhat = !!pred(r);
    if (y && yhat) tp += 1;
    else if (!y && yhat) fp += 1;
    else if (y && !yhat) fn += 1;
    else tn += 1;
  }
  return { tp, fp, fn, tn, n: rows.length, perfect: fp === 0 && fn === 0 };
}

const rows = [];
const rl = createInterface({ input: createReadStream(file) });
for await (const line of rl) {
  if (!line.trim()) continue;
  rows.push(feats(JSON.parse(line)));
}

const pos = rows.filter((r) => r.garbled);
const neg = rows.filter((r) => !r.garbled);

function range(arr, key) {
  const a = arr.map((r) => r[key]).filter((x) => typeof x === 'number' && Number.isFinite(x));
  if (!a.length) return { n: 0 };
  return { n: a.length, min: Math.min(...a), max: Math.max(...a) };
}

const rules = [
  ['host_cols !== sub_cols', (r) => r.host_ne_sub],
  ['host_cols === 235', (r) => r.host_cols === 235],
  ['host_cols > 114', (r) => r.host_cols != null && r.host_cols > 114],
  ['host_cols - sub_cols === 121', (r) => r.host_minus_sub === 121],
  ['host_cols === 235 AND mwide', (r) => r.host_cols === 235 && r.mwide === true],
  ['mwide === true', (r) => r.mwide === true],
  ['mchars > 114', (r) => r.mchars != null && r.mchars > 114],
  ['snap_bytes > 4000', (r) => r.snap_bytes != null && r.snap_bytes > 4000],
  ['n_delta > 20', (r) => r.n_delta > 20],
  ['resize_after_snap', (r) => r.resize_after_snap === true],
  ['snap_before_last_resize', (r) => r.snap_before_last_resize === true],
  ['sub_to_snap > 150', (r) => r.sub_to_snap != null && r.sub_to_snap > 150],
  ['settle_ms > 260', (r) => r.settle_ms != null && r.settle_ms > 260],
  ['TAUTOLOGY mlw > term_cols', (r) => r.mlw != null && r.term_cols != null && r.mlw > r.term_cols],
  ['TAUTOLOGY overwide > 0', (r) => r.overwide > 0],
];

const ruleResults = rules.map(([name, pred]) => ({ name, ...confusion(rows, pred) }));

// numeric threshold scan on legal fields
const numericKeys = ['snap_bytes', 'n_delta', 'n_resize_up', 'click_to_sub', 'sub_to_snap', 'settle_ms', 'host_cols', 'host_minus_sub', 'mchars', 'n_list_delta'];
const threshScan = [];
for (const key of numericKeys) {
  const vals = [...new Set(rows.map((r) => r[key]).filter((x) => typeof x === 'number'))].sort((a, b) => a - b);
  let best = null;
  for (const t of vals) {
    for (const dir of ['gt', 'ge', 'lt', 'le', 'eq']) {
      const pred = (r) => {
        const v = r[key];
        if (v == null) return false;
        if (dir === 'gt') return v > t;
        if (dir === 'ge') return v >= t;
        if (dir === 'lt') return v < t;
        if (dir === 'le') return v <= t;
        return v === t;
      };
      const c = confusion(rows, pred);
      const score = c.fp + c.fn;
      if (!best || score < best.score || (score === best.score && c.tp > best.tp)) {
        best = { key, dir, t, score, ...c };
      }
    }
  }
  if (best) threshScan.push(best);
}
threshScan.sort((a, b) => a.score - b.score);

// conjunctions of legal binary-ish
const conj = [];
const conjDefs = [
  ['host_ne_sub && resize_after_snap', (r) => r.host_ne_sub && r.resize_after_snap],
  ['host_cols===235 && snap_bytes>3000', (r) => r.host_cols === 235 && r.snap_bytes > 3000],
  ['host_cols===235 && n_delta>=1', (r) => r.host_cols === 235 && r.n_delta >= 1],
  ['host_ne_sub && settle_ms>240', (r) => r.host_ne_sub && r.settle_ms > 240],
  ['host_cols===235 && mchars>=71', (r) => r.host_cols === 235 && r.mchars >= 71],
];
for (const [name, pred] of conjDefs) conj.push({ name, ...confusion(rows, pred) });

// signature of non-labeler geometry for mixed sessions
function geomSig(r) {
  return JSON.stringify({
    host_cols: r.host_cols, host_rows: r.host_rows,
    sub_cols: r.sub_cols, sub_rows: r.sub_rows,
    term_cols: r.term_cols, term_rows: r.term_rows,
    last_fit_cols: r.last_fit_cols, last_resize_to: r.last_resize_to,
    fit_path: r.fit_path,
    n_fit: r.n_fit, n_term_resize: r.n_term_resize,
    host_ne_sub: r.host_ne_sub,
  });
}

const byRef = new Map();
for (const r of rows) {
  if (!byRef.has(r.ref)) byRef.set(r.ref, []);
  byRef.get(r.ref).push(r);
}
const mixed = [];
for (const [ref, rs] of byRef) {
  const g = rs.filter((x) => x.garbled).length;
  if (g > 0 && g < rs.length) mixed.push({ ref, n: rs.length, g });
}

// find pair: same geomSig, different label
const bySig = new Map();
for (const r of rows) {
  const s = geomSig(r);
  if (!bySig.has(s)) bySig.set(s, { pos: [], neg: [] });
  (r.garbled ? bySig.get(s).pos : bySig.get(s).neg).push(r);
}
const inseparableGeom = [];
for (const [sig, v] of bySig) {
  if (v.pos.length && v.neg.length) {
    inseparableGeom.push({
      sig: JSON.parse(sig),
      nPos: v.pos.length,
      nNeg: v.neg.length,
      posEx: v.pos[0],
      negEx: v.neg[0],
    });
  }
}
inseparableGeom.sort((a, b) => (b.nPos + b.nNeg) - (a.nPos + a.nNeg));

const out = {
  n: rows.length,
  nPos: pos.length,
  nNeg: neg.length,
  pos_range: {
    snap_bytes: range(pos, 'snap_bytes'),
    host_cols: range(pos, 'host_cols'),
    mchars: range(pos, 'mchars'),
    mlw: range(pos, 'mlw'),
    settle: range(pos, 'settle_ms'),
    sub_to_snap: range(pos, 'sub_to_snap'),
  },
  neg_range: {
    snap_bytes: range(neg, 'snap_bytes'),
    host_cols: range(neg, 'host_cols'),
    mchars: range(neg, 'mchars'),
    mlw: range(neg, 'mlw'),
    settle: range(neg, 'settle_ms'),
    sub_to_snap: range(neg, 'sub_to_snap'),
  },
  host_cols_pos: countMap(pos, 'host_cols'),
  host_cols_neg: countMap(neg, 'host_cols'),
  mwide_pos: countMap(pos, 'mwide'),
  mwide_neg: countMap(neg, 'mwide'),
  ruleResults,
  threshScan: threshScan.slice(0, 12),
  conj,
  mixed,
  inseparableGeomCount: inseparableGeom.length,
  inseparableTop: inseparableGeom.slice(0, 3).map((x) => ({
    sig: x.sig,
    nPos: x.nPos,
    nNeg: x.nNeg,
    posEx: pickEx(x.posEx),
    negEx: pickEx(x.negEx),
  })),
};

function countMap(arr, key) {
  const m = {};
  for (const r of arr) {
    const k = String(r[key]);
    m[k] = (m[k] || 0) + 1;
  }
  return m;
}
function pickEx(r) {
  return {
    ref: r.ref, round: r.round, garbled: r.garbled,
    host_cols: r.host_cols, sub_cols: r.sub_cols, term_cols: r.term_cols,
    snap_bytes: r.snap_bytes, n_delta: r.n_delta,
    mlw: r.mlw, mchars: r.mchars, mwide: r.mwide, overwide: r.overwide, box: r.box,
    settle_ms: r.settle_ms, sub_to_snap: r.sub_to_snap,
    resize_after_snap: r.resize_after_snap,
  };
}

writeFileSync(join(here, 'analyze2-mine.json'), JSON.stringify(out, null, 2));
console.error(JSON.stringify({
  n: out.n, pos: out.nPos, neg: out.nNeg,
  tautology: ruleResults.filter((r) => r.name.startsWith('TAUT')),
  bestLegal: [...ruleResults.filter((r) => !r.name.startsWith('TAUT')), ...conj]
    .sort((a, b) => (a.fp + a.fn) - (b.fp + b.fn))
    .slice(0, 6),
  mixed: mixed.length,
  inseparableGeom: inseparableGeom.length,
}, null, 2));
