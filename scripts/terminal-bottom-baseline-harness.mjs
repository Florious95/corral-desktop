/** Read-only geometry receipt for an opt-in VITE_TERMINAL_TEST_HOOKS=1 build.
 * Evaluate collectTerminalBaselines.toString() in the browser/WK page.
 * Records numbers only: no terminal text, session identifiers or credentials.
 */
export function collectTerminalBaselines() {
  const terms = window.__AGENTMIRROR_TEST_HOOKS__?.terminals;
  if (!terms) throw new Error('terminal test hooks unavailable');
  const rect = (element) => {
    const r = element.getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height, bottom: r.bottom };
  };
  const dpr = window.devicePixelRatio || 1;
  const panes = [...terms].filter((term) => !term.element.closest('.is-hidden')).map((term, index) => {
    const host = term.element.parentElement;
    const screen = term.element.querySelector('.xterm-screen');
    const h = rect(host), s = rect(screen);
    const cellHeight = s.height / term.rows;
    const buffer = term.buffer.active;
    let lastNonEmptyRow = -1;
    for (let row = 0; row < term.rows; row++) {
      if (buffer.getLine(buffer.viewportY + row)?.translateToString(true)) lastNonEmptyRow = row;
    }
    return { index, presenceMode: host.closest('.terminalpane')?.dataset.presenceMode,
      host: h, root: rect(term.element), screen: s, rows: term.rows, cols: term.cols,
      cellHeight, bottomGap: h.bottom - s.bottom, residual: h.height - s.height,
      lastNonEmptyRow, lastNonEmptyRowBottom: s.y + (lastNonEmptyRow + 1) * cellHeight,
      cursorRow: buffer.cursorY, cursorBottom: s.y + (buffer.cursorY + 1) * cellHeight,
      screenBottomDevicePixels: s.bottom * dpr };
  });
  const bottom = Math.max(...panes.map((p) => p.host.bottom));
  const touchingBottom = panes.filter((p) => Math.abs(p.host.bottom - bottom) < 0.01);
  const edges = touchingBottom.map((p) => p.screenBottomDevicePixels);
  return { dpr, viewport: { width: innerWidth, height: innerHeight }, panes,
    bottomPaneCount: touchingBottom.length,
    bottomSpreadDevicePixels: edges.length ? Math.max(...edges) - Math.min(...edges) : null };
}
