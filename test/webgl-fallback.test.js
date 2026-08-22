import { test } from 'node:test';
import assert from 'node:assert/strict';
import { attachWebglRenderer } from '../src/term/webglRenderer.js';
import { TerminalView } from '../src/term/TerminalView.js';

test('attachWebglRenderer: importer 抛错则静默返回 null，不调用 loadAddon', async () => {
  let loaded = 0;
  const term = { loadAddon() { loaded += 1; } };
  const r = await attachWebglRenderer(term, async () => { throw new Error('no webgl'); });
  assert.equal(r, null);
  assert.equal(loaded, 0);
});

test('attachWebglRenderer: loadAddon 抛错则静默返回 null', async () => {
  const r = await attachWebglRenderer(
    { loadAddon() { throw new Error('context lost'); } },
    async () => ({ WebglAddon: class { onContextLoss() {} dispose() {} } }),
  );
  assert.equal(r, null);
});

test('attachWebglRenderer: 成功时返回 addon 且 loadAddon 被调用一次', async () => {
  const calls = [];
  const addon = { onContextLoss(fn) { this._fn = fn; }, dispose() {} };
  const r = await attachWebglRenderer(
    { loadAddon(a) { calls.push(a); } },
    async () => ({ WebglAddon: class { constructor() { return addon; } } }),
  );
  assert.equal(r, addon);
  assert.equal(calls.length, 1);
});

test('TerminalView.open in node falls back when addon cannot init', async () => {
  const container = {
    isConnected: true,
    clientWidth: 800,
    clientHeight: 400,
    addEventListener() {},
    removeEventListener() {},
  };
  class FakeTerminal {
    constructor(opts) { this.opts = opts; this.cols = 80; this.rows = 24; this.writes = []; }
    open() {}
    onData() { return { dispose() {} }; }
    onScroll() { return { dispose() {} }; }
    attachCustomKeyEventHandler() { return true; }
    resize() {}
    reset() {}
    write(d) { this.writes.push(d); }
    focus() {}
    blur() {}
    dispose() {}
    element = { querySelector: () => ({ getBoundingClientRect: () => ({ width: 640, height: 384 }) }) };
  }
  const view = new TerminalView(container, { TerminalCtor: FakeTerminal });
  view.open();
  assert.equal(view.term.opts.customGlyphs, true);
  assert.equal(view.term.opts.lineHeight, 1.25);
  view.writeSnapshot(new Uint8Array([65]));
  assert.equal(view.term.writes.length, 1);
  await view._webglPromise;
  view.dispose();
});
