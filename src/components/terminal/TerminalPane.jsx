import { useEffect, useRef, useState, useCallback } from 'react';
import '@xterm/xterm/css/xterm.css';
import './terminal.css';
import { XIcon, TerminalIcon } from '../../lib/icons.jsx';
import { TerminalView } from '../../term/TerminalView.js';
import { SameWidthController } from '../../term/sameWidth.js';
import { geomTrace, bookOf } from '../../term/geomTrace.js';
import { NativeInputPump } from '../../term/nativeInput.js';
import { WheelAccumulator } from '../../term/wheelScroll.js';
import { BINARY_KIND } from '../../core/binary.js';
import { fetchOlder, acceptScrollback } from '../../../deps/corral-core/web/js/scrollback.js';
import { parseAnsi } from './ansi.js';
import { MOBILE_GRID, PRESENCE_MODE } from '../../core/presence.js';
import { computeGridDimensions, terminalLineHeight } from '../../term/fontMetrics.js';
import { nativeCapabilities } from '../../core/nativeCapabilities.js';

export { MOBILE_GRID, PRESENCE_MODE };

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
 * @param {(bytes:Uint8Array) => void} [props.onBytes]
 * @param {() => void} [props.onEnter]
 * @param {() => void} [props.onCtrlV]
 * @param {(event:ClipboardEvent) => void} [props.onPaste]
 * @param {string} props.agent.provider     Cursor uses a software input cursor; hide its parked xterm cursor
 */
export default function TerminalPane({
  agent, client, addr, subscribeBinary, focused = false, onResize,
  onText, onKey, onBytes, onEnter,
  onCtrlV, onPaste, onForceTextPaste,
  fontFamily, fontSize,
  containerWidth, containerHeight,
  isVisible = true,
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
  const [renderDiag, setRenderDiag] = useState({ rendered: false, renderer: 'dom', canvasCount: 0 });
  const [history, setHistory] = useState(null);   // { fromLine, lineCount, text }
  const [hint, setHint] = useState('');
  const [presenceMode, setPresenceMode] = useState(PRESENCE_MODE.UNKNOWN);
  const onTextRef = useRef(onText);
  const onKeyRef = useRef(onKey);
  const onBytesRef = useRef(onBytes);
  const onEnterRef = useRef(onEnter);
  const onCtrlVRef = useRef(onCtrlV);
  const onPasteRef = useRef(onPaste);
  const onForceTextPasteRef = useRef(onForceTextPaste);
  const pendingFocusRef = useRef(false);
  const isVisibleRef = useRef(isVisible);
  isVisibleRef.current = isVisible;
  const syncVisibilityRef = useRef(null);
  onTextRef.current = onText;
  onKeyRef.current = onKey;
  onBytesRef.current = onBytes;
  onEnterRef.current = onEnter;
  onCtrlVRef.current = onCtrlV;
  onPasteRef.current = onPaste;
  onForceTextPasteRef.current = onForceTextPaste;

  // 窗格点击物理聚焦唤醒入口（裁决 §4.3, §4.4, §4.5）
  const handlePaneMouseDown = useCallback((e) => {
    // 只有主键（左键）有效点击可交互终端内容才同步请求聚焦
    if (e.button !== 0) return;
    // 排除项：点击历史面板及其文字、按钮、表单控件等不抢焦点
    if (e.target?.closest?.('.terminalpane-history, button, input, select, textarea, [data-no-focus="true"]')) {
      return;
    }
    const view = viewRef.current;
    if (view) {
      view.focus();
    } else {
      pendingFocusRef.current = true;
    }
  }, []);

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
    // 1. 首帧几何前置纯数学投影（彻底消灭 80x24 与 46x44 盲订）：
    const paddingX = 10;
    const paddingY = 0;
    const effectiveW = host.clientWidth || (containerWidth ? Math.max(0, containerWidth - paddingX) : 0);
    const effectiveH = host.clientHeight || (containerHeight ? Math.max(0, containerHeight - paddingY) : 0);

    let initialCols = null;
    let initialRows = null;
    if (effectiveW > 0 && effectiveH > 0) {
      const grid = computeGridDimensions({
        width: effectiveW,
        height: effectiveH,
        lineHeight: terminalLineHeight(nativeCapabilities.platform),
        fontFamily,
        fontSize,
      });
      initialCols = grid.cols;
      initialRows = grid.rows;
    }

    const pump = new NativeInputPump({
      deferText: nativeCapabilities.platform !== 'macos',
      sendText: (text) => onTextRef.current?.(text),
      sendKey: (key) => onKeyRef.current?.(key),
      sendBytes: (bytes) => onBytesRef.current?.(bytes),
      sendEnter: () => onEnterRef.current?.(),
      onUnsupported: showUnsupported,
    });
    const gate = new SameWidthController();
    let firstSub = true;
    let lastSubscribe = null;

    // 默认进入 TAKEOVER 模式，首订携带最终真实尺寸，彻底消除 500ms 盲等与二次弹跳
    const initialPresence = clientRef.current?.getPresence?.();
    const isMobileActive = initialPresence && initialPresence.hasMobile === true;
    let currentMode = isMobileActive ? PRESENCE_MODE.AVOIDANCE : PRESENCE_MODE.TAKEOVER;
    setPresenceMode(currentMode);
    if (!isMobileActive && initialCols && initialRows) {
      gate.settle(initialRows, initialCols);
    }

    let isManualReflowing = false;
    let view;
    const sendIfNeeded = (act, reason, { force = false } = {}) => {
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
      if (view && !view.isVisible) {
        geomTrace('subscribe', {
          ref: target,
          rows: act ? act.rows : null,
          cols: act ? act.cols : null,
          reason,
          ok: false,
          skipped: 'pane_hidden',
          grid_cols: gate.grid ? gate.grid.cols : null,
          ...bookOf(target),
        });
        return;
      }
      const subscribeKey = `${target}:${act.rows}x${act.cols}`;
      if (!force && lastSubscribe === subscribeKey) {
        geomTrace('subscribe', {
          ref: target,
          rows: act.rows,
          cols: act.cols,
          reason,
          ok: false,
          skipped: 'same_geometry',
          ...bookOf(target),
        });
        return;
      }
      const sent = clientRef.current?.subscribe(target, act.rows, act.cols, reason, {
        client_type: 'desktop',
        retain_pane_size: true,
      });
      if (sent === false) return;
      lastSubscribe = subscribeKey;
      gate.noteSent(act.rows, act.cols);
    };
    const paneHost = host.closest?.('.pane-host');
    const isPaneVisible = (paneHost ? !paneHost.classList.contains('is-hidden') && paneHost.style.visibility !== 'hidden' : true) && (isVisible !== false);

    view = new TerminalView(host, {
      traceRef: target,
      fontFamily,
      fontSize,
      isVisible: isPaneVisible,
      initialCols: currentMode === PRESENCE_MODE.TAKEOVER ? initialCols : null,
      initialRows: currentMode === PRESENCE_MODE.TAKEOVER ? initialRows : null,
      onFirstPaint: (info) => {
        setRenderDiag({
          rendered: true,
          renderer: info.renderer,
          canvasCount: info.canvasCount,
        });
      },
      onResize: (rows, cols) => {
        const act = gate.settle(rows, cols);
        if (!isManualReflowing) {
          const reason = firstSub ? 'activate' : 'settle';
          sendIfNeeded(act, reason);
          if (act && act.type === 'subscribe') firstSub = false;
        }
        onResizeRef.current?.(rows, cols);
      },
      onWriteBackpressure: () => {
        const grid = gate.grid;
        if (!grid) return;
        // A recovery subscribe is intentional even at the same geometry; all
        // ordinary settled-grid callbacks still pass through the dedupe gate.
        sendIfNeeded({ type: 'subscribe', rows: grid.rows, cols: grid.cols }, 'write_backpressure', { force: true });
      },
      onHistoryBoundary: () => loadHistory(),
      hideCursor: agent.provider === 'cursor',
      onData: (data) => pump.onData(data),
      onBinary: (data) => pump.onBinary(data),
      onPaste: (ev) => onPasteRef.current?.(ev),
      onCtrlV: () => onCtrlVRef.current?.(),
      onForceTextPaste: () => onForceTextPasteRef.current?.(),
      onCopyError: () => setHint('复制失败，请重试'),
    });
    view.readyWebgl?.then(() => {
      if (viewRef.current === view) {
        setRenderDiag((prev) => ({
          ...prev,
          renderer: view.rendererType,
          canvasCount: view.canvasCount,
        }));
      }
    });
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
      // 后台隐藏窗格彻底断流（Issue #316）：绝不向非激活终端写入任何帧，杜绝 DomRenderer 分配 DOM 节点与 TypedArray 堆积
      if (!viewRef.current?.isVisible) return;
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

    const triggerTakeover = () => {
      if (currentMode !== PRESENCE_MODE.TAKEOVER) {
        currentMode = PRESENCE_MODE.TAKEOVER;
        setPresenceMode(PRESENCE_MODE.TAKEOVER);
        if (viewRef.current && hostRef.current) {
          isManualReflowing = true;
          try {
            viewRef.current.clearFixedGrid();
            viewRef.current.fit({ immediate: true, sync: true });
          } finally {
            isManualReflowing = false;
          }
          const fit = viewRef.current.lastFit;
          if (fit?.derived_rows && fit?.derived_cols) {
            gate.settle(fit.derived_rows, fit.derived_cols);
            sendIfNeeded({ type: 'subscribe', rows: fit.derived_rows, cols: fit.derived_cols }, 'takeover', { force: true });
            firstSub = false;
          }
        }
      }
    };

    if (isMobileActive) {
      view.setFixedGrid(MOBILE_GRID, { sync: true });
    }

    // 监听多端 presence 广播：动静双模流转，消除死循环与重复发送 (R2)
    const offPresence = clientRef.current?.onPresence?.((evt) => {
      // 若断开连接，立即将模式降级为 UNKNOWN 并锁定 46x44 (R3)
      if (evt.disconnected) {
        currentMode = PRESENCE_MODE.UNKNOWN;
        setPresenceMode(PRESENCE_MODE.UNKNOWN);
        if (viewRef.current) {
          isManualReflowing = true;
          try {
            viewRef.current.setFixedGrid(MOBILE_GRID, { sync: true });
          } finally {
            isManualReflowing = false;
          }
          gate.settle(MOBILE_GRID.rows, MOBILE_GRID.cols);
          gate.noteSent(MOBILE_GRID.rows, MOBILE_GRID.cols);
        }
        return;
      }

      if (evt.hasMobile) {
        // 手机在线/重回 -> 避让模式 (avoidance)：保持 46x44 物理底锚，绝不发桌面 resize
        if (currentMode !== PRESENCE_MODE.AVOIDANCE || gate.grid?.rows !== MOBILE_GRID.rows || gate.grid?.cols !== MOBILE_GRID.cols) {
          currentMode = PRESENCE_MODE.AVOIDANCE;
          setPresenceMode(PRESENCE_MODE.AVOIDANCE);
          if (viewRef.current) {
            isManualReflowing = true;
            try {
              viewRef.current.setFixedGrid(MOBILE_GRID, { sync: true });
            } finally {
              isManualReflowing = false;
            }
            if (gate.grid?.rows !== MOBILE_GRID.rows || gate.grid?.cols !== MOBILE_GRID.cols) {
              gate.settle(MOBILE_GRID.rows, MOBILE_GRID.cols);
              sendIfNeeded({ type: 'subscribe', rows: MOBILE_GRID.rows, cols: MOBILE_GRID.cols }, 'presence_avoidance', { force: true });
              firstSub = false;
            }
          }
        }
      } else {
        // 手机离开 -> 仅在初次从避让/未知切入接管态（currentMode !== TAKEOVER）时，才执行一次接管！
        // R2: 杜绝死循环！若已经处于 TAKEOVER，重复收到 false 绝对不重复发订阅
        triggerTakeover();
      }
    });

    // The frame listener must be live before open() can report its initial grid
    // and trigger the first subscribe.
    viewRef.current = view;
    view.open();
    // Hidden resident panes are content-visibility skipped, so xterm records
    // a zero client rect during open. Preserve the projected non-zero geometry
    // used for the initial grid; revealing an unchanged split must stay silent.
    if (initialCols && initialRows && effectiveW > 0 && effectiveH > 0 && view.lastFit) {
      view.lastFit.container_width_px = effectiveW;
      view.lastFit.container_height_px = effectiveH;
    }
    if (focused || pendingFocusRef.current) {
      view.focus();
      pendingFocusRef.current = false;
    }

    const ro = new ResizeObserver(() => {
      // Hidden resident panes already have their projected geometry. Their
      // observer may fire while a tab switches, but fitting them here only
      // repeats the same grid and can trigger an activation reflow.
      if (host.closest('.is-hidden')) return;
      if (view.isFitCurrent?.()) return;
      if (currentMode === PRESENCE_MODE.TAKEOVER) {
        view.fit();
      } else {
        // 避让模式下只测量容器，保持 46x44 网格不向服务端发送桌面 resize
        view.fit({ immediate: false, sync: true });
      }
    });
    ro.observe(host);

    const handleLayoutSettled = () => {
      if (nativeCapabilities.platform !== 'macos' || currentMode !== PRESENCE_MODE.TAKEOVER
          || host.closest('.is-hidden') || view.isFitCurrent?.()) return;
      view.fit({ immediate: true, sync: true });
    };
    const stage = host.closest('.terminal-stage');
    stage?.addEventListener('terminal:layout-settled', handleLayoutSettled);

    const handleReflow = (ev) => {
      const targetUid = ev?.detail?.uid;
      if (targetUid && targetUid !== target && targetUid !== agent.key && targetUid !== agent.ref) return;
      if (!viewRef.current || !hostRef.current) return;

      // R4 (P1): 手动“适应当前窗口”必须严格遵守当前 presence：
      // 当手机在线 (has_mobile: true) 或状态未知 (unknown) 时，严禁下发桌面大尺寸抢占！
      // 只允许在当前 46x44 尺寸上发一次强制 subscribe 恢复快照与对齐
      if (currentMode === PRESENCE_MODE.AVOIDANCE) {
        gate.settle(MOBILE_GRID.rows, MOBILE_GRID.cols);
        sendIfNeeded({ type: 'subscribe', rows: MOBILE_GRID.rows, cols: MOBILE_GRID.cols }, 'reflow_mobile_recover', { force: true });
        firstSub = false;
        return;
      }

      // 仅当手机离开 (takeover) 时，才允许测量桌面尺寸并发送铺满桌面视口
      currentMode = PRESENCE_MODE.TAKEOVER;
      setPresenceMode(PRESENCE_MODE.TAKEOVER);
      isManualReflowing = true;
      try {
        viewRef.current.clearFixedGrid();
        viewRef.current.fit({ immediate: true, sync: true });
      } finally {
        isManualReflowing = false;
      }
      const fit = viewRef.current.lastFit;
      if (fit && fit.derived_rows && fit.derived_cols) {
        // 原子同步：确保 gate.grid 在发送前与待发送尺寸严格一致，杜绝快照早到拒收死锁 (F1)
        gate.settle(fit.derived_rows, fit.derived_cols);
        sendIfNeeded({ type: 'subscribe', rows: fit.derived_rows, cols: fit.derived_cols }, 'reflow', { force: true });
        firstSub = false;
      }
    };
    const handleThemeChange = (ev) => {
      if (viewRef.current && typeof ev?.detail?.isDark === 'boolean') {
        viewRef.current.setDark(ev.detail.isDark);
      }
    };
    if (typeof window !== 'undefined') {
      window.addEventListener('terminal:reflow', handleReflow);
      window.addEventListener('terminal:theme-change', handleThemeChange);
    }

    const syncVisibility = (visible) => {
      if (!view) return;
      const prevVisible = view.isVisible;
      view.setVisible(visible);
      setRenderDiag((prev) => ({
        ...prev,
        renderer: view.rendererType,
        canvasCount: view.canvasCount,
      }));
      if (visible) {
        view.attachWebgl()?.then(() => {
          if (viewRef.current === view) {
            setRenderDiag((prev) => ({
              ...prev,
              renderer: view.rendererType,
              canvasCount: view.canvasCount,
            }));
          }
        });
        if (!prevVisible) {
          // 从后台切入前台：检查尺寸漂移（仅当物理尺寸改变时才测量），若网格未变直接复用已有画面，绝不强行 force 重新拉取快照清屏 (Issue #301 & #321)
          if (!view.isFitCurrent?.()) {
            view.fit({ immediate: true, sync: true });
          }
          const grid = gate.grid || (view.rows && view.cols ? { rows: view.rows, cols: view.cols } : null);
          if (grid) {
            gate.settle(grid.rows, grid.cols);
            sendIfNeeded({ type: 'subscribe', rows: grid.rows, cols: grid.cols }, 'visibility_resume');
            firstSub = false;
          }
        }
      } else {
        if (prevVisible) {
          // 切入后台：退订断流，防止后台持续产生数据流与 DOM 节点 (Issue #316)
          clientRef.current?.unsubscribe(target);
          lastSubscribe = null;
        }
      }
    };
    syncVisibilityRef.current = syncVisibility;

    let mo = null;
    if (paneHost && typeof MutationObserver !== 'undefined') {
      mo = new MutationObserver(() => {
        const isHidden = Boolean(host.closest?.('.is-hidden') || paneHost.classList.contains('is-hidden') || paneHost.style.visibility === 'hidden');
        const visible = !isHidden && (isVisibleRef.current !== false);
        syncVisibility(visible);
      });
      mo.observe(paneHost, { attributes: true, attributeFilter: ['class', 'style', 'aria-hidden'] });
    }

    return () => {
      syncVisibilityRef.current = null;
      mo?.disconnect();
      if (typeof window !== 'undefined') {
        window.removeEventListener('terminal:reflow', handleReflow);
        window.removeEventListener('terminal:theme-change', handleThemeChange);
      }
      ro.disconnect();
      stage?.removeEventListener('terminal:layout-settled', handleLayoutSettled);
      host.removeEventListener('wheel', onWheel, { capture: true });
      wheel.dispose();
      clearTimeout(g.timer);
      clearTimeout(flashTimer);
      pump.dispose();
      if (typeof off === 'function') off();
      if (typeof offPresence === 'function') offPresence();
      view.dispose();
      viewRef.current = null;
      gRef.current = null;
      pendingFocusRef.current = false;
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

  // 动态响应终端字体与字号变更（Issue #193）
  useEffect(() => {
    if (viewRef.current && (fontFamily !== undefined || fontSize !== undefined)) {
      viewRef.current.updateFont({ fontFamily, fontSize });
    }
  }, [fontFamily, fontSize]);

  // 动态响应窗格可见性变更（Issue #314 & #316）：前台按需激活 WebGL 与快照订阅，切入后台时注销 WebGL 释放 Canvas 并退订断流
  useEffect(() => {
    const host = hostRef.current;
    const paneHost = host?.closest?.('.pane-host');
    const isHidden = Boolean(host?.closest?.('.is-hidden') || paneHost?.classList.contains('is-hidden') || paneHost?.style.visibility === 'hidden');
    const visible = !isHidden && (isVisible !== false);
    syncVisibilityRef.current?.(visible);
  }, [isVisible]);

  return (
    <div
      className="terminalpane"
      data-platform={nativeCapabilities.platform}
      data-presence-mode={presenceMode}
      data-ready={ready ? 'true' : 'false'}
      data-rendered={renderDiag.rendered ? 'true' : 'false'}
      data-renderer={renderDiag.renderer}
      data-canvas-count={renderDiag.canvasCount}
      data-cols={viewRef.current?.cols ?? agent.cols ?? undefined}
      data-rows={viewRef.current?.rows ?? agent.rows ?? undefined}
      onMouseDown={handlePaneMouseDown}
    >
      <div className={`terminalpane-body${presenceMode === PRESENCE_MODE.TAKEOVER ? ' is-takeover' : ''}`}>
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

        <div
          className={`terminalpane-host${presenceMode === PRESENCE_MODE.TAKEOVER ? ' is-takeover' : ''}`}
          ref={hostRef}
          data-alignment="bottom-left"
        />

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
