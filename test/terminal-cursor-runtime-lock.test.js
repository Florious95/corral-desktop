import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TerminalView } from '../src/term/TerminalView.js';

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
