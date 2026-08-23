import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseSessionRef, parseDisplay, TMUX_FMT } from '../.team/nodes/garble/tmux-pane-query.mjs';

test('parseSessionRef splits socket US pane_id', () => {
  const r = parseSessionRef('/tmp/tmux-501/default\x1f%12');
  assert.deepEqual(r, { socket: '/tmp/tmux-501/default', pane: '%12' });
});

test('parseSessionRef rejects garbage (no tmux call)', () => {
  assert.equal(parseSessionRef(''), null);
  assert.equal(parseSessionRef('%0'), null);
  assert.equal(parseSessionRef('/tmp/tmux-501/default'), null);
  assert.equal(parseSessionRef('not-a-path\x1f%0'), null);
});

test('parseDisplay reads brief format including window-size=manual', () => {
  const g = parseDisplay('235x48 win=235x48 ws=manual clients=0\n');
  assert.equal(g.tmux_pane_w, 235);
  assert.equal(g.tmux_pane_h, 48);
  assert.equal(g.tmux_window_size, 'manual');
  assert.equal(g.tmux_clients, 0);
});

test('TMUX_FMT matches the brief display-message template', () => {
  assert.match(TMUX_FMT, /pane_width/);
  assert.match(TMUX_FMT, /window-size/);
  assert.match(TMUX_FMT, /session_attached/);
});
