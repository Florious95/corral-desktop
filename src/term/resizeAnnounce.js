/**
 * Multi-client tmux size (2026-08-22).
 *
 * Daemon attach is pipe-pane + resize-window (not a client-side `new-session -t`).
 * Desktop only sends `resize` when our DOM changes, so a smaller client leaving
 * never prompts us to grow the session back. Reassert last wanted rows/cols on
 * an external cause (focus / visibility / capture narrower than we asked).
 *
 * ⛔ No interval polling — daemon Resize sets window-size latest every time.
 */

export const REASSERT_MS = 250;

/** CSI / OSC out; leftover printable length. */
export function visibleWidth(line) {
  const s = String(line)
    .replace(/\x1b\][^\x07]*(\x07|\x1b\\)/g, '')
    .replace(/\x1b\[[0-9;?]*[ -/]*[@-~]/g, '')
    .replace(/\x1b./g, '')
    .replace(/\r/g, '');
  return s.length;
}

/**
 * capture-pane of a smaller window is full-width lines of that pane.
 * If many lines share the same max width and that width is below our grid, we
 * should re-send resize. Sparse prompts must not look like a 10-col pane.
 */
export function inferCapturedCols(text) {
  const widths = String(text).split(/\n/).map(visibleWidth).filter((w) => w > 0);
  if (widths.length < 4) return null;
  const max = Math.max(...widths);
  if (max < 20) return null;
  const atMax = widths.filter((w) => w === max).length;
  if (atMax < Math.ceil(widths.length * 0.5)) return null;
  return max;
}

export function createResizeAnnouncer({ reassertMs = REASSERT_MS, send } = {}) {
  if (typeof send !== 'function') throw new Error('createResizeAnnouncer needs send');
  let rows = 0;
  let cols = 0;
  let timer = null;
  let sends = 0;

  const flush = () => {
    timer = null;
    if (rows < 1 || cols < 1) return;
    sends += 1;
    send(rows, cols);
  };

  return {
    get rows() { return rows; },
    get cols() { return cols; },
    get sendCount() { return sends; },
    note(nextRows, nextCols) {
      rows = nextRows;
      cols = nextCols;
    },
    /** DOM fit: remember and send (caller already gated on change). */
    fromFit(nextRows, nextCols) {
      this.note(nextRows, nextCols);
      sends += 1;
      send(nextRows, nextCols);
    },
    /** Same dims on the wire so daemon resize-window can grow the pane. */
    reassert() {
      if (rows < 1 || cols < 1) return;
      clearTimeout(timer);
      timer = setTimeout(flush, reassertMs);
    },
    dispose() {
      clearTimeout(timer);
      timer = null;
    },
  };
}
