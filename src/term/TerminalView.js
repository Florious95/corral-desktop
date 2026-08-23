/*
 * AgentMirror 桌面端 —— xterm 底座（CLIENT-CONTRACT §1.3 的重写版）。
 *
 * 保留 web 版 TerminalView 的全部语义，只换实现底座：
 *   - snapshot → reset() + write()（清屏重建；游标锚 ESC[row;colH 在字节尾，必须整段原样喂）
 *   - delta    → write()（追加）
 *   - resize   → 120ms debounce 合并后回调（服务端每次真 reflow 都补一帧 snapshot，不合并会闪）
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
import { isLocalSidebarToggle, unsupportedKeyEvent, consumeTerminalReplies, REPLY_HOLD_MAX } from './nativeInput.js';
import { attachWebglRenderer } from './webglRenderer.js';

/** 滚轮触顶到再次触发拉历史之间的最小间隔（ms），避免一次手势打出几十个请求。 */
const WHEEL_THROTTLE_MS = 400;
/** 本地 grid 与上报共用：列宽抖动未落定前 ⛔ 不 term.resize 旧快照。 */
export const GRID_DEBOUNCE_MS = 120;

export class TerminalView {
  /**
   * @param {HTMLElement} container 已有确定尺寸的挂载容器
   * @param {Object}   [opts]
   * @param {(rows:number, cols:number) => void} [opts.onResize]         几何变了（已 debounce）
   * @param {() => void}                         [opts.onHistoryBoundary] 视口滚到顶 / 顶部继续上滚
   * @param {(data:string) => void}               [opts.onData]            xterm 编好的按键字节
   * @param {(label:string) => void}              [opts.onUnsupportedKey]  协议表达不了的键
   * @param {number}   [opts.scrollback=0]  本地回滚行数。默认 0：历史唯一事实来源是协议
   *                                        scrollback 帧（UI-SPEC §6.2）
   * @param {number}   [opts.fontSize=13]
   * @param {Function} [opts.TerminalCtor]  仅供单测注入 FakeTerminal；生产走 @xterm/xterm
   */
  constructor(container, {
    onResize, onHistoryBoundary, onData, onUnsupportedKey,
    scrollback = 0, fontSize = 13, TerminalCtor = Terminal,
  } = {}) {
    this.container = container;
    this.onResize = onResize || (() => {});
    this.onHistoryBoundary = onHistoryBoundary || (() => {});
    this.onData = onData || (() => {});
    this.onUnsupportedKey = onUnsupportedKey || (() => {});
    this.fontSize = fontSize;
    this.term = new TerminalCtor({
      scrollback,
      fontSize,
      fontFamily: 'ui-monospace, SF Mono, Menlo, monospace',
      lineHeight: 1.25,
      customGlyphs: true,
      cursorBlink: true,
      cursorStyle: 'block',
      cursorInactiveStyle: 'outline',
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
    this._replyHold = '';
    this._hasPainted = false;
  }

  /** 挂载进容器并做一次 fit。 */
  open() {
    this.term.open(this.container);
    this._dataDisposable = this.term.onData((data) => {
      const r = consumeTerminalReplies(data, this._replyHold);
      this._replyHold = r.hold.length > REPLY_HOLD_MAX ? '' : r.hold;
      if (r.kept.length) this.onData(r.kept);
    });
    if (typeof this.term.attachCustomKeyEventHandler === 'function') {
      this.term.attachCustomKeyEventHandler((ev) => {
        if (isLocalSidebarToggle(ev)) return false;
        const label = unsupportedKeyEvent(ev);
        if (!label) return true;
        this.onUnsupportedKey(label);
        return false;
      });
    }
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
    // WebGL 接上之后再给调用方开订阅，避免首帧 snapshot 写在 DOM 上、addon 一切换就空屏。
    this.readyWebgl = attachWebglRenderer(this.term).then((addon) => {
      this._webglAddon = addon;
      // addon 换渲染器后必须再 fit 一次：探针 T1 70x29 → T3 73x23。
      if (addon) this.fit({ immediate: true });
    });
  }

  /**
   * 按容器像素重算 rows/cols。首帧立刻落到格子上；之后 120ms 内的抖动只记目标，
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
    this._pendingCols = cols;
    this._pendingRows = rows;
    if (!this._hasFit || immediate) {
      this._hasFit = true;
      this._commitGrid(cols, rows, { reportDelay: true });
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

  /** 全屏快照：清屏重建（protocol §6.2）。字节整段原样喂，⛔ 不 trim、不按行拆。 */
  writeSnapshot(u8) {
    this.term.reset();
    this.term.write(u8);
    this._hasPainted = true;
  }

  /** 增量：追加到当前屏。 */
  writeDelta(u8) {
    this.term.write(u8);
  }

  clear() { this.term.reset(); }

  focus() { try { this.term.focus(); } catch { /* 已 dispose */ } }

  blur() { try { this.term.blur(); } catch { /* 已 dispose */ } }

  scrollToBottom() { this.term.scrollToBottom(); }

  dispose() {
    this._disposed = true;
    this._replyHold = '';
    clearTimeout(this._resizeTimer);
    clearTimeout(this._gridTimer);
    try { this._webglAddon?.dispose(); } catch { /* already gone */ }
    this._webglAddon = null;
    if (this._onWheel && this.container) this.container.removeEventListener('wheel', this._onWheel);
    if (this._dataDisposable) this._dataDisposable.dispose();
    if (this._scrollDisposable) this._scrollDisposable.dispose();
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
