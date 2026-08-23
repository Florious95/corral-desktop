#!/usr/bin/env node
import { createReadStream } from 'node:fs';
import { createInterface } from 'node:readline';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const rows = [];
for await (const line of createInterface({ input: createReadStream(join(here, 'sweep-full.jsonl')) })) {
  if (line.trim()) rows.push(JSON.parse(line));
}

function evalPred(pred) {
  let tp = 0, fp = 0, tn = 0, fn = 0, unk = 0;
  const fps = [], fns = [];
  for (const r of rows) {
    const v = pred(r);
    const g = r.garbled === true;
    if (v == null) { unk++; continue; }
    if (v && g) tp++;
    else if (v && !g) { fp++; if (fps.length < 3) fps.push(r); }
    else if (!v && !g) tn++;
    else { fn++; if (fns.length < 3) fns.push(r); }
  }
  return { tp, fp, tn, fn, unk, ok: fp === 0 && fn === 0 && unk === 0, fps: fps.map(refOf), fns: fns.map(refOf) };
}
function refOf(r) {
  const g = (r.dump?.events || []).find((e) => e.type === 'garble_label');
  return `${g?.ref} r${r.round}`;
}

const rules = {
  'first_resize_up.t > snapshot.t': (r) => {
    const ev = r.dump.events;
    const snap = ev.find((e) => e.type === 'snapshot');
    const ru = ev.find((e) => e.type === 'resize_up');
    if (!snap || !ru) return null;
    return ru.t > snap.t;
  },
  'no resize_up before snapshot': (r) => {
    const ev = r.dump.events;
    const snap = ev.find((e) => e.type === 'snapshot');
    if (!snap) return null;
    const before = ev.filter((e) => e.type === 'resize_up' && e.t <= snap.t);
    return before.length === 0;
  },
  'resize_up count after snap > 0 && none before': (r) => {
    const ev = r.dump.events;
    const snap = ev.find((e) => e.type === 'snapshot');
    if (!snap) return null;
    const before = ev.filter((e) => e.type === 'resize_up' && e.t <= snap.t).length;
    const after = ev.filter((e) => e.type === 'resize_up' && e.t > snap.t).length;
    return before === 0 && after > 0;
  },
  'n_delta === 3': (r) => evCount(r, 'delta') === 3,
  'n_delta < 4': (r) => evCount(r, 'delta') < 4,
  'snapshot.bytes < 4000': (r) => {
    const s = r.dump.events.find((e) => e.type === 'snapshot');
    return s.bytes < 4000;
  },
  'resize_up after snap AND bytes < 4000': (r) => {
    const ev = r.dump.events;
    const snap = ev.find((e) => e.type === 'snapshot');
    const ru = ev.find((e) => e.type === 'resize_up');
    if (!snap || !ru) return null;
    return ru.t > snap.t && snap.bytes < 4000;
  },
};

function evCount(r, t) {
  return (r.dump.events || []).filter((e) => e.type === t).length;
}

for (const [name, pred] of Object.entries(rules)) {
  console.log(name, JSON.stringify(evalPred(pred)));
}

// distribution of resize_up vs snap order by label
let posBefore = 0, posAfter = 0, posNone = 0;
let negBefore = 0, negAfter = 0, negNone = 0;
for (const r of rows) {
  const ev = r.dump.events;
  const snap = ev.find((e) => e.type === 'snapshot');
  const rus = ev.filter((e) => e.type === 'resize_up');
  const before = rus.filter((e) => e.t <= snap.t).length;
  const after = rus.filter((e) => e.t > snap.t).length;
  const bucket = before ? 'before' : after ? 'after' : 'none';
  if (r.garbled) {
    if (bucket === 'before') posBefore++;
    else if (bucket === 'after') posAfter++;
    else posNone++;
  } else {
    if (bucket === 'before') negBefore++;
    else if (bucket === 'after') negAfter++;
    else negNone++;
  }
}
console.log({ posBefore, posAfter, posNone, negBefore, negAfter, negNone });
