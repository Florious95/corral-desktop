#!/usr/bin/env node
/** Fixture screen metrics. No pane body except the already-published '/ 500K'. */
import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Terminal } from '@xterm/xterm/lib/xterm.mjs';
import { wrapStats } from '../../../src/term/sameWidth.js';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '../../..');

function rowText(term, y, cols) {
  const line = term.buffer.active.getLine(y);
  if (!line) return '';
  let s = '';
  for (let x = 0; x < cols; x++) {
    const cell = line.getCell(x);
    if (cell) s += cell.getChars() || ' ';
  }
  return s.trimEnd();
}

async function paint(bytes, cols, rows) {
  const term = new Terminal({
    cols, rows, scrollback: 1000, convertEol: false, allowProposedApi: true,
  });
  await new Promise((r) => term.write(bytes, () => r()));
  const st = wrapStats(term);
  const line2 = rowText(term, 2, cols);
  term.dispose();
  return { ...st, line2_public: line2 === '/ 500K' ? '/ 500K' : '[redacted]' };
}

const wide = new Uint8Array(readFileSync(join(root, 'test/testdata/garble/wide-host.snapshot.bin')));
const out = {
  wide_235: await paint(wide, 235, 50),
  wide_114: await paint(wide, 114, 39),
};
writeFileSync(join(here, 'invariant-screen.json'), JSON.stringify(out, null, 2));
process.stderr.write(`${JSON.stringify(out)}\n`);
