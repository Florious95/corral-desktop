// Deepen the wrap question: compare detectGarble line widths vs xterm cell occupancy.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { detectGarble } from '../../../src/term/garbleDetect.js';
import { Terminal } from '@xterm/xterm/lib/xterm.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const CSI_OR_ESC = /\x1b(?:\[[0-?]*[ -/]*[@-~]|].*?(?:\x07|\x1b\\)|[PX^_].*?\x1b\\|[\[\]()#%][0-9;]*[0-9A-Za-z]|.)/gs;

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

function overwideLines(u8, termCols) {
  const raw = new TextDecoder('utf-8', { fatal: false }).decode(u8);
  const lines = stripAnsi(raw).replace(/\r/g, '').split('\n');
  const hits = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i].replace(/\s+$/g, '');
    const w = displayWidth(line);
    const chars = [...line];
    const hasWide = chars.some((ch) => isWide(ch.codePointAt(0)));
    if (w > termCols) {
      hits.push({
        i,
        w,
        chars: chars.length,
        hasWide,
        // last 8 codepoints + widths, not the whole pane
        tail: chars.slice(-12).map((ch) => ({
          hex: ch.codePointAt(0).toString(16),
          w: displayWidth(ch),
        })),
        head: chars.slice(0, 8).map((ch) => ({
          hex: ch.codePointAt(0).toString(16),
          w: displayWidth(ch),
        })),
      });
    }
  }
  return hits;
}

function feed(term, bytes) {
  return new Promise((resolve) => {
    term.reset();
    term.write(bytes, () => resolve());
  });
}

function xtermRows(term) {
  const buf = term.buffer.active;
  const rows = [];
  let maxCells = 0;
  let wrapped = 0;
  let wrappedAfterFull = 0;
  for (let i = 0; i < buf.length; i++) {
    const line = buf.getLine(i);
    if (!line) continue;
    let cells = 0;
    for (let x = 0; x < line.length; x++) {
      const cell = line.getCell(x);
      if (!cell) continue;
      const w = cell.getWidth();
      const ch = cell.getChars();
      if (ch && ch !== ' ') cells = x + (w || 1);
      else if (ch === ' ' && cells > 0) {
        // keep trailing spaces out of "used" like detectGarble trim
      }
    }
    // trim trailing spaces using translate
    const text = line.translateToString(true).replace(/\s+$/g, '');
    const used = text.length; // code units, not cells — also count via cells
    let lastNonEmpty = -1;
    for (let x = 0; x < line.length; x++) {
      const cell = line.getCell(x);
      if (!cell) continue;
      const ch = cell.getChars();
      if (ch && ch !== '') lastNonEmpty = x;
    }
    const occupied = lastNonEmpty + 1;
    if (occupied > maxCells) maxCells = occupied;
    if (line.isWrapped) {
      wrapped += 1;
      const prev = i > 0 ? buf.getLine(i - 1) : null;
      if (prev && prev.length === term.cols) wrappedAfterFull += 1;
    }
    if (line.isWrapped || occupied > term.cols - 1) {
      rows.push({
        i, isWrapped: line.isWrapped, occupied, trimmedChars: text.length,
      });
    }
  }
  return { maxOccupiedCells: maxCells, wrapped, wrappedAfterFull, notable: rows.slice(0, 12) };
}

const files = [
  ['wide-host', join(here, '../../../test/testdata/garble/wide-host.snapshot.bin')],
  ['matched-host', join(here, '../../../test/testdata/garble/matched-host.snapshot.bin')],
  ['live-default-p1', join(here, 'wrap-probe/default-socket-p1.snapshot.bin')],
  ['live-p90', join(here, 'wrap-probe/pair-session-p90.snapshot.bin')],
];

const out = [];
for (const [name, path] of files) {
  const bytes = new Uint8Array(readFileSync(path));
  const label114 = detectGarble({ snapshot: bytes, termCols: 114, termRows: 39 });
  const hits = overwideLines(bytes, 114);
  const term = new Terminal({ cols: 114, rows: 39, scrollback: 2000, allowProposedApi: true, convertEol: false });
  await feed(term, bytes);
  const xt = xtermRows(term);
  term.dispose();
  out.push({
    name, bytes: bytes.length,
    label: {
      garbled: label114.garbled,
      reasons: label114.reasons,
      maxLineWidth: label114.metrics.maxLineWidth,
      overwideLines: label114.metrics.overwideLines,
      maxBoxRun: label114.metrics.maxBoxRun,
    },
    overwide_line_details: hits,
    xterm114: xt,
  });
}

writeFileSync(join(here, 'wrap-probe/deep.json'), JSON.stringify(out, null, 2));
console.error('wrote deep.json', out.map((r) => `${r.name} mlw=${r.label.maxLineWidth} xtMax=${r.xterm114.maxOccupiedCells} wrap=${r.xterm114.wrapped}`).join(' | '));
