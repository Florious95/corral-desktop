import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

const ROOT = join(import.meta.dirname, '..');
const app = readFileSync(join(ROOT, 'src', 'App.jsx'), 'utf8');
const css = readFileSync(join(ROOT, 'src', 'components', 'terminal', 'terminal.css'), 'utf8');

test('bottom image footer is absent while Ctrl+V remains routed', () => {
  assert.doesNotMatch(app, /InputBar|handleFileForActive|fileToAttachment/);
  assert.equal(existsSync(join(ROOT, 'src', 'components', 'terminal', 'InputBar.jsx')), false);
  assert.doesNotMatch(css, /terminal-inputbar/);
  assert.match(app, /handlePaneCtrlV/);
  assert.match(app, /readCtrlV/);
});
