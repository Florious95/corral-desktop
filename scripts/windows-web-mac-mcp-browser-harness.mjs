#!/usr/bin/env node
/**
 * Functions printed by this helper are pasted into Chrome DevTools MCP
 * evaluate_script. They intentionally return JSON-safe evidence only.
 *
 * Usage:
 *   node scripts/windows-web-mac-mcp-browser-harness.mjs --print start
 *   node scripts/windows-web-mac-mcp-browser-harness.mjs --print static
 *   node scripts/windows-web-mac-mcp-browser-harness.mjs --print finish
 */

function startWebSocketTrace() {
  const trace = [];
  const send = WebSocket.prototype.send;
  const dispatch = WebSocket.prototype.dispatchEvent;
  const safe = (direction, data) => {
    if (typeof data !== 'string') return;
    try {
      const frame = JSON.parse(data);
      const payload = { ...(frame.payload || {}) };
      delete payload.token;
      if (payload.bytes) payload.bytes = `<${String(payload.bytes).length} base64 chars>`;
      trace.push({ direction, type: frame.type, payload });
    } catch {
      // Binary/non-JSON traffic is intentionally not captured.
    }
  };
  WebSocket.prototype.send = function patchedSend(data) {
    safe('out', data);
    return send.call(this, data);
  };
  WebSocket.prototype.dispatchEvent = function patchedDispatch(event) {
    if (event?.type === 'message') safe('in', event.data);
    return dispatch.call(this, event);
  };
  window.__amWsTrace = trace;
  window.__amWsTraceStop = () => {
    WebSocket.prototype.send = send;
    WebSocket.prototype.dispatchEvent = dispatch;
    return trace.slice();
  };
  return { started: true };
}

async function collectStaticBrowserReceipt() {
  const rr = (element) => {
    if (!element) return null;
    const r = element.getBoundingClientRect();
    const cs = getComputedStyle(element);
    return {
      x: r.x, y: r.y, width: r.width, height: r.height,
      top: r.top, bottom: r.bottom, left: r.left, right: r.right,
      overflowX: cs.overflowX, overflowY: cs.overflowY,
      transform: cs.transform,
      clientWidth: element.clientWidth, clientHeight: element.clientHeight,
      scrollWidth: element.scrollWidth, scrollHeight: element.scrollHeight,
    };
  };
  const scroll = document.querySelector('.tb-tabs-scroll');
  const capsule = document.querySelector('.tb-tab-capsule');
  const active = document.querySelector('.tb-tab.is-active');
  const root = getComputedStyle(document.documentElement);
  const luminance = (hex) => {
    const rgb = [1, 3, 5].map((index) => parseInt(hex.slice(index, index + 2), 16) / 255);
    const linear = rgb.map((value) => value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2];
  };
  const contrast = (fg, bg) => {
    const a = luminance(fg);
    const b = luminance(bg);
    return Number(((Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05)).toFixed(2));
  };
  const colors = ['#3a3835', '#c0392b', '#3f7a4c', '#a4542e', '#3b6ea5', '#8054a8', '#2b7a78', '#6d6a63'];
  const host = document.createElement('div');
  const events = [];
  host.addEventListener('keydown', (event) => {
    if (!event.ctrlKey || event.metaKey || event.altKey || !/^v$/i.test(event.key)) return;
    event.preventDefault();
    event.stopPropagation();
    events.push({ type: 'ctrl-v', defaultPrevented: event.defaultPrevented });
  }, true);
  document.body.append(host);
  const ctrlV = new KeyboardEvent('keydown', {
    key: 'v', code: 'KeyV', ctrlKey: true, bubbles: true, cancelable: true,
  });
  host.dispatchEvent(ctrlV);
  host.remove();

  const nativeInput = await import('/src/term/nativeInput.js');
  const sequences = [
    '\\x16', '\\x1b[<0;10;10M', '\\x1b[<2;10;10M', '\\x1b[<64;10;10M',
    '\\x1b[A', '\\x1b[H',
  ];
  const mapping = Object.fromEntries(sequences.map((sequence) => [sequence, nativeInput.parseOnData(sequence)]));
  const silentEvents = Object.entries(mapping).filter(([, result]) => result.some((event) => event.type === 'mouse-silent'))
    .map(([sequence]) => sequence);

  return {
    tab: {
      scroll: rr(scroll),
      active: rr(active),
      capsule: rr(capsule),
      clipPx: scroll && capsule ? Math.max(0, capsule.getBoundingClientRect().bottom - scroll.getBoundingClientRect().bottom) : 0,
      overflowPx: scroll ? scroll.scrollHeight - scroll.clientHeight : 0,
    },
    dark: {
      prefersDark: matchMedia('(prefers-color-scheme: dark)').matches,
      vars: Object.fromEntries(['--bg', '--bg-solid', '--text', '--text-muted'].map((name) => [name, root.getPropertyValue(name).trim()])),
      colors: colors.map((fg) => ({ fg, bg: '#1e1e1e', contrast: contrast(fg, '#1e1e1e') })),
    },
    paste: {
      ctrlVDefaultPrevented: events[0]?.defaultPrevented === true,
      nativeTextFallback: window.__amWindowsNativeTextFallback === true,
    },
    mapping: { sequences: mapping, silentEvents },
    wsTraceStarted: Array.isArray(window.__amWsTrace),
  };
}

function finishWebSocketTrace() {
  const trace = typeof window.__amWsTraceStop === 'function'
    ? window.__amWsTraceStop()
    : (window.__amWsTrace || []);
  const close = trace.find((frame) => frame.direction === 'out' && frame.type === 'close_session');
  const result = trace.find((frame) => frame.type === 'close_session_result' || frame.type === 'error');
  return { trace, close, result, nativeTextFallback: window.__amWindowsNativeTextFallback === true };
}

const printIndex = process.argv.indexOf('--print');
const source = printIndex >= 0 ? (process.argv[printIndex + 1] || 'static') : 'static';
const functions = { start: startWebSocketTrace, static: collectStaticBrowserReceipt, finish: finishWebSocketTrace };
if (!functions[source]) {
  console.error('Expected --print start|static|finish');
  process.exitCode = 2;
} else {
  console.log(functions[source].toString());
}

export { startWebSocketTrace, collectStaticBrowserReceipt, finishWebSocketTrace };
