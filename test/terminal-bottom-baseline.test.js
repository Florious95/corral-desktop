import { test } from 'node:test';
import assert from 'node:assert/strict';
import { collectTerminalBaselines } from '../scripts/terminal-bottom-baseline-harness.mjs';

test('bottom receipt distinguishes flush grids from equally inset grids', () => {
  const previous = { window: globalThis.window, innerWidth: globalThis.innerWidth, innerHeight: globalThis.innerHeight };
  const element = (bottom, height) => ({
    getBoundingClientRect: () => ({ x: 0, y: bottom - height, width: 600, height, bottom }),
    closest: selector => selector === '.terminalpane' ? { dataset: { presenceMode: 'takeover' } } : null,
  });
  const terminal = (bottom, height) => {
    const screen = element(bottom, height), root = element(bottom, height);
    root.parentElement = element(bottom, height + 4);
    root.querySelector = () => screen;
    return { element: root, rows: height / 15, cols: 80,
      buffer: { active: { viewportY: 0, cursorY: height / 15 - 1, getLine: () => ({ translateToString: () => 'content' }) } } };
  };
  globalThis.innerWidth = 1200;
  globalThis.innerHeight = 900;
  try {
    for (const gap of [0, 5]) {
      globalThis.window = { devicePixelRatio: 2,
        __AGENTMIRROR_TEST_HOOKS__: { terminals: new Set([terminal(900 - gap, 870), terminal(900 - gap, 420)]) } };
      const r = collectTerminalBaselines();
      assert.equal(r.bottomSpreadDevicePixels, 0, 'relative alignment alone cannot detect an equal inset');
      assert.equal(r.viewportBottomGap, gap);
      assert.deepEqual(r.bottomScreenGapsDevicePixels, [gap * 2, gap * 2]);
    }
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete globalThis[key];
      else globalThis[key] = value;
    }
  }
});
