import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const ROOT = dirname(fileURLToPath(import.meta.url));
const source = (path) => readFileSync(join(ROOT, '..', path), 'utf8');

/** The App must let TerminalPane's settled grid subscribe be the sole wire action. */
test('App does not wire TerminalPane onResize to a second network resize', () => {
  const app = source('src/App.jsx');
  const paneStart = app.indexOf('<TerminalPane');
  const paneEnd = app.indexOf('/>', paneStart);
  assert.notEqual(paneStart, -1, 'App must render TerminalPane');
  assert.notEqual(paneEnd, -1, 'TerminalPane JSX must be closed');
  const pane = app.slice(paneStart, paneEnd + 2);
  assert.doesNotMatch(pane, /\bonResize\s*=/);
  assert.doesNotMatch(pane, /\bdm\.resize\s*\(/);

  const terminalPane = source('src/components/terminal/TerminalPane.jsx');
  assert.match(terminalPane, /onResizeRef\.current\?\.\(rows, cols\)/);
  assert.match(terminalPane, /clientRef\.current\?\.subscribe\(target, act\.rows, act\.cols/);
});

test('TerminalPane requests a same-grid snapshot when delta writes overflow', () => {
  const terminalPane = source('src/components/terminal/TerminalPane.jsx');
  assert.match(terminalPane, /onWriteBackpressure:/);
  assert.match(terminalPane, /gate\.noteSent\(grid\.rows, grid\.cols\)/);
  assert.match(terminalPane, /'write_backpressure'/);
});
