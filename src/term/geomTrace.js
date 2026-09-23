/**
 * Geometry / subscribe ledger (081-style). Numbers and reasons only.
 * Never logs pane bytes, tokens, or titles.
 */

const RING = 8192;
const events = new Array(RING);
let eventCount = 0;
let cursor = 0;
let ENABLED = typeof process !== 'undefined' && process.env?.AM_GEOM_TRACE === '1';
const book = new Map(); // ref -> { rows, cols }

const DROP = /token|authkey|password|payload|data|text|title|bytes$/i;

export function resetGeomTrace() {
  events.fill(undefined);
  eventCount = 0;
  cursor = 0;
  book.clear();
}

/** Explicitly enable capture for diagnostics/tests; production defaults off. */
export function setGeomTraceEnabled(value) {
  ENABLED = Boolean(value);
}

export function isGeomTraceEnabled() { return ENABLED; }

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
  if (!ENABLED) return 0;
  const rec = { t: Date.now(), mono_ms: globalThis.performance?.now() ?? null, event };
  for (const [k, v] of Object.entries(fields)) {
    if (DROP.test(k)) continue;
    rec[k] = v === undefined ? null : v;
  }
  events[cursor] = rec;
  cursor += 1;
  if (cursor === RING) cursor = 0;
  if (eventCount < RING) eventCount += 1;
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
  if (eventCount === 0) return [];
  if (eventCount < RING) return events.slice(0, eventCount);
  return events.slice(cursor).concat(events.slice(0, cursor));
}
