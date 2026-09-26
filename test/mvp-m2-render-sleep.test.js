import { test, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { TerminalView, withHiddenCursor } from '../src/term/TerminalView.js';
import { setNativeEngineForTests, resetNativeEngineForTests } from '../src/core/nativeCapabilities.js';

beforeEach(() => setNativeEngineForTests({ platform: 'macos' }));
afterEach(() => resetNativeEngineForTests());

class FakeElement {
  constructor(tag = 'div') {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.parentElement = null;
    this.style = {};
    this.clientWidth = 800;
    this.clientHeight = 600;
    this.isConnected = true;
  }
  appendChild(child) {
    this.children.push(child);
    child.parentElement = this;
    return child;
  }
  removeChild(child) {
    const idx = this.children.indexOf(child);
    if (idx !== -1) {
      this.children.splice(idx, 1);
      child.parentElement = null;
    }
    return child;
  }
  querySelector() { return null; }
  querySelectorAll() { return []; }
  getBoundingClientRect() { return { width: this.clientWidth, height: this.clientHeight, top: 0, left: 0 }; }
  addEventListener() {}
  removeEventListener() {}
}

class FakeTerminalForSleep {
  constructor(opts = {}) {
    this.opts = opts;
    this.cols = opts.cols || 80;
    this.rows = opts.rows || 24;
    this.writes = [];
    this.resets = 0;
    this.refreshes = [];
    this.flushedTasks = 0;
    this.renderRowsCalls = 0;
    this.disposed = false;
    this._core = {
      coreService: {
        isCursorHidden: false,
      },
      _renderService: {
        _isPaused: false,
        _needsFullRefresh: false,
        _pausedResizeTask: {
          flush: () => { this.flushedTasks++; },
        },
        _renderRows: (start, end) => {
          this.renderRowsCalls++;
        },
        refreshRows: (start, end) => {
          if (this._core._renderService._isPaused) {
            this._core._renderService._needsFullRefresh = true;
            return;
          }
          this.renderRowsCalls++;
        },
      },
    };
    this.buffer = {
      active: {
        viewportY: 0,
        getLine: () => null,
      },
    };
  }
  open() {}
  onData() { return { dispose() {} }; }
  onBinary() { return { dispose() {} }; }
  onScroll() { return { dispose() {} }; }
  attachCustomKeyEventHandler() { return true; }
  reset() { this.resets++; }
  resize(cols, rows) { this.cols = cols; this.rows = rows; }
  refresh(start, end) {
    this.refreshes.push({ start, end });
    this._core._renderService.refreshRows(start, end);
  }
  write(data, cb) {
    this.writes.push(data);
    // Simulate DECSET 25 showing cursor if requested
    if (typeof data === 'string' && data.includes('\x1b[?25h')) {
      this._core.coreService.isCursorHidden = false;
    }
    // Simulate HIDE_CURSOR setting isCursorHidden to true
    if (data instanceof Uint8Array && data.length === 6 && data[0] === 0x1b && data[1] === 0x5b && data[4] === 0x35 && data[5] === 0x6c) {
      this._core.coreService.isCursorHidden = true;
    }
    // Simulate xterm parser notifying renderService of changed rows
    this._core._renderService.refreshRows(0, 1);
    cb?.();
  }
  focus() {}
  blur() {}
  dispose() { this.disposed = true; }
}

test('MVP M2: Render Sleep state machine pauses GPU submission on sleep and conditionally refreshes on wake', async () => {
  const container = new FakeElement('div');
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminalForSleep,
  });
  view.open();

  const rs = view.term._core._renderService;
  assert.equal(rs._isPaused, false);
  assert.equal(view.isRenderSleeping, false);

  // 1. Initially awake: writes trigger rendering
  view.writeDelta(new TextEncoder().encode('Active line 1\n'));
  await new Promise((r) => setTimeout(r, 40));
  assert.ok(view.term.writes.length >= 1);

  // 2. Put into Render Sleep (pane hidden in background)
  view.setRenderSleep(true);
  assert.equal(view.isRenderSleeping, true);
  assert.equal(rs._isPaused, true, 'RenderService._isPaused must be true while in Render Sleep');

  const rendersBeforeSleepWrites = view.term.renderRowsCalls;
  view.term.refreshes.length = 0;

  // Write while sleeping: writes succeed into buffer, but renderRows is paused
  view.writeDelta(new TextEncoder().encode('Background line 2\n'));
  await new Promise((r) => setTimeout(r, 40));
  assert.equal(view.term.renderRowsCalls, rendersBeforeSleepWrites, 'Render Sleep must block renderRows submissions');
  assert.equal(rs._needsFullRefresh, true, '_needsFullRefresh must be marked true when data arrives while sleeping');

  // 3. Wake up from sleep when dirty: triggers atomic refresh(0, rows - 1)
  view.setRenderSleep(false);
  assert.equal(view.isRenderSleeping, false);
  assert.equal(rs._isPaused, false);
  assert.equal(rs._needsFullRefresh, false);
  assert.equal(view.term.refreshes.length, 1);
  assert.deepEqual(view.term.refreshes[0], { start: 0, end: view.term.rows - 1 });
  assert.ok(view.term.flushedTasks >= 1);

  // 4. Put into Render Sleep again, but this time NO data arrives while sleeping (clean session)
  view.term.refreshes.length = 0;
  view.setRenderSleep(true);
  assert.equal(rs._isPaused, true);
  assert.equal(rs._needsFullRefresh, false);

  // Wake up clean session: zero refresh, zero redraw, zero GPU submit!
  view.setRenderSleep(false);
  assert.equal(view.isRenderSleeping, false);
  assert.equal(rs._isPaused, false);
  assert.equal(view.term.refreshes.length, 0, 'Clean session wake-up must NOT trigger unnecessary redraws');

  view.dispose();
});

test('MVP M2: Zero-copy cursor stream optimization writes raw data and appends static HIDE_CURSOR without full-buffer copy', async () => {
  const container = new FakeElement('div');
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminalForSleep,
    hideCursor: true,
  });
  view.open();
  view.term.writes.length = 0;

  const originalPayload = new Uint8Array([104, 101, 108, 108, 111]); // 'hello'
  view.writeDelta(originalPayload);
  await new Promise((r) => setTimeout(r, 40));

  // The first write must be the exact reference to originalPayload (zero allocation/zero copy!)
  assert.equal(view.term.writes[0], originalPayload, 'Data must be passed by reference without cloning into a new Uint8Array');

  // The second write must be the 6-byte HIDE_CURSOR constant
  const secondWrite = view.term.writes[1];
  assert.ok(secondWrite instanceof Uint8Array);
  assert.equal(secondWrite.length, 6);
  assert.equal(secondWrite[0], 0x1b);
  assert.equal(secondWrite[5], 0x6c);
  assert.equal(view.term._core.coreService.isCursorHidden, true, 'Cursor must remain hidden');

  // Test backward-compatibility helper withHiddenCursor
  const legacyCopied = withHiddenCursor(originalPayload);
  assert.equal(legacyCopied.length, originalPayload.length + 6);

  view.dispose();
});

test('MVP M2: _syncCursorAnchor skips expensive DOM line inspection while in Render Sleep', () => {
  const container = new FakeElement('div');
  let lineInspections = 0;
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminalForSleep,
    hideCursor: true,
  });
  view.open();
  view.term.buffer.active.getLine = () => {
    lineInspections++;
    return { translateToString: () => 'Add a follow-up' };
  };

  // When awake: _syncCursorAnchor inspects lines
  view._syncCursorAnchor();
  assert.ok(lineInspections >= 1, '_syncCursorAnchor should inspect lines when awake');

  // When sleeping: _syncCursorAnchor immediately returns without inspecting lines
  lineInspections = 0;
  view.setRenderSleep(true);
  view._syncCursorAnchor();
  assert.equal(lineInspections, 0, '_syncCursorAnchor must return immediately while in Render Sleep');

  view.dispose();
});

test('MVP M2: _flushWrites releases queued buffer references by nulling slots immediately', async () => {
  const container = new FakeElement('div');
  const view = new TerminalView(container, {
    TerminalCtor: FakeTerminalForSleep,
  });
  view.open();

  const chunk1 = new Uint8Array([1, 2, 3]);
  const snap = new Uint8Array([4, 5, 6]);

  // Queue a delta followed by a snapshot: flushing delta advances head to 1, leaving slot 0 as null before queue completes
  view._writeQueue.push({ kind: 'delta', data: chunk1 });
  view._writeQueue.push({ kind: 'snapshot', data: snap });
  view._queuedWriteBytes = 6;

  view._flushWrites();

  // Slot 0 must be nulled after consumption
  assert.equal(view._writeQueue[0], null, 'Queue slot 0 must be nulled after consumption');
  assert.equal(view._writeHead, 1);

  view.dispose();
});

test('MVP M2: UI-SPEC.md §6.2 documents Phase M2 Render Sleep and write-stream zero-copy ruling', async () => {
  const spec = await readFile(new URL('../docs/UI-SPEC.md', import.meta.url), 'utf8');

  assert.match(spec, /2026-09-26（后台窗格渲染休眠与写流零拷贝，MVP Phase M2）/);
  assert.match(spec, /WebGL Canvas 永久常驻 DOM 原几何位置/);
  assert.match(spec, /数据流常驻正常解析写入/);
  assert.match(spec, /_renderService\._isPaused = true/);
  assert.match(spec, /_needsFullRefresh/);
  assert.match(spec, /消除 `withHiddenCursor` 逐帧数组重新分配与内存拷贝/);
});

test('MVP M2: TerminalPane & TerminalView source contract verifies Render Sleep integration without detach/disconnect', async () => {
  const [viewJs, paneJsx] = await Promise.all([
    readFile(new URL('../src/term/TerminalView.js', import.meta.url), 'utf8'),
    readFile(new URL('../src/components/terminal/TerminalPane.jsx', import.meta.url), 'utf8'),
  ]);

  // TerminalView has setRenderSleep
  assert.match(viewJs, /setRenderSleep\(sleeping\)\s*\{/);
  assert.match(viewJs, /renderService\._isPaused = true;/);
  assert.match(viewJs, /renderService\._needsFullRefresh/);
  assert.match(viewJs, /if\s*\(!this\.hideCursor\s*\|\|\s*this\._disposed\s*\|\|\s*this\._renderSleeping\)\s*return;/);

  // TerminalPane hooks isVisible and pane-host to pauseRendering/resumeRendering
  assert.match(paneJsx, /renderSleep:\s*!isPaneVisible/);
  assert.match(paneJsx, /v\.pauseRendering\(\)/);
  assert.match(paneJsx, /v\.resumeRendering\(\)/);
  assert.match(paneJsx, /const deltaW = Math\.abs\(curW - lastWidthRef\.current\);/);
  assert.match(paneJsx, /const deltaH = Math\.abs\(curH - lastHeightRef\.current\);/);
  assert.match(paneJsx, /if\s*\(deltaW < 2 && deltaH < 2\)\s*return;/);

  // Invariants strictly held: NO detachWebgl, NO visibility_resume, NO background unsubscribe/dropping
  assert.doesNotMatch(viewJs, /detachWebgl/);
  assert.doesNotMatch(paneJsx, /visibility_resume/);
  assert.doesNotMatch(paneJsx, /useLayoutEffect\(\(\)\s*=>\s*\{[^}]*unsubscribe/);
  assert.doesNotMatch(paneJsx, /new MutationObserver\(\(\)\s*=>\s*\{[^}]*unsubscribe/);
  assert.doesNotMatch(paneJsx, /if\s*\(!viewRef\.current\?\.isVisible\)\s*return;/);
});

test('MVP M2: ResizeObserver physical threshold guard suppresses fit and subscribe on tab switch (fit=0, subscribe=0, reset=0)', async () => {
  const [paneJsx, terminalViewJs] = await Promise.all([
    readFile(new URL('../src/components/terminal/TerminalPane.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/term/TerminalView.js', import.meta.url), 'utf8'),
  ]);

  // TerminalPane records lastWidthRef and lastHeightRef
  assert.match(paneJsx, /const lastWidthRef = useRef\(0\);/);
  assert.match(paneJsx, /const lastHeightRef = useRef\(0\);/);

  // Both ro and handleLayoutSettled bail out if deltaW < 2 && deltaH < 2
  const matches = paneJsx.match(/if\s*\(deltaW < 2 && deltaH < 2\)\s*return;/g);
  assert.ok(matches && matches.length >= 2, 'Both ResizeObserver and handleLayoutSettled must check deltaW < 2 && deltaH < 2');

  // TerminalView.isFitCurrent tolerates 1px subpixel jitter when derived cols/rows are identical
  assert.match(terminalViewJs, /Math\.abs\(this\.lastFit\.container_width_px - w\) <= 1/);
  assert.match(terminalViewJs, /Math\.abs\(this\.lastFit\.container_height_px - h\) <= 1/);
});

test('MVP M2: TerminalPane props destructuring safely declares isVisible = true and avoids ReferenceError', async () => {
  const [paneJsx, appJsx] = await Promise.all([
    readFile(new URL('../src/components/terminal/TerminalPane.jsx', import.meta.url), 'utf8'),
    readFile(new URL('../src/App.jsx', import.meta.url), 'utf8'),
  ]);

  // TerminalPane must safely destructure isVisible = true
  assert.match(paneJsx, /export default function TerminalPane\(\{[\s\S]*?isVisible = true,[\s\S]*?\}\)/);

  // App safely forwards isVisible if present or defaults to true
  assert.match(appJsx, /isVisible=\{dimensions\?\.isVisible !== undefined \? dimensions\.isVisible : true\}/);
});

