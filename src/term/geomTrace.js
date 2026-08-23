/**
 * Geometry / subscribe ledger (081-style). Numbers and reasons only.
 * Never logs pane bytes, tokens, or titles.
 */

const RING = 8192;
const events = [];
const book = new Map(); // ref -> { rows, cols }

const DROP = /token|authkey|password|payload|data|text|title|bytes$/i;

export function resetGeomTrace() {
  events.length = 0;
  book.clear();
}

export function bookkeep(ref, rows, cols) {
  if (ref == null) return;
  book.set(String(ref), { rows, cols });
}

export function unbook(ref) {
  book.delete(String(ref));
}

export function bookOf(ref) {
  const b = book.get(String(ref));
  return {
    bookkept_rows: b ? b.rows : null,
    bookkept_cols: b ? b.cols : null,
  };
}

export function geomTrace(event, fields = {}) {
  const rec = { t: Date.now(), event };
  for (const [k, v] of Object.entries(fields)) {
    if (DROP.test(k)) continue;
    rec[k] = v === undefined ? null : v;
  }
  events.push(rec);
  if (events.length > RING) events.shift();
  if (typeof process !== 'undefined' && process.env.AM_GEOM_TRACE === '1') {
    process.stderr.write(`${formatLine(rec)}\n`);
  }
  return rec;
}

export function formatLine(rec) {
  const parts = ['geom', rec.event];
  for (const [k, v] of Object.entries(rec)) {
    if (k === 't' || k === 'event') continue;
    parts.push(`${k}=${v === null || v === undefined ? 'null' : v}`);
  }
  return parts.join(' ');
}

export function dumpGeomTrace() {
  return events.slice();
}
