#!/usr/bin/env node
import { createReadStream, writeFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const rows = [];
for await (const line of createInterface({ input: createReadStream(join(here, 'sweep-full.jsonl')) })) {
  if (line.trim()) rows.push(JSON.parse(line));
}

function refOf(r) {
  const ev = r.dump?.events || [];
  const g = ev.find((e) => e.type === 'garble_label');
  const a = ev.find((e) => e.type === 'activate');
  return g?.ref || a?.ref || r.session_ref;
}

function slimEvent(e) {
  const o = { ...e };
  return o;
}

function summary(r) {
  const ev = r.dump.events;
  const by = {};
  for (const e of ev) {
    if (!by[e.type]) by[e.type] = [];
    by[e.type].push(e);
  }
  const pick = (t) => (by[t] || []).map(slimEvent);
  return {
    garbled: r.garbled,
    round: r.round,
    session_ref: r.session_ref,
    click_to_sub: r.click_to_sub,
    sub_to_snap: r.sub_to_snap,
    snap_to_last_resize: r.snap_to_last_resize,
    settle_ms: r.settle_ms,
    listing_cols: r.listing_cols,
    listing_rows: r.listing_rows,
    dump: {
      seq: r.dump.seq,
      dropped: r.dump.dropped,
      length: r.dump.length,
      settle: r.dump.settle,
      events: ev,
      counts: Object.fromEntries(Object.entries(by).map(([k, v]) => [k, v.length])),
    },
    _geom: {
      subscribe: pick('subscribe'),
      snapshot_bytes: pick('snapshot').map((e) => ({ bytes: e.bytes, ref: e.ref })),
      write_snapshot: pick('write_snapshot').map((e) => ({
        term_cols: e.term_cols, term_rows: e.term_rows, bytes: e.bytes,
      })),
      last_fit: (by.fit || []).slice(-1).map((e) => ({
        cols: e.cols, rows: e.rows, term_cols: e.term_cols, term_rows: e.term_rows,
        path: e.path, early_exit: e.early_exit, will_resize: e.will_resize,
      })),
      term_resize: pick('term_resize').map((e) => ({
        from_cols: e.from_cols, from_rows: e.from_rows, to_cols: e.to_cols, to_rows: e.to_rows,
      })),
      resize_up: pick('resize_up').map((e) => ({
        cols: e.cols, rows: e.rows, sent: e.sent, reason: e.reason,
      })),
      garble_label: pick('garble_label').map((e) => ({
        garbled: e.garbled, reasons: e.reasons, max_line_width: e.max_line_width,
        overwide_lines: e.overwide_lines, geom: e.geom,
      })),
    },
  };
}

const mixedKey = 'ta-a9fd5b7defbd';
const mixed = rows.filter((r) => String(refOf(r)).includes('%97') || String(r.session_ref || '').includes('%97'));

// find session with both labels, prefer 1/10 so contrast is sharp
const byRef = new Map();
for (const r of rows) {
  const k = refOf(r);
  if (!byRef.has(k)) byRef.set(k, []);
  byRef.get(k).push(r);
}

let chosen = null;
for (const [k, list] of byRef) {
  const p = list.filter((r) => r.garbled);
  const n = list.filter((r) => !r.garbled);
  if (p.length && n.length) {
    const score = Math.min(p.length, n.length);
    if (!chosen || p.length + n.length < chosen.total) {
      chosen = { k, p, n, total: p.length + n.length };
    }
  }
}

const always = [];
for (const [k, list] of byRef) {
  if (list.every((r) => r.garbled)) always.push({ k, n: list.length });
}

const never = [];
for (const [k, list] of byRef) {
  if (list.every((r) => !r.garbled)) never.push(k);
}

const pos = chosen.p[0];
const neg = chosen.n[0];

function geomEqual(a, b) {
  const ga = summary(a)._geom;
  const gb = summary(b)._geom;
  const keys = ['subscribe', 'last_fit', 'term_resize', 'resize_up'];
  const out = {};
  for (const k of keys) out[k] = JSON.stringify(ga[k]) === JSON.stringify(gb[k]);
  return out;
}

writeFileSync(join(here, 'inseparable-pair.json'), JSON.stringify({
  chosen_ref: chosen.k,
  garbled_rounds: chosen.p.map((r) => r.round),
  clean_rounds: chosen.n.map((r) => r.round),
  geom_fields_equal_pos0_vs_neg0: geomEqual(pos, neg),
  pos: summary(pos),
  neg: summary(neg),
  always_garbled: always,
  never_count: never.length,
}, null, 2));

console.error(JSON.stringify({
  chosen: chosen.k,
  pRounds: chosen.p.map((r) => r.round),
  nRounds: chosen.n.map((r) => r.round),
  geomEq: geomEqual(pos, neg),
  posBytes: summary(pos)._geom.snapshot_bytes,
  negBytes: summary(neg)._geom.snapshot_bytes,
  posLabel: summary(pos)._geom.garble_label,
  negLabel: summary(neg)._geom.garble_label,
  posSub: summary(pos)._geom.subscribe,
  negSub: summary(neg)._geom.subscribe,
}, null, 2));
