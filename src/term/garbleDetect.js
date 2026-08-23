/*
 * Cheap labeler only: is this screen garbled? Not a root-cause analyzer.
 * ⛔ Do not infer grid width from CUP max column (PR #58).
 */

const CSI_OR_ESC = /\x1b(?:\[[0-?]*[ -/]*[@-~]|].*?(?:\x07|\x1b\\)|[PX^_].*?\x1b\\|[\[\]()#%][0-9;]*[0-9A-Za-z]|.)/gs;
const BOX_RUN = /[\u2500\u2501\u2550\u2504\u2505\u2508\u2509]+/g;

function displayWidth(str) {
  let w = 0;
  for (const ch of str) {
    const c = ch.codePointAt(0);
    if (c <= 0x1f || (c >= 0x7f && c <= 0x9f)) continue;
    if (c >= 0x300 && c <= 0x36f) continue;
    if (isWide(c)) w += 2;
    else w += 1;
  }
  return w;
}

function isWide(c) {
  return (c >= 0x1100 && c <= 0x115f)
    || (c >= 0x2e80 && c <= 0x9fff)
    || (c >= 0xac00 && c <= 0xd7af)
    || (c >= 0xf900 && c <= 0xfaff)
    || (c >= 0xfe10 && c <= 0xfe19)
    || (c >= 0xff01 && c <= 0xff60)
    || (c >= 0xffe0 && c <= 0xffe6)
    || (c >= 0x1f300 && c <= 0x1faff);
}

function stripAnsi(text) {
  return text.replace(CSI_OR_ESC, '');
}

function asText(snapshot) {
  if (snapshot == null) return '';
  if (typeof snapshot === 'string') return snapshot;
  const u8 = snapshot instanceof Uint8Array ? snapshot : new Uint8Array(snapshot);
  return new TextDecoder('utf-8', { fatal: false }).decode(u8);
}

/** CUP params only for clamp detection — never as inferred width. */
function cupParams(raw) {
  const out = [];
  const re = /\x1b\[(\d+);(\d+)H/g;
  let m;
  while ((m = re.exec(raw))) {
    out.push({ row: Number(m[1]), col: Number(m[2]) });
  }
  return out;
}

/**
 * @param {{ snapshot?: Uint8Array|string, termCols: number, termRows?: number }} state
 * @returns {{ garbled: boolean, reasons: string[], metrics: object }}
 */
export function detectGarble(state) {
  const termCols = Number(state && state.termCols);
  const termRows = state && state.termRows != null ? Number(state.termRows) : null;
  const reasons = [];
  const metrics = {
    termCols: termCols || null,
    termRows,
    lineCount: 0,
    maxLineWidth: 0,
    maxLineChars: 0,
    maxLineHasWide: false,
    overwideLines: 0,
    nLinesWidthEqCols: 0,
    nLinesWidthColsPlus1: 0,
    maxBoxRun: 0,
    overwideBoxRuns: 0,
    cupCount: 0,
    cupClamped: 0,
    maxCupCol: 0,
    maxCupRow: 0,
  };

  if (!Number.isFinite(termCols) || termCols < 1) {
    return { garbled: true, reasons: ['missing_term_cols'], metrics };
  }

  const raw = asText(state.snapshot);
  const cups = cupParams(raw);
  metrics.cupCount = cups.length;
  for (const cup of cups) {
    if (cup.col > metrics.maxCupCol) metrics.maxCupCol = cup.col;
    if (cup.row > metrics.maxCupRow) metrics.maxCupRow = cup.row;
    if (cup.col > termCols || (termRows != null && cup.row > termRows)) {
      metrics.cupClamped += 1;
    }
  }
  // CUP out of the local grid means the snapshot was addressed for a larger pane.
  if (metrics.cupClamped > 0) reasons.push('cup_clamped');

  const lines = stripAnsi(raw).replace(/\r/g, '').split('\n');
  metrics.lineCount = lines.length;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/\s+$/g, '');
    const w = displayWidth(line);
    if (w > metrics.maxLineWidth) {
      metrics.maxLineWidth = w;
      metrics.maxLineChars = [...line].length;
      metrics.maxLineHasWide = false;
      for (const ch of line) {
        const c = ch.codePointAt(0);
        if (isWide(c)) { metrics.maxLineHasWide = true; break; }
      }
    }
    if (w > termCols) {
      metrics.overwideLines += 1;
    }
    if (w === termCols) metrics.nLinesWidthEqCols += 1;
    if (w === termCols + 1) metrics.nLinesWidthColsPlus1 += 1;
    BOX_RUN.lastIndex = 0;
    let bm;
    while ((bm = BOX_RUN.exec(line))) {
      const bw = displayWidth(bm[0]);
      if (bw > metrics.maxBoxRun) metrics.maxBoxRun = bw;
      if (bw > termCols) metrics.overwideBoxRuns += 1;
    }
  }

  if (metrics.overwideLines > 0) reasons.push('overwide_line');
  if (metrics.overwideBoxRuns > 0) reasons.push('box_run_exceeds_cols');

  return {
    garbled: reasons.length > 0,
    reasons,
    metrics,
  };
}
