import { useEffect, useRef, useState, useCallback } from 'react';
import '@xterm/xterm/css/xterm.css';
import './terminal.css';
import { XIcon, TerminalIcon } from '../../lib/icons.jsx';
import { TerminalView } from '../../term/TerminalView.js';
import { SameWidthController } from '../../term/sameWidth.js';
import { geomTrace, bookOf } from '../../term/geomTrace.js';
import { NativeInputPump } from '../../term/nativeInput.js';
import { WheelAccumulator } from '../../term/wheelScroll.js';
import { BINARY_KIND } from '../../vendor/agentmirror/binary.js';
import { fetchOlder, acceptScrollback } from '../../vendor/agentmirror/scrollback.js';
import { parseAnsi } from './ansi.js';

/** scrollback 请求没等到回复时的兜底解锁（ms）。不解锁的话历史面板会永久卡在 pending。 */
const SCROLLBACK_TIMEOUT_MS = 10000;

/**
 * 一个分裂列的终端视图：网格落定后 subscribe → 同宽 snapshot 清屏重建 → delta 追加；
 * 容器尺寸变化 → fit 落定 → 重发 subscribe（resize 在几何未变时 no-op 不补快照）；
 * 捕获宽度 ≠ 网格宽度的帧 ⛔ 不画进 xterm（裁定 2026-08-23 同宽不变量）。
 * 上滚到顶 → 协议 scrollback 分页拉取，渲染进独立只读面板（⛔ 绝不写进活的 xterm 网格，§3.3）。
 *
 * @param {Object} props
 * @param {Object} props.agent          Agent（UI-SPEC §0）；`agent.key` 变化才会重挂
 * @param {Object} props.client         会话句柄，由 App 从 DeviceManager 适配。需提供：
 *                                      `isReady:boolean`、`subscribe(addr,rows,cols)`、
 *                                      `unsubscribe(addr)`、`resize(addr,rows,cols)`、
 *                                      `scrollback(addr,fromLine,count) -> reqId|{reqId}|null`、
 *                                      `onBinary(handler) -> 退订函数`（只投递本列的帧）
 * @param {string} [props.addr]         寻址键，默认 `agent.ref`（DeviceManager 走 uid 时传 agent.key）
 * @param {(handler:(frame:Object)=>void) => (() => void)} [props.subscribeBinary]
 *                                      可选：外部帧流订阅；不传则用 `client.onBinary`
 * @param {boolean} [props.focused]     是否为键盘焦点列（映射到 xterm focus/blur）
 * @param {(rows:number, cols:number) => void} [props.onResize]
 * @param {(text:string) => void} [props.onText]
 * @param {(key:string) => void} [props.onKey]
 * @param {() => void} [props.onEnter]
 */
export default function TerminalPane({
  agent, client, addr, subscribeBinary, focused = false, onResize,
  onText, onKey, onEnter,
}) {
  const hostRef = useRef(null);
  const viewRef = useRef(null);
  const gRef = useRef(null);
  const clientRef = useRef(client);
  const subRef = useRef(subscribeBinary);
  const onResizeRef = useRef(onResize);
  clientRef.current = client;
  subRef.current = subscribeBinary;
  onResizeRef.current = onResize;

  const [ready, setReady] = useState(false);
  const [history, setHistory] = useState(null);   // { fromLine, lineCount, text }
  const [hint, setHint] = useState('');
  const onTextRef = useRef(onText);
  const onKeyRef = useRef(onKey);
  const onEnterRef = useRef(onEnter);
  onTextRef.current = onText;
  onKeyRef.current = onKey;
  onEnterRef.current = onEnter;

  const target = addr || agent.ref;

  const loadHistory = useCallback(() => {
    const g = gRef.current;
    if (!g || g.pendingScrollback) return;      // 单请求在飞
    fetchOlder(() => g, {
      onLoading: (n) => setHint(`加载 ${n} 行历史…`),
      onError: () => setHint('历史未发出：连接未就绪'),
    });
    const pending = g.pendingScrollback;
    if (!pending) return;
    clearTimeout(g.timer);
    g.timer = setTimeout(() => {
      if (g.pendingScrollback === pending) {
        g.pendingScrollback = null;
        setHint('历史未收到回执');
      }
    }, SCROLLBACK_TIMEOUT_MS);
  }, []);

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return undefined;

    let flashTimer = null;
    const showUnsupported = (label) => {
      setHint(`协议发不了：${label}`);
      clearTimeout(flashTimer);
      flashTimer = setTimeout(() => setHint(''), 2500);
    };
    const pump = new NativeInputPump({
      sendText: (text) => onTextRef.current?.(text),
      sendKey: (key) => onKeyRef.current?.(key),
      sendEnter: () => onEnterRef.current?.(),
      onUnsupported: showUnsupported,
    });
    const gate = new SameWidthController();
    let firstSub = true;
    let view;
    const sendIfNeeded = (act, reason) => {
      const fit = view?.lastFit || {};
      geomTrace('derived', {
        ref: target,
        container_width_px: fit.container_width_px ?? null,
        cell_width_px: fit.cell_width_px ?? null,
        derived_cols: fit.derived_cols ?? (act && act.cols) ?? (gate.grid && gate.grid.cols) ?? null,
        derived_rows: fit.derived_rows ?? (act && act.rows) ?? (gate.grid && gate.grid.rows) ?? null,
        last_sent_cols: gate.sent ? gate.sent.cols : null,
        last_sent_rows: gate.sent ? gate.sent.rows : null,
      });
      if (!act || act.type !== 'subscribe') {
        geomTrace('subscribe', {
          ref: target,
          rows: gate.grid ? gate.grid.rows : null,
          cols: gate.grid ? gate.grid.cols : null,
          reason,
          ok: false,
          skipped: 'gate_none',
          grid_cols: gate.grid ? gate.grid.cols : null,
          ...bookOf(target),
        });
        return;
      }
      clientRef.current?.subscribe(target, act.rows, act.cols, reason);
      gate.noteSent(act.rows, act.cols);
    };
    view = new TerminalView(host, {
      onResize: (rows, cols) => {
        const act = gate.settle(rows, cols);
        const reason = firstSub ? 'activate' : 'settle';
        sendIfNeeded(act, reason);
        if (act && act.type === 'subscribe') firstSub = false;
        onResizeRef.current?.(rows, cols);
      },
      onHistoryBoundary: () => loadHistory(),
      onData: (data) => pump.onData(data),
      onUnsupportedKey: showUnsupported,
    });
    view.open();
    viewRef.current = view;
    const wheel = new WheelAccumulator((delta) => {
      clientRef.current?.scrollWheel?.(target, delta);
    });
    const onWheel = (ev) => {
      // 捕获阶段先于 xterm 的 SGR 鼠标编码。preventDefault 才能拦住编码，passive 不行。
      ev.preventDefault();
      ev.stopPropagation();
      wheel.onWheel(ev);
    };
    host.addEventListener('wheel', onWheel, { capture: true, passive: false });

    // fetchOlder/acceptScrollback 直接读写这个对象上的 pendingScrollback / nextScrollbackLine。
    const g = {
      term: view,
      ref: target,
      client: {
        scrollback: (ref, from, count) => {
          const r = clientRef.current?.scrollback(ref, from, count);
          // 裸 Client 回 reqId|null；DeviceManager 回 {deviceId, reqId}|null。
          return r && typeof r === 'object' ? r.reqId : (r ?? null);
        },
      },
      pendingScrollback: null,
      nextScrollbackLine: null,
      timer: null,
      showScrollbackPanel: (fromLine, lineCount, data) => {
        clearTimeout(g.timer);
        setHistory({ fromLine, lineCount, text: new TextDecoder('utf-8').decode(data) });
        setHint('');
      },
    };
    gRef.current = g;

    const handleBinary = (frame) => {
      // App 未按 uid 过滤时的二次防线：别把别的列的帧画进这一列。
      if (frame.ref && frame.ref !== agent.ref && frame.ref !== target) return;
      switch (frame.kind) {
        case BINARY_KIND.SNAPSHOT: {
          const painted = gate.acceptSnapshot();
          geomTrace('snapshot', {
            ref: frame.ref || target,
            frame_cols: agent.cols ?? null,
            frame_rows: agent.rows ?? null,
            grid_cols: gate.grid ? gate.grid.cols : (view.cols ?? null),
            grid_rows: gate.grid ? gate.grid.rows : (view.rows ?? null),
            painted,
            skipped: painted ? null : 'gate_reject',
            bytes_len: frame.data ? frame.data.byteLength || frame.data.length : 0,
          });
          if (!painted) return;
          view.writeSnapshot(frame.data);
          setReady(true);
          break;
        }
        case BINARY_KIND.DELTA: {
          const painted = gate.acceptDelta();
          geomTrace('delta', {
            ref: frame.ref || target,
            frame_cols: agent.cols ?? null,
            grid_cols: gate.grid ? gate.grid.cols : (view.cols ?? null),
            painted,
            skipped: painted ? null : 'gate_reject',
            bytes_len: frame.data ? frame.data.byteLength || frame.data.length : 0,
          });
          if (!painted) return;
          view.writeDelta(frame.data);
          break;
        }
        case BINARY_KIND.SCROLLBACK:
          acceptScrollback(g, frame);
          break;
        default:
          break;
      }
    };
    // 订阅二进制帧：优先 subscribeBinary prop，其次 client 自带的 onBinary（App 的薄 shim 走这条）。
    const c = clientRef.current;
    const attach = subRef.current || (c && typeof c.onBinary === 'function' ? (fn) => c.onBinary(fn) : null);
    const off = attach ? attach(handleBinary) : null;

    // A: 首订走 onResize（fit/webgl 落定后的 debounce），点开瞬间的过渡宽度不下订。

    const ro = new ResizeObserver(() => view.fit());
    ro.observe(host);

    return () => {
      ro.disconnect();
      host.removeEventListener('wheel', onWheel, { capture: true });
      wheel.dispose();
      clearTimeout(g.timer);
      clearTimeout(flashTimer);
      pump.dispose();
      if (typeof off === 'function') off();
      view.dispose();
      viewRef.current = null;
      gRef.current = null;
      clientRef.current?.unsubscribe(target);
    };
    // client / subscribeBinary 走 ref，身份变化不重挂；要换连接实例请由 App 用 React key 强制重挂。
  }, [agent.key, agent.ref, target, loadHistory]);

  useEffect(() => {
    const v = viewRef.current;
    if (!v) return;
    if (focused) v.focus();
    else v.blur();
  }, [focused]);

  return (
    <div className="terminalpane">
      <div className="terminalpane-body">
        {history && (
          <div className="terminalpane-history">
            <div className="terminalpane-history-head">
              <span>
                历史 {history.fromLine}..{history.fromLine + history.lineCount - 1}（{history.lineCount} 行）
              </span>
              <button type="button" className="terminalpane-history-btn" onClick={loadHistory}>更早</button>
              <button
                type="button"
                className="terminalpane-history-btn"
                aria-label="关闭历史面板"
                onClick={() => { setHistory(null); setHint(''); }}
              >
                <XIcon size={11} strokeWidth={2} />
              </button>
            </div>
            <pre className="terminalpane-history-body">
              {parseAnsi(history.text).map((seg, i) => (
                <span
                  key={i}
                  style={{
                    color: seg.fg || undefined,
                    background: seg.bg || undefined,
                    fontWeight: seg.bold ? 600 : undefined,
                  }}
                >
                  {seg.text}
                </span>
              ))}
            </pre>
          </div>
        )}

        <div className="terminalpane-host" ref={hostRef} />

        {!ready && (
          <div className="terminalpane-placeholder">
            <div className="terminalpane-placeholder-box">
              <TerminalIcon size={20} stroke="var(--icon-placeholder)" />
            </div>
            <div className="terminalpane-placeholder-title">正在连接会话…</div>
            <div className="terminalpane-placeholder-sub">订阅 {agent.ref} · 等待首帧快照</div>
          </div>
        )}

        {hint && <div className="terminalpane-hint">{hint}</div>}
      </div>
    </div>
  );
}
