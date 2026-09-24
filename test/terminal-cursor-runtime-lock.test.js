import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TerminalView } from '../src/term/TerminalView.js';
import {
  attachWebglRenderer,
  isWebglDisabled,
  setDisableWebglForTests,
} from '../src/term/webglRenderer.js';

class MockContainer {
  constructor() {
    this.clientWidth = 800;
    this.clientHeight = 600;
    this.isConnected = true;
    this.style = {};
  }
  addEventListener() {}
  removeEventListener() {}
  querySelector() { return null; }
  querySelectorAll() { return []; }
  getBoundingClientRect() { return { width: 800, height: 600, top: 0, left: 0 }; }
}

test('TerminalView runtime lock blocks DECSCUSR blinking bar (CSI 5 q) from activating cursorBlink', async () => {
  const container = new MockContainer();
  const view = new TerminalView(container);

  assert.equal(view.term.options.cursorBlink, false);

  // Write DECSCUSR blinking bar: \x1b[5 q
  await new Promise((done) => view.term.write('\x1b[5 q', done));

  const decModes = view.term._core?.coreService?.decPrivateModes;
  assert.equal(view.term.options.cursorBlink, false, 'options.cursorBlink must stay false');
  assert.equal(decModes?.cursorBlink, false, 'decPrivateModes.cursorBlink must stay false');
  assert.equal(decModes?.cursorStyle, 'bar', 'cursorStyle must adapt to bar');

  view.dispose();
});

test('TerminalView runtime lock blocks DECSCUSR blinking block (CSI 1 q) and underline (CSI 3 q)', async () => {
  const container = new MockContainer();
  const view = new TerminalView(container);

  const decModes = view.term._core?.coreService?.decPrivateModes;

  // Blinking underline: \x1b[3 q
  await new Promise((done) => view.term.write('\x1b[3 q', done));
  assert.equal(view.term.options.cursorBlink, false);
  assert.equal(decModes?.cursorBlink, false);
  assert.equal(decModes?.cursorStyle, 'underline');

  // Blinking block: \x1b[1 q
  await new Promise((done) => view.term.write('\x1b[1 q', done));
  assert.equal(view.term.options.cursorBlink, false);
  assert.equal(decModes?.cursorBlink, false);
  assert.equal(decModes?.cursorStyle, 'block');

  // Steady block: \x1b[2 q
  await new Promise((done) => view.term.write('\x1b[2 q', done));
  assert.equal(view.term.options.cursorBlink, false);
  assert.equal(decModes?.cursorBlink, false);
  assert.equal(decModes?.cursorStyle, 'block');

  view.dispose();
});

test('TerminalView runtime lock blocks DECSET ?12h and combined escape sequences from activating cursorBlink', async () => {
  const container = new MockContainer();
  const view = new TerminalView(container);

  const decModes = view.term._core?.coreService?.decPrivateModes;

  // DECSET 12: \x1b[?12h
  await new Promise((done) => view.term.write('\x1b[?12h', done));
  assert.equal(view.term.options.cursorBlink, false);
  assert.equal(decModes?.cursorBlink, false);

  // Combined DECSCUSR default + DECSET 12: \x1b[0 q\x1b[?12h
  await new Promise((done) => view.term.write('\x1b[0 q\x1b[?12h', done));
  assert.equal(view.term.options.cursorBlink, false);
  assert.equal(decModes?.cursorBlink, false);

  // Multi-param DECSET: \x1b[?1;12;25h
  await new Promise((done) => view.term.write('\x1b[?1;12;25h', done));
  assert.equal(view.term.options.cursorBlink, false);
  assert.equal(decModes?.cursorBlink, false);
  assert.equal(decModes?.applicationCursorKeys, true, 'other DEC modes must still work');

  view.dispose();
});

test('TerminalView runtime lock resists fragmented/chunked escape sequences across packet boundaries', async () => {
  const container = new MockContainer();
  const view = new TerminalView(container);

  const decModes = view.term._core?.coreService?.decPrivateModes;

  // Chunked DECSCUSR 5: "\x1b[5" then " q"
  await new Promise((done) => view.term.write('\x1b[5', done));
  await new Promise((done) => view.term.write(' q', done));
  assert.equal(view.term.options.cursorBlink, false);
  assert.equal(decModes?.cursorBlink, false);
  assert.equal(decModes?.cursorStyle, 'bar');

  // Chunked DECSET 12: "\x1b[?" then "12h"
  await new Promise((done) => view.term.write('\x1b[?', done));
  await new Promise((done) => view.term.write('12h', done));
  assert.equal(view.term.options.cursorBlink, false);
  assert.equal(decModes?.cursorBlink, false);

  view.dispose();
});

test('TerminalView runtime lock survives writeSnapshot/term.reset and avoids stale closure/stuck block cursor', async () => {
  const container = new MockContainer();
  const view = new TerminalView(container);

  // Set to blinking bar: \x1b[5 q
  await new Promise((done) => view.term.write('\x1b[5 q', done));
  assert.equal(view.term._core.coreService.decPrivateModes.cursorStyle, 'bar');
  assert.equal(view.term._core.coreService.decPrivateModes.cursorBlink, false);

  const originalModes = view.term._core.coreService.decPrivateModes;

  // Perform writeSnapshot (which invokes term.reset())
  view.writeSnapshot(new TextEncoder().encode('\x1b[5 qsnapshot'));
  await new Promise((done) => view.term.write('', done));

  const newModes = view.term._core.coreService.decPrivateModes;
  assert.notEqual(newModes, originalModes, 'term.reset() must replace decPrivateModes instance');
  assert.equal(newModes.cursorBlink, false, 'new decPrivateModes must be immediately re-locked to false');
  assert.equal(typeof Object.getOwnPropertyDescriptor(newModes, 'cursorBlink')?.get, 'function', 'new decPrivateModes must have locked getter');

  // Verify subsequent cursor style updates after reset work properly instead of being stuck at block
  await new Promise((done) => view.term.write('\x1b[3 q', done));
  assert.equal(view.term._core.coreService.decPrivateModes.cursorStyle, 'underline', 'cursorStyle must adapt to underline after reset');
  assert.equal(view.term._core.coreService.decPrivateModes.cursorBlink, false);

  view.dispose();
});

test('TerminalView DECSCUSR accurately parses param 0 as default reset and safely ignores unsupported params', async () => {
  const container = new MockContainer();
  const view = new TerminalView(container);

  // 1. Configure default cursorStyle to bar
  view.term.options.cursorStyle = 'bar';

  // Remote sets underline: \x1b[3 q
  await new Promise((done) => view.term.write('\x1b[3 q', done));
  assert.equal(view.term._core.coreService.decPrivateModes.cursorStyle, 'underline');

  // Remote sends \x1b[0 q (reset to default configured style)
  await new Promise((done) => view.term.write('\x1b[0 q', done));
  const decModes = view.term._core.coreService.decPrivateModes;
  assert.equal(decModes.cursorStyle, undefined, 'param 0 must clear remote cursorStyle to undefined');
  const effectiveStyle = decModes.cursorStyle ?? view.term.options.cursorStyle;
  assert.equal(effectiveStyle, 'bar', 'effectiveStyle must fall back to configured default bar');

  // 2. Remote sets underline: \x1b[3 q, then sends unsupported param 7 (\x1b[7 q)
  await new Promise((done) => view.term.write('\x1b[3 q', done));
  assert.equal(decModes.cursorStyle, 'underline');

  await new Promise((done) => view.term.write('\x1b[7 q', done));
  assert.equal(decModes.cursorStyle, 'underline', 'unsupported param 7 must be safely ignored without forcing block');

  view.dispose();
});

test('WebGL ablation channel: supports explicit disableWebgl parameter and test overrides for Phase 2 energy profiling', async () => {
  setDisableWebglForTests(null);
  assert.equal(isWebglDisabled(), false);

  // 1. Global / test override disables WebGL
  setDisableWebglForTests(true);
  assert.equal(isWebglDisabled(), true);

  const fakeTerm = { loadAddon() {} };
  const res = await attachWebglRenderer(fakeTerm);
  assert.equal(res, null, 'attachWebglRenderer must return null when WebGL is disabled');

  // 2. Per-instance disableWebgl parameter disables WebGL
  setDisableWebglForTests(false);
  assert.equal(isWebglDisabled(), false);

  const resInstance = await attachWebglRenderer(fakeTerm, undefined, { disableWebgl: true });
  assert.equal(resInstance, null, 'Per-instance disableWebgl: true must return null');

  // 3. TerminalView accepts disableWebgl option
  const container = new MockContainer();
  const view = new TerminalView(container, { disableWebgl: true });
  assert.equal(view._disableWebgl, true);
  view.dispose();

  setDisableWebglForTests(null);
});

test('UI-SPEC §6.2 documents 2026-09-24 runtime cursor protocol lock policy', async () => {
  const { readFile } = await import('node:fs/promises');
  const spec = await readFile(new URL('../docs/UI-SPEC.md', import.meta.url), 'utf8');

  assert.match(spec, /2026-09-24（运行期光标协议硬锁策略）/);
  assert.match(spec, /DECSCUSR.*DECSET \?12h/);
  assert.match(spec, /系统级实际能耗与 GPU 占用需经由真实交付面与独立量具消融检验/);
});
