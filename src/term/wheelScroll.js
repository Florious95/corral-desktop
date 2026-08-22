/*
 * DOM wheel → protocol scroll_wheel delta (CLIENT-CONTRACT §1.2 / Go InjectScroll).
 * delta < 0 = up (toward history); delta > 0 = down. Same sign as DOM deltaY.
 * Pixel wheels are folded into whole lines so we never send delta=0.
 */

export const WHEEL_FLUSH_MS = 50;
/** Pixels that count as one protocol line when deltaMode is 0 (DOM_DELTA_PIXEL). */
export const LINE_PX = 40;

export function linesFromWheel(ev, linePx = LINE_PX) {
  const y = Number(ev && ev.deltaY);
  if (!Number.isFinite(y) || y === 0) return 0;
  const mode = ev.deltaMode == null ? 0 : ev.deltaMode;
  if (mode === 1) return y;          // already in lines
  if (mode === 2) return y * 24;     // pages
  return y / linePx;
}

export class WheelAccumulator {
  /**
   * @param {(delta:number) => void} send  integer ≠ 0
   * @param {number} [intervalMs]
   */
  constructor(send, intervalMs = WHEEL_FLUSH_MS) {
    this.send = send;
    this.intervalMs = intervalMs;
    this.acc = 0;
    this.timer = null;
  }

  onWheel(ev) {
    this.acc += linesFromWheel(ev);
    if (this.timer) return;
    this.timer = setTimeout(() => this.flush(), this.intervalMs);
  }

  flush() {
    clearTimeout(this.timer);
    this.timer = null;
    const n = Math.trunc(this.acc);
    this.acc -= n;
    if (n !== 0) this.send(n);
  }

  dispose() {
    this.flush();
  }
}
