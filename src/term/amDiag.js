/*
 * Geometry/subscribe diagnostic ring (truth source). Default-on.
 * Events are structured records only: no pane text, no tokens.
 * window.__amDiag.dump() → JSON for Chrome Runtime.evaluate.
 */

/** 10 rounds × ~50 sessions × ~20 events, with headroom. */
export const AM_DIAG_CAPACITY = 16384;

const STABLE_NEED = 2;

function monotonicMs() {
  if (typeof performance !== 'undefined' && typeof performance.now === 'function') {
    return performance.now();
  }
  return Date.now();
}

const state = {
  seq: 0,
  dropped: 0,
  buf: new Array(AM_DIAG_CAPACITY),
  head: 0,
  length: 0,
  settle: new Map(),
};

function settleOf(ref) {
  if (!ref) return null;
  let s = state.settle.get(ref);
  if (!s) {
    s = {
      ref,
      t0: null,
      t_sub_sent: null,
      t_snap_first: null,
      t_last_resize: null,
      t_stable: null,
      lastGeom: null,
      stableHits: 0,
    };
    state.settle.set(ref, s);
  }
  return s;
}

function touchSettle(ev) {
  const ref = ev.ref;
  if (!ref) return;
  const s = settleOf(ref);
  const t = ev.t;
  if (ev.type === 'activate' && s.t0 == null) s.t0 = t;
  if (ev.type === 'subscribe' && ev.sent === true && s.t_sub_sent == null) s.t_sub_sent = t;
  if (ev.type === 'snapshot' && s.t_snap_first == null) s.t_snap_first = t;
  if (ev.type === 'term_resize') s.t_last_resize = t;
  if (ev.type === 'garble_label') {
    const geom = ev.geom || null;
    if (ev.garbled === false && geom && geom === s.lastGeom) {
      s.stableHits += 1;
      if (s.stableHits >= STABLE_NEED && s.t_stable == null) s.t_stable = t;
    } else {
      s.stableHits = ev.garbled === false && geom ? 1 : 0;
      s.t_stable = null;
    }
    s.lastGeom = geom;
  }
}

function events() {
  const out = [];
  const n = state.length;
  const cap = AM_DIAG_CAPACITY;
  const start = (state.head - n + cap) % cap;
  for (let i = 0; i < n; i++) out.push(state.buf[(start + i) % cap]);
  return out;
}

function settleDump() {
  const out = {};
  for (const [ref, s] of state.settle) {
    const t0 = s.t0;
    const tStable = s.t_stable;
    out[ref] = {
      t0: s.t0,
      t_sub_sent: s.t_sub_sent,
      t_snap_first: s.t_snap_first,
      t_last_resize: s.t_last_resize,
      t_stable: s.t_stable,
      settle_ms: t0 != null && tStable != null ? tStable - t0 : null,
      segments: {
        click_to_sub: t0 != null && s.t_sub_sent != null ? s.t_sub_sent - t0 : null,
        sub_to_snap: s.t_sub_sent != null && s.t_snap_first != null ? s.t_snap_first - s.t_sub_sent : null,
        snap_to_last_resize: s.t_snap_first != null && s.t_last_resize != null
          ? s.t_last_resize - s.t_snap_first : null,
        last_resize_to_stable: s.t_last_resize != null && tStable != null ? tStable - s.t_last_resize : null,
      },
    };
  }
  return out;
}

export function resetDiag() {
  state.seq = 0;
  state.dropped = 0;
  state.head = 0;
  state.length = 0;
  state.settle = new Map();
}

export function beginActivate(ref) {
  push({ type: 'activate', ref });
}

export function push(partial) {
  try {
    const ev = {
      t: monotonicMs(),
      seq: ++state.seq,
      ...partial,
    };
    state.buf[state.head] = ev;
    state.head = (state.head + 1) % AM_DIAG_CAPACITY;
    if (state.length < AM_DIAG_CAPACITY) state.length += 1;
    else state.dropped += 1;
    touchSettle(ev);
  } catch {
    /* diag must never throw into product paths */
  }
}

export function dump() {
  return {
    seq: state.seq,
    dropped: state.dropped,
    length: state.length,
    events: events(),
    settle: settleDump(),
  };
}

function install() {
  const api = {
    dump: () => dump(),
    reset: () => resetDiag(),
    push,
    beginActivate,
    capacity: AM_DIAG_CAPACITY,
  };
  if (typeof globalThis !== 'undefined') globalThis.__amDiag = api;
  if (typeof window !== 'undefined') window.__amDiag = api;
}

install();
