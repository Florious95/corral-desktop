/** Byte-compare two captures. No heuristic. Col is 1-based code point. */
export function firstMismatch(got, exp) {
  const norm = (s) => String(s ?? '').replace(/\r\n/g, '\n').replace(/\s+$/gm, '');
  const gLines = norm(got).split('\n');
  const eLines = norm(exp).split('\n');
  const n = Math.max(gLines.length, eLines.length);
  for (let r = 0; r < n; r++) {
    const gPts = [...(gLines[r] ?? '')];
    const ePts = [...(eLines[r] ?? '')];
    const m = Math.max(gPts.length, ePts.length);
    for (let c = 0; c < m; c++) {
      if (gPts[c] !== ePts[c]) {
        return {
          equal: false,
          row: r + 1,
          col: c + 1,
          got_len: norm(got).length,
          exp_len: norm(exp).length,
        };
      }
    }
  }
  return {
    equal: true,
    row: null,
    col: null,
    got_len: norm(got).length,
    exp_len: norm(exp).length,
  };
}
