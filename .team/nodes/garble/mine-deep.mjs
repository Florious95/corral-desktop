#!/usr/bin/env node
import { createReadStream, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const file = join(here, 'sweep-full.jsonl');

const rows = [];
for await (const line of createInterface({ input: createReadStream(file) })) {
  if (line.trim()) rows.push(JSON.parse(line));
}

function flattenEvents(events) {
  const byType = {};
  const counts = {};
  for (const e of events || []) {
    const t = e.type || 'unknown';
    counts[t] = (counts[t] || 0) + 1;
    if (!byType[t]) byType[t] = [];
    byType[t].push(e);
  }
  const out = { counts };
  for (const [t, list] of Object.entries(byType)) {
    const last = list[list.length - 1];
    const first = list[0];
    for (const [k, v] of Object.entries(last)) {
      if (k === 'type' || k === 't' || k === 't_write') continue;
      if (typeof v === 'object' && v !== null) continue;
      out[`last.${t}.${k}`] = v;
    }
    for (const [k, v] of Object.entries(first)) {
      if (k === 'type' || k === 't' || k === 't_write') continue;
      if (typeof v === 'object' && v !== null) continue;
      out[`first.${t}.${k}`] = v;
    }
  }
  return out;
}

const flat = rows.map((r) => {
  const f = flattenEvents(r.dump?.events);
  return {
    garbled: r.garbled === true,
    session: r.session_ref || r.ref || r.socket,
    round: r.round,
    click_to_sub: r.click_to_sub,
    sub_to_snap: r.sub_to_snap,
    snap_to_last_resize: r.snap_to_last_resize,
    settle_ms: r.settle_ms,
    listing_cols: r.listing_cols,
    listing_rows: r.listing_rows,
    dump_len: r.dump?.length,
    dump_dropped: r.dump?.dropped,
    dump_seq: r.dump?.seq,
    ...f,
    _row: r,
  };
});

const P = flat.filter((x) => x.garbled);
const N = flat.filter((x) => !x.garbled);

const skipPrefix = ['last.garble_label.', 'first.garble_label.'];
function isLabeler(k) {
  return skipPrefix.some((p) => k.startsWith(p)) || k === 'garbled';
}

const allKeys = new Set();
for (const x of flat) {
  for (const k of Object.keys(x)) {
    if (k === '_row' || k === 'session' || k === 'round') continue;
    allKeys.add(k);
  }
}

function evalPred(pred) {
  let tp = 0, fp = 0, tn = 0, fn = 0, unk = 0;
  for (const x of flat) {
    const v = pred(x);
    if (v == null) { unk++; continue; }
    if (v && x.garbled) tp++;
    else if (v && !x.garbled) fp++;
    else if (!v && !x.garbled) tn++;
    else fn++;
  }
  return { tp, fp, tn, fn, unk, ok: fp === 0 && fn === 0 && unk === 0 };
}

const numericKeys = [];
const catKeys = [];
for (const k of [...allKeys].sort()) {
  const vals = flat.map((x) => x[k]).filter((v) => v !== undefined && v !== null);
  if (!vals.length) continue;
  const types = new Set(vals.map((v) => typeof v));
  if (types.size === 1 && types.has('number')) numericKeys.push(k);
  else catKeys.push(k);
}

const perfectNum = [];
const nearNum = [];
for (const k of numericKeys) {
  if (isLabeler(k)) continue;
  const pos = P.map((x) => x[k]).filter((v) => v != null);
  const neg = N.map((x) => x[k]).filter((v) => v != null);
  if (!pos.length || !neg.length) continue;
  const minP = Math.min(...pos), maxP = Math.max(...pos);
  const minN = Math.min(...neg), maxN = Math.max(...neg);
  // try threshold greater-than
  const candidates = [...new Set([...pos, ...neg])].sort((a, b) => a - b);
  let best = null;
  for (const t of candidates) {
    const r1 = evalPred((x) => (x[k] == null ? null : x[k] > t));
    const r2 = evalPred((x) => (x[k] == null ? null : x[k] >= t));
    const r3 = evalPred((x) => (x[k] == null ? null : x[k] < t));
    const r4 = evalPred((x) => (x[k] == null ? null : x[k] <= t));
    for (const [op, r] of [['>', r1], ['>=', r2], ['<', r3], ['<=', r4]]) {
      if (!best || r.fp + r.fn + r.unk < best.err) {
        best = { k, op, t, ...r, err: r.fp + r.fn + r.unk };
      }
      if (r.ok) perfectNum.push({ k, op, t, ...r });
    }
  }
  if (best) nearNum.push({ ...best, minP, maxP, minN, maxN, disjoint: maxP < minN || maxN < minP });
}

const perfectCat = [];
for (const k of catKeys) {
  if (isLabeler(k)) continue;
  const posVals = new Set(P.map((x) => JSON.stringify(x[k])));
  const negVals = new Set(N.map((x) => JSON.stringify(x[k])));
  const onlyP = [...posVals].filter((v) => !negVals.has(v));
  const onlyN = [...negVals].filter((v) => !posVals.has(v));
  const both = [...posVals].filter((v) => negVals.has(v));
  const pred = (x) => {
    const s = JSON.stringify(x[k]);
    if (onlyP.includes(s) && !onlyN.includes(s)) return true;
    if (onlyN.includes(s) && !onlyP.includes(s)) return false;
    if (both.includes(s)) return null; // inseparable on this key
    return null;
  };
  const r = evalPred(pred);
  if (r.ok) perfectCat.push({ k, onlyP, onlyN, both, ...r });
}

// labeler circular checks
const labelerRules = [
  ['garble_label.garbled', (x) => x['last.garble_label.garbled'] === true],
  ['max_line_width > last.write_snapshot.term_cols', (x) => {
    const w = x['last.garble_label.max_line_width'];
    const c = x['last.write_snapshot.term_cols'];
    if (w == null || c == null) return null;
    return w > c;
  }],
  ['overwide_lines > 0', (x) => {
    const n = x['last.garble_label.overwide_lines'];
    if (n == null) return null;
    return n > 0;
  }],
];
const labelerEval = labelerRules.map(([name, pred]) => ({ name, ...evalPred(pred) }));

// mixed sessions: same session, both labels — field diffs excluding labeler
const bySess = new Map();
for (const x of flat) {
  const s = x.session || x._row.session_ref || x._row.dump?.events?.find((e) => e.ref)?.ref;
  const key = x._row.session || x._row.socket_file || JSON.stringify([x._row.session_name, x._row.pane]);
  const k = x._row.session_id || x._row.uid || x._row.session_ref || x._row.ref || x._row.pane_id;
  const ident = x._row.session_ref ?? `${x._row.socket}:${x._row.pane}` ?? x._row.activate_ref;
  void s; void key; void k; void ident;
}

function sessKey(r) {
  const ev = r.dump?.events || [];
  const act = ev.find((e) => e.type === 'activate');
  const lab = ev.find((e) => e.type === 'garble_label');
  return lab?.ref || act?.ref || r.session_ref || r.ref;
}

const groups = new Map();
for (const x of flat) {
  const k = sessKey(x._row);
  if (!groups.has(k)) groups.set(k, { p: [], n: [] });
  if (x.garbled) groups.get(k).p.push(x);
  else groups.get(k).n.push(x);
}
const mixedSess = [...groups.entries()].filter(([, g]) => g.p.length && g.n.length);

function scalarDiff(a, b) {
  const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
  const diffs = [];
  for (const k of keys) {
    if (k === '_row' || k === 'round' || k === 'garbled') continue;
    if (isLabeler(k)) continue;
    if (JSON.stringify(a[k]) !== JSON.stringify(b[k])) diffs.push({ k, pos: a[k], neg: b[k] });
  }
  return diffs;
}

const mixedPairs = mixedSess.slice(0, 5).map(([sess, g]) => {
  const diffs = scalarDiff(g.p[0], g.n[0]);
  return {
    sess,
    p: g.p.length,
    n: g.n.length,
    nDiffKeys: diffs.length,
    diffs: diffs.slice(0, 40),
  };
});

// intersection of differing keys across ALL mixed pos-neg pairs
const commonDiff = new Map();
let pairCount = 0;
for (const [, g] of mixedSess) {
  for (const p of g.p) {
    for (const n of g.n) {
      pairCount++;
      const diffs = scalarDiff(p, n);
      const set = new Set(diffs.map((d) => d.k));
      if (commonDiff.size === 0 && pairCount === 1) {
        for (const k of set) commonDiff.set(k, 1);
      } else {
        for (const k of [...commonDiff.keys()]) {
          if (!set.has(k)) commonDiff.delete(k);
        }
      }
    }
  }
}

// keys that ALWAYS differ in mixed pairs vs keys that sometimes match
const alwaysDiff = new Map();
const sometimesSame = new Map();
for (const [, g] of mixedSess) {
  for (const p of g.p) {
    for (const n of g.n) {
      const diffs = new Set(scalarDiff(p, n).map((d) => d.k));
      const keys = new Set([...Object.keys(p), ...Object.keys(n)]);
      for (const k of keys) {
        if (k === '_row' || k === 'round' || k === 'garbled' || isLabeler(k)) continue;
        if (diffs.has(k)) alwaysDiff.set(k, (alwaysDiff.get(k) || 0) + 1);
        else sometimesSame.set(k, (sometimesSame.get(k) || 0) + 1);
      }
    }
  }
}

const alwaysDiffOnly = [...alwaysDiff.entries()]
  .filter(([k]) => !sometimesSame.has(k))
  .sort((a, b) => b[1] - a[1]);

// identical non-labeler dump for mixed? full event dump minus garble_label
function dumpSansLabel(r) {
  const ev = (r.dump?.events || []).filter((e) => e.type !== 'garble_label');
  const norm = ev.map((e) => {
    const { t, t_write, t0, ...rest } = e;
    void t; void t_write; void t0;
    return rest;
  });
  return JSON.stringify(norm);
}

const sansBuckets = new Map();
for (const x of flat) {
  const k = dumpSansLabel(x._row);
  if (!sansBuckets.has(k)) sansBuckets.set(k, { p: 0, n: 0, exP: null, exN: null });
  const b = sansBuckets.get(k);
  if (x.garbled) { b.p++; if (!b.exP) b.exP = x; }
  else { b.n++; if (!b.exN) b.exN = x; }
}
const mixedSans = [...sansBuckets.values()].filter((b) => b.p && b.n);

// WITH timings (t fields)
function dumpSansLabelKeepT(r) {
  const ev = (r.dump?.events || []).filter((e) => e.type !== 'garble_label');
  return JSON.stringify(ev);
}
const tBuckets = new Map();
for (const x of flat) {
  const k = dumpSansLabelKeepT(x._row);
  if (!tBuckets.has(k)) tBuckets.set(k, { p: 0, n: 0 });
  if (x.garbled) tBuckets.get(k).p++;
  else tBuckets.get(k).n++;
}
const mixedT = [...tBuckets.values()].filter((b) => b.p && b.n);

writeFileSync(join(here, 'analyze-deep.json'), JSON.stringify({
  n: flat.length, pos: P.length, neg: N.length,
  labelerEval,
  perfectNum,
  perfectCat,
  nearNum: nearNum.sort((a, b) => a.err - b.err).slice(0, 25),
  mixedSessCount: mixedSess.length,
  mixedPairs,
  pairCount,
  alwaysDiffOnly: alwaysDiffOnly.slice(0, 30),
  mixedSansCount: mixedSans.length,
  mixedTCount: mixedT.length,
  mixedSansExample: mixedSans[0] ? {
    p: mixedSans[0].p, n: mixedSans[0].n,
    sessP: sessKey(mixedSans[0].exP._row),
    sessN: sessKey(mixedSans[0].exN._row),
    roundP: mixedSans[0].exP.round,
    roundN: mixedSans[0].exN.round,
  } : null,
  sampleKeys: [...allKeys].sort(),
}, null, 2));

console.error(JSON.stringify({
  n: flat.length, pos: P.length, neg: N.length,
  labelerEval,
  perfectNumN: perfectNum.length,
  perfectCatN: perfectCat.length,
  mixedSess: mixedSess.length,
  mixedSans: mixedSans.length,
  mixedT: mixedT.length,
  alwaysDiffOnly: alwaysDiffOnly.slice(0, 20),
  topNear: nearNum.sort((a, b) => a.err - b.err).slice(0, 8),
}, null, 2));
