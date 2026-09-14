import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  AGENT_OVERSCAN, AGENT_ROW_HEIGHT, sortAgents, visibleWindow,
} from '../src/components/sidebar/agentWindow.js';

test('large agent catalogs render only a viewport-sized constant window', () => {
  const total = 5000;
  const viewportHeight = AGENT_ROW_HEIGHT * 7;
  const window = visibleWindow(total, 0, viewportHeight);
  assert.equal(window.start, 0);
  assert.equal(window.end, 7 + AGENT_OVERSCAN);
  assert.ok(window.end - window.start < 25);
});

test('scroll window follows scrollTop and stays within catalog bounds', () => {
  const total = 5000;
  const viewportHeight = AGENT_ROW_HEIGHT * 7;
  const window = visibleWindow(total, AGENT_ROW_HEIGHT * 100, viewportHeight);
  assert.deepEqual(window, { start: 96, end: 111 });
  const tail = visibleWindow(total, total * AGENT_ROW_HEIGHT, viewportHeight);
  assert.deepEqual(tail, { start: total - AGENT_OVERSCAN, end: total });
});

test('fractional scroll keeps DOM window within the viewport plus overscan bound', () => {
  const total = 5000;
  const viewportHeight = AGENT_ROW_HEIGHT * 7;
  const window = visibleWindow(total, (AGENT_ROW_HEIGHT * 100) + 0.5, viewportHeight);
  assert.ok(window.end - window.start <= 7 + (AGENT_OVERSCAN * 2));
  assert.equal(window.start, 96);
  assert.equal(window.end, 111);
});

test('favourites sort first while preserving stable order within each group', () => {
  const agents = [
    { key: 'a', fav: false },
    { key: 'b', fav: true },
    { key: 'c', fav: false },
    { key: 'd', fav: true },
  ];
  assert.deepEqual(sortAgents(agents).map((agent) => agent.key), ['b', 'd', 'a', 'c']);
  assert.deepEqual(agents.map((agent) => agent.key), ['a', 'b', 'c', 'd']);
});
