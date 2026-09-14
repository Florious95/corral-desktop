import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(new URL('../src/components/sidebar/AgentsList.jsx', import.meta.url), 'utf8');
const appSource = readFileSync(new URL('../src/App.jsx', import.meta.url), 'utf8');

test('AgentsList uses memoized sorted/tops derivations and renders only the window', () => {
  assert.match(source, /const sorted = useMemo\(\(\) => sortAgents\(agents\), \[agents\]\)/);
  assert.match(source, /const tops = useMemo\(\(\) => new Map\(sorted\.map/);
  assert.match(source, /const windowed = sorted\.slice\(start, end\)/);
  assert.match(source, /const AgentRow = memo\(function AgentRow/);
  assert.doesNotMatch(source, /\{agents\.map\(\(ag\) =>/);
});

test('App memoizes the sidebar favourite count', () => {
  assert.match(appSource, /const favCount = useMemo\(\(\) => allAgents\.reduce\(/);
});
