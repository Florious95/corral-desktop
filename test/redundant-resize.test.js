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
  const pane = app.slice(app.indexOf('<TerminalPane'), app.indexOf('/>', app.indexOf('<TerminalPane')));
  assert.doesNotMatch(pane, /\bonResize\s*=/);

  const terminalPane = source('src/components/terminal/TerminalPane.jsx');
  assert.match(terminalPane, /onResizeRef\.current\?\.\(rows, cols\)/);
  assert.match(terminalPane, /clientRef\.current\?\.subscribe\(target, act\.rows, act\.cols/);
});
