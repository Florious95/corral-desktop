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
  constructor(container, {
    onResize, onHistoryBoundary, onData, onBinary, onWriteBackpressure,
    scrollback = 0, fontSize = 13, maxPendingWriteBytes = MAX_PENDING_WRITE_BYTES,
    hideCursor = false, TerminalCtor = Terminal,
  } = {}) {
    this.container = container;
    this.onResize = onResize || (() => {});
    this.onHistoryBoundary = onHistoryBoundary || (() => {});
    this.onData = onData || (() => {});
    this.onBinary = onBinary || (() => {});
    this.onWriteBackpressure = onWriteBackpressure || (() => {});
    this.maxPendingWriteBytes = Number.isInteger(maxPendingWriteBytes) && maxPendingWriteBytes > 0
      ? maxPendingWriteBytes : MAX_PENDING_WRITE_BYTES;

    this.fontSize = fontSize;
    this.hideCursor = hideCursor === true;
    this.term = new TerminalCtor({
      scrollback,
      fontSize,
      fontFamily: 'ui-monospace, SF Mono, Menlo, monospace',
      lineHeight: 1.25,
      customGlyphs: true,
      cursorBlink: !this.hideCursor,
      cursorStyle: 'block',
      cursorInactiveStyle: this.hideCursor ? 'none' : 'outline',
      convertEol: false,
      // 输入走 onData → 协议。远程 delta 负责回显，xterm 不本地 echo。
      disableStdin: false,
      allowProposedApi: true,
      theme: {
        background: '#fbfaf8',
        foreground: '#3a3835',
        cursor: '#3a3835',
        selectionBackground: 'rgba(0,0,0,.12)',
      },
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
    this._writeQueue = [];
    this._writeHead = 0;
    this._queuedWriteBytes = 0;
    this._writeInFlight = false;
    this._writeScheduled = false;
    this._writeScheduleKind = null;
    this._writeHandle = null;
    this._recovering = false;
    this._cursorAnchor = null;
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
    this.fit();
    if (this.hideCursor) {
      this._syncCursorAnchor();
      const textarea = this.term.textarea;
      if (textarea?.addEventListener) {
        const sync = () => this._syncCursorAnchor();
        this._compositionListeners = ['compositionstart', 'compositionupdate'].map((type) => {
          textarea.addEventListener(type, sync);
          return { type, sync };
        });
      }
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
  fit({ immediate = false } = {}) {
    const el = this.container;
    if (this._disposed || !el || !el.isConnected) return;
    const w = el.clientWidth;
    const h = el.clientHeight;
    if (w === 0 || h === 0) return;
    const cell = this._cell();
    const cols = Math.max(2, Math.floor(w / cell.w));
    const rows = Math.max(2, Math.floor(h / cell.h));
    this.lastFit = {
      container_width_px: w,
      container_height_px: h,
      cell_width_px: cell.w,
      derived_cols: cols,
      derived_rows: rows,
    };
    this._pendingCols = cols;
    this._pendingRows = rows;
    if (!this._hasFit || immediate) {
      const initialFit = !this._hasFit;
      this._hasFit = true;
      // The first settled grid is the subscription handshake; do not make it
      // wait for the resize debounce. `immediate` is reserved for renderer
      // changes and keeps the normal post-initial debounce semantics.
      this._commitGrid(cols, rows, { reportDelay: !initialFit });
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

  /** 全屏快照：清屏重建；只为裸 LF 补隐含 CR，⛔ 不 trim、不按行拆。 */
  writeSnapshot(u8) {
    const data = withImplicitCr(u8);
    this._recovering = false;
    this._cancelWriteSchedule();
    this._writeQueue.length = 0;
    this._writeHead = 0;
    this._queuedWriteBytes = 0;
    if (this._writeInFlight) {
      this._writeQueue.push({ kind: 'snapshot', data });
      this._queuedWriteBytes = data.byteLength;
      return;
    }
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
    if (this._onWheel && this.container) this.container.removeEventListener('wheel', this._onWheel);
    if (this._dataDisposable) this._dataDisposable.dispose();
    if (this._binaryDisposable) this._binaryDisposable.dispose();
    if (this._scrollDisposable) this._scrollDisposable.dispose();
    if (this._cursorMoveDisposable) this._cursorMoveDisposable.dispose();
    if (this._renderDisposable) this._renderDisposable.dispose();
    const textarea = this.term.textarea;
    for (const listener of this._compositionListeners || []) {
      textarea?.removeEventListener?.(listener.type, listener.sync);
    }
    this._compositionListeners = null;
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

  /** 单元格实际渲染尺寸；首帧渲染前退化成按字号估算。 */
  _cell() {
    const screen = this.term.element && this.term.element.querySelector('.xterm-screen');
    if (screen) {
      const r = screen.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) {
        return { w: r.width / this.term.cols, h: r.height / this.term.rows };
      }
    }
    return { w: this.fontSize * 0.6, h: Math.round(this.fontSize * 1.25) };
  }
}
