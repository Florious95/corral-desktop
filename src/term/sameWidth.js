/*
 * Capture-width == render-grid-width invariant (ruling 2026-08-23).
 *
 * Snapshots are capture-pane bytes at the subscribe/reshape size. Painting
 * them into a different xterm grid wraps and shears. Protocol `resize` is a
 * no-op when the host pane is already at that size, so geometry changes must
 * re-`subscribe` to force a matched snapshot.
 *
 * A  subscribe only after the local grid has settled
 * B  after a settled grid change, re-subscribe (do not rely on resize)
 * C  do not paint snapshot/delta until sent cols/rows match the grid
 */

export function wrapStats(term) {
  const buf = term.buffer && term.buffer.active;
  if (!buf) return { bufferLen: 0, wrapped: 0, ratio: 0 };
  const n = buf.length;
  let wrapped = 0;
  for (let y = 0; y < n; y++) {
    const line = buf.getLine(y);
    if (line && line.isWrapped) wrapped += 1;
  }
  return { bufferLen: n, wrapped, ratio: n ? wrapped / n : 0 };
}

export class SameWidthController {
  constructor() {
    this.grid = null;
    this.sent = null;
    this.painted = null;
    this.awaitingSnapshot = false;
    this.settled = false;
  }

  proposeGrid(rows, cols) {
    this.grid = { rows, cols };
    this.settled = false;
  }

  /** A: first protocol action after the debounce/webgl settle. */
  settle(rows, cols) {
    this.grid = { rows, cols };
    this.settled = true;
    return this.nextAction();
  }

  nextAction() {
    if (!this.settled || !this.grid) return { type: 'none' };
    const { rows, cols } = this.grid;
    if (!this.sent) return { type: 'subscribe', rows, cols };
    if (this.sent.rows !== rows || this.sent.cols !== cols) {
      return { type: 'subscribe', rows, cols };
    }
    return { type: 'none' };
  }

  noteSent(rows, cols) {
    this.sent = { rows, cols };
    this.awaitingSnapshot = true;
    this.painted = null;
  }

  /** C: paint only when this snapshot is the answer to the last send. */
  acceptSnapshot() {
    if (!this.sent || !this.grid) return false;
    if (this.sent.cols !== this.grid.cols || this.sent.rows !== this.grid.rows) return false;
    if (!this.awaitingSnapshot && this.painted
        && this.painted.cols === this.sent.cols && this.painted.rows === this.sent.rows) {
      this.painted = { ...this.sent };
      return true;
    }
    if (!this.awaitingSnapshot) return false;
    this.awaitingSnapshot = false;
    this.painted = { ...this.sent };
    return true;
  }

  acceptDelta() {
    if (this.awaitingSnapshot) return false;
    if (!this.painted || !this.grid) return false;
    return this.painted.cols === this.grid.cols && this.painted.rows === this.grid.rows;
  }
}
