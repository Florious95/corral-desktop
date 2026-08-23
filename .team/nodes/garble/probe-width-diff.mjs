// Find which code points disagree between detectGarble displayWidth and xterm cell width.
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
  return new Promise((resolve) => term.write(bytes, () => resolve()));
}

async function xtermCharWidth(ch) {
  const term = new Terminal({ cols: 10, rows: 3, allowProposedApi: true, convertEol: false });
  await feed(term, ch);
  const line = term.buffer.active.getLine(0);
  let occupied = 0;
  for (let x = 0; x < line.length; x++) {
    const cell = line.getCell(x);
    if (cell && cell.getChars()) occupied = x + cell.getWidth();
  }
  term.dispose();
  return occupied;
}

const bytes = new Uint8Array(readFileSync(join(here, 'wrap-probe/default-socket-p1.snapshot.bin')));
const line = overwideLine(bytes, 114);
const diffs = [];
let dwSum = 0;
let xtSum = 0;
for (const ch of line) {
  const dw = displayWidth(ch);
  const xt = await xtermCharWidth(ch);
  dwSum += dw;
  xtSum += xt;
  if (dw !== xt) {
    diffs.push({ hex: ch.codePointAt(0).toString(16), dw, xt });
  }
}

const report = { dwSum, xtSum, diffs, chars: [...line].length };
writeFileSync(join(here, 'wrap-probe/width-diff.json'), JSON.stringify(report, null, 2));
console.error(JSON.stringify(report, null, 2));
