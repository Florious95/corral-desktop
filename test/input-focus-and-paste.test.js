import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { TerminalView } from '../src/term/TerminalView.js';
import {
  extractPasteEventSnapshot,
  fileToImageAttachment,
} from '../src/term/clipboard.js';
import {
  setNativeEngineForTests,
  resetNativeEngineForTests,
} from '../src/core/nativeCapabilities.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

class FakeTerminalForFocus {
  constructor(opts) {
    this.opts = opts;
    this.cols = 80;
    this.rows = 24;
    this.writes = [];
    this.keyHandler = null;
    this.focused = false;
    this.pasteHandlers = [];
    this.textarea = {
      style: {},
      focus: () => { this.focused = true; },
      blur: () => { this.focused = false; },
      addEventListener: (type, cb) => {
        if (type === 'paste') this.pasteHandlers.push(cb);
      },
      removeEventListener: (type, cb) => {
        if (type === 'paste') {
          this.pasteHandlers = this.pasteHandlers.filter((h) => h !== cb);
        }
      },
    };
    this.element = {
      querySelector: () => ({ getBoundingClientRect: () => ({ width: 640, height: 384 }) }),
    };
  }
  open() {}
  onScroll() { return { dispose: () => {} }; }
  onData() { return { dispose: () => {} }; }
  onBinary() { return { dispose: () => {} }; }
  attachCustomKeyEventHandler(fn) { this.keyHandler = fn; return true; }
  resize(cols, rows) { this.cols = cols; this.rows = rows; }
  focus() {
    this.textarea.focus();
  }
  blur() {
    this.textarea.blur();
  }
  hasSelection() {
    return Boolean(this.selection);
  }
  getSelection() {
    return this.selection || '';
  }
  dispose() {}
}

test('terminal.css declares pointer-events: none on .terminalpane-placeholder to prevent click blocking', () => {
  const cssFile = path.resolve(__dirname, '../src/components/terminal/terminal.css');
  const content = fs.readFileSync(cssFile, 'utf8');

  assert.match(
    content,
    /\.terminalpane-placeholder\s*\{[^}]*pointer-events:\s*none;/,
    '.terminalpane-placeholder must have pointer-events: none so clicks pass through to terminal container',
  );
});

test('TerminalPane.jsx does not register capture-phase keydown or contextmenu interceptors', () => {
  const paneFile = path.resolve(__dirname, '../src/components/terminal/TerminalPane.jsx');
  const content = fs.readFileSync(paneFile, 'utf8');

  // Must NOT intercept keydown in capture phase
  assert.ok(
    !content.includes("addEventListener('keydown'"),
    'TerminalPane.jsx must not register capture-phase keydown listener',
  );

  // Must NOT intercept contextmenu in capture phase
  assert.ok(
    !content.includes("addEventListener('contextmenu'"),
    'TerminalPane.jsx must not register capture-phase contextmenu listener',
  );

  // Must declare onMouseDown on terminalpane to wake focus
  assert.match(
    content,
    /onMouseDown=\{handlePaneMouseDown\}/,
    'TerminalPane.jsx must declare onMouseDown={handlePaneMouseDown} on container',
  );
});

test('SplitPanes.jsx guards onMouseDown against .pane-close-btn to avoid stealing focus on close', () => {
  const splitFile = path.resolve(__dirname, '../src/components/terminal/SplitPanes.jsx');
  const content = fs.readFileSync(splitFile, 'utf8');

  assert.ok(
    content.includes('.pane-close-btn') && content.includes('closest'),
    'SplitPanes.jsx must guard onMouseDown against pane close button',
  );
});

test('TerminalView attachCustomKeyEventHandler accurately routes keys by platform and modifiers', () => {
  // Test Windows platform routing
  setNativeEngineForTests({ platform: 'windows' });
  try {
    let forceTextCalled = false;
    let ctrlVCalled = false;

    const container = { isConnected: true, clientWidth: 800, clientHeight: 400 };
    const view = new TerminalView(container, {
      TerminalCtor: FakeTerminalForFocus,
      onForceTextPaste: () => { forceTextCalled = true; },
      onCtrlV: () => { ctrlVCalled = true; },
    });

    const handler = view.term.keyHandler;
    assert.ok(typeof handler === 'function', 'attachCustomKeyEventHandler must be installed');

    // 1. Windows Ctrl+V returns false without preventDefault (lets native paste proceed to textarea)
    const winCtrlV = { type: 'keydown', ctrlKey: true, metaKey: false, altKey: false, shiftKey: false, key: 'v' };
    assert.equal(handler(winCtrlV), false, 'Windows Ctrl+V must return false to let native paste happen');

    // 2. Windows Ctrl+Shift+V triggers onForceTextPaste and returns false
    const winCtrlShiftV = { type: 'keydown', ctrlKey: true, metaKey: false, altKey: false, shiftKey: true, key: 'v' };
    assert.equal(handler(winCtrlShiftV), false, 'Windows Ctrl+Shift+V must return false');
    assert.equal(forceTextCalled, true, 'onForceTextPaste must be called on Windows Ctrl+Shift+V');

    // 3. Windows Ctrl+Shift+C copies selection and returns false
    view.term.selection = 'selected terminal text';
    let copiedText = '';
    const origClipboard = globalThis.navigator?.clipboard;
    Object.defineProperty(globalThis, 'navigator', {
      value: {
        clipboard: {
          writeText: async (text) => { copiedText = text; },
        },
      },
      configurable: true,
      writable: true,
    });
    try {
      const winCtrlShiftC = { type: 'keydown', ctrlKey: true, metaKey: false, altKey: false, shiftKey: true, key: 'c' };
      assert.equal(handler(winCtrlShiftC), false, 'Windows Ctrl+Shift+C must return false');
      assert.equal(copiedText, 'selected terminal text');
    } finally {
      if (origClipboard) globalThis.navigator.clipboard = origClipboard;
    }

    // 4. Ctrl+C (terminal interrupt) is NOT intercepted, returns true
    const ctrlC = { type: 'keydown', ctrlKey: true, metaKey: false, altKey: false, shiftKey: false, key: 'c' };
    assert.equal(handler(ctrlC), true, 'Ctrl+C must return true for terminal interrupt');

    // 5. Normal keys return true
    assert.equal(handler({ type: 'keydown', key: 'a' }), true);
    assert.equal(handler({ type: 'keydown', key: 'Enter' }), true);
    assert.equal(handler({ type: 'keydown', key: 'Tab' }), true);
    assert.equal(handler({ type: 'keydown', key: 'ArrowUp' }), true);

    // 6. Composition events return true
    assert.equal(handler({ type: 'keydown', isComposing: true, key: 'v' }), true);
    assert.equal(handler({ type: 'keydown', keyCode: 229, key: 'v' }), true);

    view.dispose();
  } finally {
    resetNativeEngineForTests();
  }

  // Test macOS platform routing
  setNativeEngineForTests({ platform: 'macos' });
  try {
    let macCtrlVCalled = false;
    const container = { isConnected: true, clientWidth: 800, clientHeight: 400 };
    const view = new TerminalView(container, {
      TerminalCtor: FakeTerminalForFocus,
      onCtrlV: () => { macCtrlVCalled = true; },
    });

    const handler = view.term.keyHandler;

    // macOS Cmd+V returns false (lets native paste proceed to textarea)
    const macCmdV = { type: 'keydown', metaKey: true, ctrlKey: false, altKey: false, shiftKey: false, key: 'v' };
    assert.equal(handler(macCmdV), false, 'macOS Cmd+V must return false');

    // macOS Ctrl+V triggers image paste hook and returns false
    const macCtrlV = { type: 'keydown', ctrlKey: true, metaKey: false, altKey: false, shiftKey: false, key: 'v' };
    assert.equal(handler(macCtrlV), false, 'macOS Ctrl+V must return false');
    assert.equal(macCtrlVCalled, true, 'macOS Ctrl+V must trigger onCtrlV hook');

    view.dispose();
  } finally {
    resetNativeEngineForTests();
  }
});

test('TerminalView textarea paste listener captures native paste and forwards to onPaste callback', () => {
  let pasteEventReceived = null;
  const container = {
    isConnected: true,
    clientWidth: 800,
    clientHeight: 400,
    addEventListener: () => {},
    removeEventListener: () => {},
  };
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminalForFocus,
    onPaste: (ev) => { pasteEventReceived = ev; },
  });

  view.open();
  assert.equal(view.term.pasteHandlers.length, 1, 'textarea must have exactly 1 paste listener');

  let defaultPrevented = false;
  let propagationStopped = false;
  const fakeEvent = {
    type: 'paste',
    clipboardData: { getData: () => 'pasted text' },
    preventDefault: () => { defaultPrevented = true; },
    stopPropagation: () => { propagationStopped = true; },
  };

  // Dispatch paste to textarea listener
  view.term.pasteHandlers[0](fakeEvent);

  assert.equal(defaultPrevented, true, 'paste event default must be prevented');
  assert.equal(propagationStopped, true, 'paste event propagation must be stopped');
  assert.equal(pasteEventReceived, fakeEvent, 'onPaste callback must receive the event');

  view.dispose();
  assert.equal(view.term.pasteHandlers.length, 0, 'paste listener must be removed on dispose');
});

test('extractPasteEventSnapshot strictly prioritizes text/plain over images and handles multiline without auto-enter', async () => {
  const fakePng = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
  const fakeFile = {
    name: 'screenshot.png',
    type: 'image/png',
    arrayBuffer: async () => fakePng.buffer,
  };

  // Case 1: Both text and image present -> text wins unconditionally (Priority 1)
  const textAndImageEvent = {
    clipboardData: {
      getData: (type) => (type === 'text/plain' ? 'echo "multiline\ncommand"' : ''),
      items: [
        { kind: 'string', type: 'text/plain' },
        { kind: 'file', type: 'image/png', getAsFile: () => fakeFile },
      ],
      files: [fakeFile],
    },
  };
  const snap1 = extractPasteEventSnapshot(textAndImageEvent);
  assert.equal(snap1.text, 'echo "multiline\ncommand"');
  assert.equal(snap1.imageFile, null, 'imageFile must be null when text is present');

  // Case 2: Only image present (text is empty) -> image extracted (Priority 2)
  const imageOnlyEvent = {
    clipboardData: {
      getData: () => '',
      items: [
        { kind: 'file', type: 'image/png', getAsFile: () => fakeFile },
      ],
      files: [fakeFile],
    },
  };
  const snap2 = extractPasteEventSnapshot(imageOnlyEvent);
  assert.equal(snap2.text, '');
  assert.ok(snap2.imageFile, 'imageFile must be resolved');

  const attachment = await fileToImageAttachment(snap2.imageFile);
  assert.ok(attachment, 'attachment must be created from imageFile');
  assert.equal(attachment.name, 'screenshot.png');
  assert.equal(attachment.mime, 'image/png');
  assert.deepEqual([...attachment.bytes], [137, 80, 78, 71, 13, 10, 26, 10]);

  // Case 3: Empty clipboardData -> both empty (Priority 3)
  const emptyEvent = {
    clipboardData: {
      getData: () => '',
      items: [],
      files: [],
    },
  };
  const snap3 = extractPasteEventSnapshot(emptyEvent);
  assert.equal(snap3.text, '');
  assert.equal(snap3.imageFile, null);
});

test('Physical focus waking: calling view.focus() focuses underlying textarea directly', () => {
  const container = {
    isConnected: true,
    clientWidth: 800,
    clientHeight: 400,
    addEventListener: () => {},
    removeEventListener: () => {},
  };
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminalForFocus,
  });

  view.open();
  assert.equal(view.term.focused, false, 'initially not focused');

  // Simulate pane click focus call
  view.focus();
  assert.equal(view.term.focused, true, 'calling view.focus() must focus term.textarea');

  view.blur();
  assert.equal(view.term.focused, false, 'calling view.blur() must blur term.textarea');

  view.dispose();
});
