/*
 * AgentMirror 桌面端 —— xterm 底座（CLIENT-CONTRACT §1.3 的重写版）。
 *
 * 保留 web 版 TerminalView 的全部语义，只换实现底座：
 *   - snapshot → reset() + write()（清屏重建；游标锚 ESC[row;colH 在字节尾，必须整段原样喂）
 *   - delta    → write()（追加）
 *   - 首次几何 → 立即回调；后续 resize → 120ms debounce 合并（服务端每次真 reflow 都补一帧 snapshot，不合并会闪）
 *   - 滚到顶   → onHistoryBoundary()，由调用方去拉协议 scrollback
 *
 * ⛔ 不引 @xterm/addon-fit：仓库装的是 @xterm/xterm@6.0.0，addon-fit@0.11 面向 xterm5 的私有
 * _renderService 结构，0.12-beta 又要求 xterm ^6.1.0-beta。fit() 改为直接量 .xterm-screen 的
 * 实际渲染几何（公开 DOM，自校正），比探针量单字符宽度更准。
 */

// 直指 ESM 产物（= 包里 module 字段指的那个文件；该包没有 exports 映射，深路径合法）。
// 走裸 '@xterm/xterm' 的话，打包器拿 .mjs（具名导出）、Node 拿 .js（CJS，具名导入直接
// SyntaxError），`node --test` 就加载不了本模块 —— 两边指同一个文件才不用写互操作补丁。
import { Terminal } from '@xterm/xterm/lib/xterm.mjs';

import { attachWebglRenderer } from './webglRenderer.js';
import { resolveTerminalTheme, DARK_TERMINAL_THEME, LIGHT_TERMINAL_THEME } from './theme.js';
import { isCtrlV, isCtrlShiftV, isCtrlShiftC, isCmdV } from './clipboard.js';
import { nativeCapabilities } from '../core/nativeCapabilities.js';
import { getFontMetrics } from './fontMetrics.js';

/** 滚轮触顶到再次触发拉历史之间的最小间隔（ms），避免一次手势打出几十个请求。 */
const WHEEL_THROTTLE_MS = 400;
/** 本地 grid 与上报共用：列宽抖动未落定前 ⛔ 不 term.resize 旧快照。 */
export const GRID_DEBOUNCE_MS = 120;
/** Delta backlog budget; overflow requests a fresh snapshot instead of dropping silently. */
export const MAX_PENDING_WRITE_BYTES = 4 * 1024 * 1024;
const HIDE_CURSOR = new Uint8Array([0x1b, 0x5b, 0x3f, 0x32, 0x35, 0x6c]); // ESC[?25l
const FOLLOW_UP_RE = /^(?:\s*)(?:→|->)\s*Add a follow-up\b/;
const FOLLOW_UP_PREFIX_RE = /^(?:\s*)(?:→|->)\s*/;

function withHiddenCursor(bytes) {
  const hidden = new Uint8Array(bytes.byteLength + HIDE_CURSOR.byteLength);
  hidden.set(bytes);
  hidden.set(HIDE_CURSOR, bytes.byteLength);
  return hidden;
}

function withImplicitCr(bytes) {
  let lfCount = 0;
  for (const byte of bytes) if (byte === 0x0a) lfCount += 1;
  if (lfCount === 0) return bytes;

  const normalized = new Uint8Array(bytes.length + lfCount);
  let out = 0;
  for (const byte of bytes) {
    if (byte === 0x0a) normalized[out++] = 0x0d;
    normalized[out++] = byte;
  }
  return normalized;
}

export class TerminalView {
  /**
   * @param {HTMLElement} container 已有确定尺寸的挂载容器
   * @param {Object}   [opts]
   * @param {(rows:number, cols:number) => void} [opts.onResize]         几何变了（已 debounce）
   * @param {() => void}                         [opts.onHistoryBoundary] 视口滚到顶 / 顶部继续上滚
   * @param {(data:string) => void}               [opts.onData]            xterm 编好的按键字节
   * @param {(data:string) => void}               [opts.onBinary]          xterm 原始二进制事件（X10 鼠标）

   * @param {number}   [opts.scrollback=0]  本地回滚行数。默认 0：历史唯一事实来源是协议
   *                                        scrollback 帧（UI-SPEC §6.2）
   * @param {number}   [opts.fontSize=13]
   * @param {(info:{queuedBytes:number,maxPendingBytes:number}) => void} [opts.onWriteBackpressure]
   * @param {number}   [opts.maxPendingWriteBytes] 仅供单测缩小积压预算
   * @param {Function} [opts.TerminalCtor]  仅供单测注入 FakeTerminal；生产走 @xterm/xterm
   * @param {boolean} [opts.hideCursor=false] 隐藏远端停靠的硬件游标（Cursor TUI）
   */
  constructor(container, opts = {}) {
    const {
      onResize, onHistoryBoundary, onData, onBinary, onWriteBackpressure,
      onPaste, onCtrlV, onForceTextPaste,
      scrollback = 0, fontSize = 13, fontFamily = 'ui-monospace, SF Mono, Menlo, monospace',
      maxPendingWriteBytes = MAX_PENDING_WRITE_BYTES,
      hideCursor = false, TerminalCtor = Terminal,
    } = opts;
    this.container = container;
    this.onResize = onResize || (() => {});
    this.onHistoryBoundary = onHistoryBoundary || (() => {});
    this.onData = onData || (() => {});
    this.onBinary = onBinary || (() => {});
    this.onWriteBackpressure = onWriteBackpressure || (() => {});
    this.onPaste = onPaste || (() => {});
    this.onCtrlV = onCtrlV || (() => {});
    this.onForceTextPaste = onForceTextPaste || (() => {});
    this.maxPendingWriteBytes = Number.isInteger(maxPendingWriteBytes) && maxPendingWriteBytes > 0
      ? maxPendingWriteBytes : MAX_PENDING_WRITE_BYTES;

    this.fontSize = fontSize;
    this.fontFamily = fontFamily;
    // Windows uses the DOM renderer: extra leading separates box-drawing rows.
    this.lineHeight = nativeCapabilities.platform === 'windows' ? 1 : 1.25;
    this.hideCursor = hideCursor === true;
    this._customTheme = Boolean(opts.theme);
    const initialCols = opts.initialCols || (opts.cols ?? null);
    const initialRows = opts.initialRows || (opts.rows ?? null);
    this.initialCols = initialCols;
    this.initialRows = initialRows;
    this._cellMetrics = opts.cellMetrics || null;

    const theme = resolveTerminalTheme(opts);
    this.term = new TerminalCtor({
      cols: initialCols || 80,
      rows: initialRows || 24,
      scrollback,
      fontSize,
      fontFamily,
      lineHeight: this.lineHeight,
      customGlyphs: true,
      cursorBlink: !this.hideCursor,
      cursorStyle: 'block',
      cursorInactiveStyle: this.hideCursor ? 'none' : 'outline',
      convertEol: false,
      // 输入走 onData → 协议。远程 delta 负责回显，xterm 不本地 echo。
      disableStdin: false,
      allowProposedApi: true,
      theme,
    });
    this._lastDims = null;
    this._lastScrollLine = null;
    this._resizeTimer = null;
    this._gridTimer = null;
    this._hasFit = false;
    this._pendingCols = null;
    this._pendingRows = null;
    this._lastWheelAt = 0;
    this._disposed = false;
    this._hasPainted = false;
    this._fixedGrid = null;
    this._writeQueue = [];
    this._writeHead = 0;
    this._queuedWriteBytes = 0;
    this._writeInFlight = false;
    this._writeScheduled = false;
    this._writeScheduleKind = null;
    this._writeHandle = null;
    this._recovering = false;
    this._cursorAnchor = null;
    this._anchorObservers = null;
    this._pasteListener = null;

    // 应用终端快捷键统一由 term.attachCustomKeyEventHandler 守护（裁决 §5.1）
    if (typeof this.term.attachCustomKeyEventHandler === 'function') {
      const isWindows = nativeCapabilities.platform === 'windows';
      this.term.attachCustomKeyEventHandler((event) => {
        // Composition 期间放行，避免一次手势在 keydown/keypress/keyup 重复执行
        if (event.isComposing || event.keyCode === 229) return true;
        if (event.type !== 'keydown') return true;

        // 1. Windows Ctrl+Shift+C: 复制当前终端选中文字，不发 PTY
        if (isWindows && isCtrlShiftC(event)) {
          if (typeof this.term.hasSelection === 'function' && this.term.hasSelection()) {
            const selection = this.term.getSelection();
            if (selection && typeof navigator !== 'undefined' && navigator.clipboard?.writeText) {
              navigator.clipboard.writeText(selection).catch(() => {});
            }
          }
          return false;
        }

        // 2. Windows Ctrl+Shift+V: 强制纯文本粘贴
        if (isWindows && isCtrlShiftV(event)) {
          this.onForceTextPaste();
          return false;
        }

        // 3. macOS Ctrl+V: 图片专用快捷键
        if (!isWindows && isCtrlV(event)) {
          this.onCtrlV();
          return false;
        }

        // 4. Windows Ctrl+V / macOS Cmd+V: 放行系统原生生成 paste 事件到 textarea，不被 xterm 编码为 0x16
        if ((isWindows && isCtrlV(event)) || (!isWindows && isCmdV(event))) {
          return false;
        }

        return true;
      });
    }
  }

  /** 挂载进容器并做一次 fit。 */
  open() {
    this.term.open(this.container);
    if (this.hideCursor) {
      this.term.write(HIDE_CURSOR);
      this._cursorMoveDisposable = this.term.onCursorMove?.(() => this._syncCursorAnchor());
      this._renderDisposable = this.term.onRender?.(() => this._syncCursorAnchor());
    }
    this._dataDisposable = this.term.onData((data) => this.onData(data));
    // xterm emits X10 mouse reports through onBinary; each code unit is one raw byte.
    this._binaryDisposable = this.term.onBinary
      ? this.term.onBinary((data) => this.onBinary(data))
      : null;
    this._scrollDisposable = this.term.onScroll((line) => {
      if (line <= 0 && this._lastScrollLine > 0) this.onHistoryBoundary();
      this._lastScrollLine = line;
    });
    // scrollback=0 时视口永远不可滚，onScroll 不会触发；上滚手势是唯一的「要更早历史」信号。
    this._onWheel = (ev) => {
      if (ev.deltaY >= 0) return;
      const buf = this.term.buffer && this.term.buffer.active;
      if (buf && buf.viewportY > 0) return; // 还能本地往上滚，先滚本地
      const now = Date.now();
      if (now - this._lastWheelAt < WHEEL_THROTTLE_MS) return;
      this._lastWheelAt = now;
      this.onHistoryBoundary();
    };
    this.container.addEventListener('wheel', this._onWheel, { passive: true });
    if (typeof window !== 'undefined' && window.matchMedia && !this._customTheme) {
      this._themeMql = window.matchMedia('(prefers-color-scheme: dark)');
      this._themeListener = (e) => this.setDark(e.matches);
      this._themeMql.addEventListener?.('change', this._themeListener);
    }
    // 单一 textarea 唯一 paste 接缝（裁决 §5.2）
    const textarea = this.term.textarea;
    if (textarea?.addEventListener) {
      this._pasteListener = (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        this.onPaste(ev);
      };
      textarea.addEventListener('paste', this._pasteListener, true);
    }
    if (this.initialCols && this.initialRows && !this._hasFit) {
      this._hasFit = true;
      const cell = this._cell();
      this.lastFit = {
        container_width_px: this.container.clientWidth || 0,
        container_height_px: this.container.clientHeight || 0,
        cell_width_px: cell.w,
        derived_cols: this.initialCols,
        derived_rows: this.initialRows,
      };
      this._commitGrid(this.initialCols, this.initialRows, { reportDelay: false });
    } else {
      this.fit();
    }
    if (this.hideCursor) {
      this._syncCursorAnchor();
      const textarea = this.term.textarea;
      if (textarea?.addEventListener) {
        const sync = () => this._syncCursorAnchor();
        this._compositionListeners = ['compositionstart', 'compositionupdate', 'input', 'compositionend'].map((type) => {
          textarea.addEventListener(type, sync);
          return { type, sync };
        });
      }
      this._observeCursorAnchor();
    }
    // WebGL 接上之后再给调用方开订阅，避免首帧 snapshot 写在 DOM 上、addon 一切换就空屏。
    this.readyWebgl = attachWebglRenderer(this.term).then((addon) => {
      this._webglAddon = addon;
      // addon 换渲染器后必须再 fit 一次：探针 T1 70x29 → T3 73x23。
      if (addon) this.fit({ immediate: true });
    });
  }

  /**
   * 按容器像素重算 rows/cols。首帧立刻落到格子并上报订阅；之后 120ms 内的抖动只记目标，
   * 落定后再 term.resize + 上报。否则频繁切列会把旧 snapshot 按过渡宽度本地 reflow，
   * 回到原几何时 daemon resize 还是 no-op（不补快照），错乱就钉死。
   */
  fit({ immediate = false, sync = false } = {}) {
    const el = this.container;
    if (this._disposed || !el || !el.isConnected) return;
    const w = el.clientWidth;
    const h = el.clientHeight;
    if (w === 0 || h === 0) return;
    const cell = this._cell();
    const derivedCols = Math.max(2, Math.floor(w / cell.w));
    const derivedRows = Math.max(2, Math.floor(h / cell.h));
    this.lastFit = {
      container_width_px: w,
      container_height_px: h,
      cell_width_px: cell.w,
      derived_cols: derivedCols,
      derived_rows: derivedRows,
    };
    const cols = this._fixedGrid ? this._fixedGrid.cols : derivedCols;
    const rows = this._fixedGrid ? this._fixedGrid.rows : derivedRows;
    this._pendingCols = cols;
    this._pendingRows = rows;
    if (!this._hasFit || immediate) {
      const initialFit = !this._hasFit;
      this._hasFit = true;
      if (sync) {
        clearTimeout(this._gridTimer);
        clearTimeout(this._resizeTimer);
        this._gridTimer = null;
        this._resizeTimer = null;
      }
      // The first settled grid is the subscription handshake; do not make it
      // wait for the resize debounce. `immediate` is reserved for renderer
      // changes and keeps the normal post-initial debounce semantics, unless sync is requested.
      const reportDelay = sync ? false : !initialFit;
      this._commitGrid(cols, rows, { reportDelay });
      return;
    }
    if (cols === this.term.cols && rows === this.term.rows) {
      clearTimeout(this._gridTimer);
      this._gridTimer = null;
      return;
    }
    clearTimeout(this._gridTimer);
    clearTimeout(this._resizeTimer);
    this._gridTimer = setTimeout(() => {
      this._gridTimer = null;
      if (this._disposed) return;
      this._commitGrid(this._pendingCols, this._pendingRows, { reportDelay: false });
    }, GRID_DEBOUNCE_MS);
  }

  setFixedGrid(grid, { sync = true } = {}) {
    if (grid && Number.isInteger(grid.cols) && Number.isInteger(grid.rows)) {
      this._fixedGrid = { cols: grid.cols, rows: grid.rows };
      if (sync) {
        clearTimeout(this._gridTimer);
        clearTimeout(this._resizeTimer);
        this._gridTimer = null;
        this._resizeTimer = null;
      }
      this._commitGrid(grid.cols, grid.rows, { reportDelay: !sync });
    } else {
      this._fixedGrid = null;
    }
  }

  clearFixedGrid() {
    this._fixedGrid = null;
  }

  _commitGrid(cols, rows, { reportDelay = true } = {}) {
    if (cols !== this.term.cols || rows !== this.term.rows) {
      // C: 有旧快照时先 reset 再 resize，避免把捕获宽度 A 的格子 wrap 进宽度 B。
      if (this._hasPainted) {
        this.term.reset();
        this._hasPainted = false;
      }
      this.term.resize(cols, rows);
      if (reportDelay) this._report();
      else {
        this._lastDims = `${rows}x${cols}`;
        this.onResize(rows, cols);
      }
    } else if (this._lastDims == null) {
      if (reportDelay) this._report();
      else {
        this._lastDims = `${rows}x${cols}`;
        this.onResize(rows, cols);
      }
    }
  }

  _cancelWriteSchedule() {
    if (!this._writeScheduled) return;
    if (this._writeScheduleKind === 'raf' && typeof cancelAnimationFrame === 'function') {
      cancelAnimationFrame(this._writeHandle);
    }
    this._writeScheduled = false;
    this._writeScheduleKind = null;
    this._writeHandle = null;
  }

  _scheduleWrite() {
    if (this._disposed || this._recovering || this._writeScheduled || this._writeInFlight
        || this._writeHead === this._writeQueue.length) return;
    this._writeScheduled = true;
    const run = () => {
      if (!this._writeScheduled) return;
      this._writeScheduled = false;
      this._writeScheduleKind = null;
      this._writeHandle = null;
      this._flushWrites();
    };
    if (typeof requestAnimationFrame === 'function') {
      this._writeScheduleKind = 'raf';
      this._writeHandle = requestAnimationFrame(run);
    } else if (typeof queueMicrotask === 'function') {
      this._writeScheduleKind = 'microtask';
      queueMicrotask(run);
    } else {
      this._writeScheduleKind = 'microtask';
      Promise.resolve().then(run);
    }
  }

  _triggerWriteRecovery() {
    if (this._recovering) return;
    const queuedBytes = this._queuedWriteBytes;
    this._cancelWriteSchedule();
    this._writeQueue.length = 0;
    this._writeHead = 0;
    this._queuedWriteBytes = 0;
    this._recovering = true;
    this.onWriteBackpressure({ queuedBytes, maxPendingBytes: this.maxPendingWriteBytes });
  }

  _write(kind, data) {
    this._writeInFlight = true;
    let finished = false;
    const done = () => {
      if (finished) return;
      finished = true;
      this._writeInFlight = false;
      if (!this._disposed && !this._recovering) this._scheduleWrite();
    };
    try {
      if (kind === 'snapshot') {
        this.term.reset();
        this._hasPainted = true;
      }
      this.term.write(this.hideCursor ? withHiddenCursor(data) : data, done);
    } catch (error) {
      done();
      throw error;
    }
  }

  _flushWrites() {
    if (this._disposed || this._recovering || this._writeInFlight) return;
    const first = this._writeQueue[this._writeHead];
    if (!first) return;

    let data;
    const kind = first.kind;
    if (kind === 'snapshot') {
      this._writeHead += 1;
      this._queuedWriteBytes -= first.data.byteLength;
      data = first.data;
    } else {
      const chunks = [];
      let total = 0;
      while (this._writeQueue[this._writeHead]?.kind === 'delta') {
        const item = this._writeQueue[this._writeHead];
        this._writeHead += 1;
        chunks.push(item.data);
        total += item.data.byteLength;
        this._queuedWriteBytes -= item.data.byteLength;
      }
      if (chunks.length === 1) data = chunks[0];
      else {
        data = new Uint8Array(total);
        let offset = 0;
        for (const chunk of chunks) {
          data.set(chunk, offset);
          offset += chunk.byteLength;
        }
      }
    }
    if (this._writeHead === this._writeQueue.length) {
      this._writeQueue.length = 0;
      this._writeHead = 0;
    }
    this._write(kind, data);
  }

  /** Keep Cursor's IME composition view on its software follow-up prompt. */
  _syncCursorAnchor() {
    if (!this.hideCursor || this._disposed) return;
    const buffer = this.term.buffer?.active;
    const getLine = buffer?.getLine?.bind(buffer);
    if (!getLine) return;
    let anchor = null;
    const ydisp = Number.isInteger(buffer.ydisp) ? buffer.ydisp : 0;
    for (let row = 0; row < this.term.rows; row += 1) {
      const line = getLine(ydisp + row);
      const text = line?.translateToString?.(false) || '';
      const match = FOLLOW_UP_RE.exec(text);
      if (match) {
        const charIndex = match.index + match[0].indexOf('Add a follow-up');
        anchor = { row, col: this._lineColumn(line, charIndex) };
        break;
      }
    }
    // Once the placeholder has been replaced with user text, retain its row and
    // move the IME anchor to the end of that same follow-up line.
    if (!anchor && this._cursorAnchor) {
      const row = this._cursorAnchor.row;
      const line = getLine(ydisp + row);
      const text = line?.translateToString?.(false) || '';
      if (FOLLOW_UP_PREFIX_RE.test(text)) {
        anchor = { row, col: this._lineColumn(line, text.length) };
      }
    }
    if (!anchor) return;
    this._cursorAnchor = anchor;
    const cell = this._cell();
    const left = anchor.col * cell.w;
    const top = anchor.row * cell.h;
    const textarea = this.term.textarea;
    if (textarea?.style) {
      textarea.style.left = `${left}px`;
      textarea.style.top = `${top}px`;
      textarea.style.width = `${cell.w}px`;
      textarea.style.height = `${cell.h}px`;
      textarea.style.lineHeight = `${cell.h}px`;
      textarea.style.zIndex = '-5';
    }
    const composition = this.term.element?.querySelector?.('.composition-view');
    if (composition?.style) {
      composition.style.left = `${left}px`;
      composition.style.top = `${top}px`;
      composition.style.height = `${cell.h}px`;
      composition.style.lineHeight = `${cell.h}px`;
    }
  }

  /** Reapply the anchor after xterm's internal composition/style mutation. */
  _observeCursorAnchor() {
    const Observer = globalThis.MutationObserver;
    if (typeof Observer !== 'function') return;
    const elements = [
      this.term.textarea,
      this.term.element?.querySelector?.('.composition-view'),
    ].filter(Boolean);
    this._anchorObservers = elements.map((element) => {
      const observer = new Observer(() => this._syncCursorAnchor());
      observer.observe(element, { attributes: true, attributeFilter: ['style'] });
      return observer;
    });
  }

  /** Convert a string offset to xterm cell columns so CJK input remains aligned. */
  _lineColumn(line, charIndex) {
    if (!line?.getCell) return charIndex;
    let col = 0;
    let index = 0;
    while (index < charIndex && col < this.term.cols) {
      const cell = line.getCell(col);
      if (!cell) break;
      const chars = cell.getChars?.() || '';
      index += chars.length || 1;
      col += Math.max(1, cell.getWidth?.() || 1);
    }
    return Math.min(this.term.cols, col);
  }

  /** 全屏快照：清屏重建；只为裸 LF 补隐含 CR，同步原子写入，⛔ 不 trim、不按行拆。 */
  writeSnapshot(u8) {
    const data = withImplicitCr(u8);
    this._recovering = false;
    this._cancelWriteSchedule();
    this._writeQueue.length = 0;
    this._writeHead = 0;
    this._queuedWriteBytes = 0;
    this._writeInFlight = false;
    this._write('snapshot', data);
  }

  /** 增量：在浏览器帧内合并并以 xterm write callback 单飞。 */
  writeDelta(u8) {
    if (this._disposed || this._recovering) return false;
    const data = u8 instanceof Uint8Array ? u8 : new Uint8Array(u8 || []);
    if (data.byteLength === 0) return true;
    if (this._queuedWriteBytes + data.byteLength > this.maxPendingWriteBytes) {
      this._triggerWriteRecovery();
      return false;
    }
    this._writeQueue.push({ kind: 'delta', data });
    this._queuedWriteBytes += data.byteLength;
    this._scheduleWrite();
    return true;
  }

  clear() {
    this._cancelWriteSchedule();
    this._writeQueue.length = 0;
    this._writeHead = 0;
    this._queuedWriteBytes = 0;
    this._recovering = false;
    this.term.reset();
    if (this.hideCursor) this.term.write(HIDE_CURSOR);
  }

  focus() { try { this.term.focus(); } catch { /* 已 dispose */ } }

  blur() { try { this.term.blur(); } catch { /* 已 dispose */ } }

  scrollToBottom() { this.term.scrollToBottom(); }

  setTheme(theme) {
    if (this.term && this.term.options) {
      this.term.options.theme = theme;
    }
  }

  setDark(isDark) {
    this.setTheme(isDark ? DARK_TERMINAL_THEME : LIGHT_TERMINAL_THEME);
  }

  /**
   * 动态更新终端字体与字号，并即时重新 fit 计算行列（Issue #193）。
   * @param {Object} [opts]
   * @param {string} [opts.fontFamily]
   * @param {number} [opts.fontSize]
   */
  updateFont({ fontFamily, fontSize } = {}) {
    if (this._disposed || !this.term?.options) return;
    let changed = false;
    if (typeof fontFamily === 'string' && fontFamily.trim()) {
      const trimmed = fontFamily.trim();
      if (this.term.options.fontFamily !== trimmed) {
        this.fontFamily = trimmed;
        this.term.options.fontFamily = trimmed;
        changed = true;
      }
    }
    if (fontSize !== undefined && fontSize !== null) {
      const clamped = Math.min(24, Math.max(10, Number(fontSize) || 13));
      if (this.fontSize !== clamped || this.term.options.fontSize !== clamped) {
        this.fontSize = clamped;
        this.term.options.fontSize = clamped;
        changed = true;
      }
    }
    if (changed) {
      this._cellMetrics = null;
      this.fit({ immediate: true, sync: true });
    }
  }

  dispose() {
    this._disposed = true;
    this._cancelWriteSchedule();
    this._writeQueue.length = 0;
    this._writeHead = 0;
    this._queuedWriteBytes = 0;
    clearTimeout(this._resizeTimer);
    clearTimeout(this._gridTimer);
    try { this._webglAddon?.dispose(); } catch { /* already gone */ }
    this._webglAddon = null;
    if (this._themeMql && this._themeListener) {
      this._themeMql.removeEventListener?.('change', this._themeListener);
      this._themeMql = null;
      this._themeListener = null;
    }
    if (this._onWheel && this.container) this.container.removeEventListener('wheel', this._onWheel);
    if (this._dataDisposable) this._dataDisposable.dispose();
    if (this._binaryDisposable) this._binaryDisposable.dispose();
    if (this._scrollDisposable) this._scrollDisposable.dispose();
    if (this._cursorMoveDisposable) this._cursorMoveDisposable.dispose();
    if (this._renderDisposable) this._renderDisposable.dispose();
    if (this._pasteListener && this.term.textarea?.removeEventListener) {
      this.term.textarea.removeEventListener('paste', this._pasteListener, true);
      this._pasteListener = null;
    }
    const textarea = this.term.textarea;
    for (const listener of this._compositionListeners || []) {
      textarea?.removeEventListener?.(listener.type, listener.sync);
    }
    this._compositionListeners = null;
    for (const observer of this._anchorObservers || []) observer.disconnect();
    this._anchorObservers = null;
    try { this.term.dispose(); } catch { /* 已 dispose */ }
  }

  get rows() { return this.term.rows; }
  get cols() { return this.term.cols; }

  _report() {
    const dims = `${this.term.rows}x${this.term.cols}`;
    if (dims === this._lastDims) return;
    this._lastDims = dims;
    clearTimeout(this._resizeTimer);
    // 服务端对每次真 reflow 都补一帧 snapshot；拖窗口时不合并会闪烁重画。
    this._resizeTimer = setTimeout(() => {
      if (!this._disposed) this.onResize(this.term.rows, this.term.cols);
    }, 120);
  }

  /** 单元格实际渲染尺寸；优先直读常驻字体度量缓存（O(1) 纯数学除法，彻底消除 Layout Thrashing）。 */
  _cell() {
    if (this._cellMetrics) return this._cellMetrics;
    const metrics = getFontMetrics({
      fontFamily: this.term.options?.fontFamily || this.fontFamily,
      fontSize: this.fontSize,
      lineHeight: this.lineHeight,
    });
    // 兼容 FakeTerminal 测试替身注入的 screen 元素模拟
    const screen = this.term.element && this.term.element.querySelector?.('.xterm-screen');
    if (screen) {
      const r = screen.getBoundingClientRect?.();
      if (r && r.width > 0 && r.height > 0) {
        const m = { w: r.width / this.term.cols, h: r.height / this.term.rows };
        this._cellMetrics = m;
        return m;
      }
    }
    const m = { w: metrics.cellWidth, h: metrics.cellHeight };
    this._cellMetrics = m;
    return m;
  }
}
