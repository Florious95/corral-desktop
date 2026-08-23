// Isolate the overwide stripped line and feed it alone into xterm 114.
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Terminal } from '@xterm/xterm/lib/xterm.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const CSI_OR_ESC = /\x1b(?:\[[0-?]*[ -/]*[@-~]|].*?(?:\x07|\x1b\\)|[PX^_].*?\x1b\\|[\[\]()#%][0-9;]*[0-9A-Za-z]|.)/gs;

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

function overwideLine(u8, termCols) {
  const raw = new TextDecoder('utf-8', { fatal: false }).decode(u8);
  const lines = raw.replace(CSI_OR_ESC, '').replace(/\r/g, '').split('\n');
  for (const line0 of lines) {
    const line = line0.replace(/\s+$/g, '');
    if (displayWidth(line) > termCols) return line;
  }
  return null;
}

function feed(term, bytes) {
  return new Promise((resolve) => {
    term.reset();
    term.write(bytes, () => resolve());
  });
}

async function measurePlain(text, cols) {
  const term = new Terminal({ cols, rows: 10, scrollback: 20, allowProposedApi: true, convertEol: false });
  await feed(term, text);
  const buf = term.buffer.active;
  const rows = [];
  for (let i = 0; i < Math.min(buf.length, 8); i++) {
    const line = buf.getLine(i);
    if (!line) continue;
    let last = -1;
    const widths = [];
    for (let x = 0; x < line.length; x++) {
      const cell = line.getCell(x);
      const ch = cell ? cell.getChars() : '';
      const w = cell ? cell.getWidth() : 0;
      if (ch) {
        last = x;
        if (widths.length < 6 || x > line.length - 8) widths.push({ x, hex: ch.codePointAt(0).toString(16), w });
      }
    }
    rows.push({
      i, isWrapped: line.isWrapped, occupied: last + 1,
      textHead: line.translateToString(true).slice(0, 20),
    });
  }
  term.dispose();
  return rows;
}

const path = join(here, 'wrap-probe/default-socket-p1.snapshot.bin');
const bytes = new Uint8Array(readFileSync(path));
const line = overwideLine(bytes, 114);
const chars = [...line];
const perChar = chars.map((ch) => ({
  hex: ch.codePointAt(0).toString(16),
  dw: displayWidth(ch),
}));
const wideChars = perChar.filter((c) => c.dw === 2);

const rows114 = await measurePlain(line, 114);
const rows115 = await measurePlain(line, 115);
const rows116 = await measurePlain(line, 116);

// Ambiguous-width suspects: box, punctuation, latin-1
const suspects = perChar.filter((c) => {
  const n = parseInt(c.hex, 16);
  return (n >= 0x2500 && n <= 0x257f) || n === 0x3002 || n === 0xff0c || n === 0x2014 || n === 0x2026;
});

const report = {
  dw: displayWidth(line),
  chars: chars.length,
  wideCount: wideChars.length,
  narrowCount: perChar.filter((c) => c.dw === 1).length,
  // do not dump full line text into logs; keep codepoints only
  allHex: perChar.map((c) => `${c.hex}:${c.dw}`).join(' '),
  xtermPlain114: rows114,
  xtermPlain115: rows115,
  xtermPlain116: rows116,
};

writeFileSync(join(here, 'wrap-probe/line-isolate.json'), JSON.stringify(report, null, 2));
console.error(JSON.stringify({
  dw: report.dw, chars: report.chars, wideCount: report.wideCount,
  wrap114: rows114.map((r) => ({ i: r.i, w: r.isWrapped, occ: r.occupied })),
  wrap115: rows115.map((r) => ({ i: r.i, w: r.isWrapped, occ: r.occupied })),
  wrap116: rows116.map((r) => ({ i: r.i, w: r.isWrapped, occ: r.occupied })),
}, null, 2));
