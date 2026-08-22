/*
 * xterm onData → protocol input.text / input.keys (CLIENT-CONTRACT §0.3 / §3.5).
 * 不把 keydown 映射成字符；只吃 xterm 已经编好的字节，再按 8 值闭集分流。
 */

export const TEXT_FLUSH_MS = 32;
export const TEXT_FLUSH_CHARS = 64;
/** 真点击提示：同一泵每这么多毫秒最多一次。移动/滚轮上报不提示。 */
export const CLICK_HINT_MS = 3000;

const ARROW = { A: 'up', B: 'down', C: 'right', D: 'left' };

function ctrlLabel(code) {
  if (code === 4) return 'Ctrl-D';
  if (code === 1) return 'Ctrl-A';
  if (code === 5) return 'Ctrl-E';
  if (code === 18) return 'Ctrl-R';
  if (code === 26) return 'Ctrl-Z';
  if (code === 12) return 'Ctrl-L';
  if (code === 11) return 'Ctrl-K';
  if (code === 21) return 'Ctrl-U';
  if (code === 23) return 'Ctrl-W';
  if (code === 14) return 'Ctrl-N';
  if (code === 16) return 'Ctrl-P';
  if (code >= 1 && code <= 26) return `Ctrl-${String.fromCharCode(64 + code)}`;
  return `byte 0x${code.toString(16)}`;
}

function csiLabel(seq) {
  if (seq === '\x1b[Z') return 'Shift-Tab';
  if (seq === '\x1b[H' || seq === '\x1b[1~') return 'Home';
  if (seq === '\x1b[F' || seq === '\x1b[4~' || seq === '\x1b[8~') return 'End';
  if (seq === '\x1b[5~') return 'PageUp';
  if (seq === '\x1b[6~') return 'PageDown';
  if (seq === '\x1b[2~') return 'Insert';
  if (seq === '\x1b[3~') return 'Delete';
  if (/^\x1b\[1;2[ABCD]$/.test(seq)) return 'Shift-Arrow';
  if (/^\x1b\[[0-9]+;[0-9]+[A-Z]$/.test(seq)) return 'modified arrow';
  if (/^\x1b\[[0-9]*~$/.test(seq)) return 'function/nav key';
  return `CSI ${JSON.stringify(seq.slice(1))}`;
}

function mapCsi(seq) {
  if (seq === '\x1b[A') return 'up';
  if (seq === '\x1b[B') return 'down';
  if (seq === '\x1b[C') return 'right';
  if (seq === '\x1b[D') return 'left';
  return null;
}

/**
 * SGR 1006 鼠标：btn 64/65 = 滚轮，≥32 = 移动（含 35），0/1/2 = 真点击。
 * @returns {'silent'|'click'|null}
 */
export function classifyMouseBtn(btn) {
  if (!Number.isFinite(btn)) return 'silent';
  if (btn === 64 || btn === 65 || btn === 66 || btn === 67) return 'silent';
  if (btn >= 32) return 'silent';
  return 'click';
}

function mouseEvent(kind, seq) {
  if (kind === 'click') return { type: 'mouse-click', label: '鼠标点击', seq };
  return { type: 'mouse-silent', seq };
}

/**
 * @param {string} s xterm onData payload
 * @returns {Array<{type:'text',value:string}|{type:'enter'}|{type:'key',value:string}|{type:'unsupported',label:string,seq:string}>}
 */
export function parseOnData(s) {
  const events = [];
  if (typeof s !== 'string' || s.length === 0) return events;
  let i = 0;
  let text = '';
  const flush = () => {
    if (text.length === 0) return;
    events.push({ type: 'text', value: text });
    text = '';
  };
  while (i < s.length) {
    const c = s[i];
    const code = s.charCodeAt(i);
    if (c === '\r' || c === '\n') {
      flush();
      events.push({ type: 'enter' });
      if (c === '\r' && s[i + 1] === '\n') i += 1;
      i += 1;
      continue;
    }
    if (c === '\x7f' || c === '\b') {
      flush();
      events.push({ type: 'key', value: 'backspace' });
      i += 1;
      continue;
    }
    if (c === '\x03') {
      flush();
      events.push({ type: 'key', value: 'ctrl_c' });
      i += 1;
      continue;
    }
    if (c === '\t') {
      flush();
      events.push({ type: 'key', value: 'tab' });
      i += 1;
      continue;
    }
    if (c === '\x1b') {
      flush();
      // X10 鼠标：ESC [ M + 3 字节（btn/x/y 各 +32）
      if (s[i + 1] === '[' && s[i + 2] === 'M') {
        if (i + 5 >= s.length) {
          events.push(mouseEvent('silent', s.slice(i)));
          break;
        }
        const btn = s.charCodeAt(i + 3) - 32;
        events.push(mouseEvent(classifyMouseBtn(btn), s.slice(i, i + 6)));
        i += 6;
        continue;
      }
      if (s[i + 1] === '[') {
        // SGR 1006：ESC [ < btn ; x ; y M|m —— 必须在通用 CSI 之前吃掉，否则变成「协议发不了」
        if (s[i + 2] === '<') {
          let j = i + 3;
          while (j < s.length && s[j] !== 'M' && s[j] !== 'm') j += 1;
          if (j >= s.length) {
            events.push(mouseEvent('silent', s.slice(i)));
            break;
          }
          const seq = s.slice(i, j + 1);
          const m = /^(\d+)/.exec(s.slice(i + 3));
          const btn = m ? Number(m[1]) : NaN;
          events.push(mouseEvent(classifyMouseBtn(btn), seq));
          i = j + 1;
          continue;
        }
        let j = i + 2;
        while (j < s.length) {
          const cc = s.charCodeAt(j);
          if (cc >= 0x30 && cc <= 0x3f) { j += 1; continue; }
          break;
        }
        while (j < s.length) {
          const cc = s.charCodeAt(j);
          if (cc >= 0x20 && cc <= 0x2f) { j += 1; continue; }
          break;
        }
        if (j < s.length) {
          const fin = s.charCodeAt(j);
          if (fin >= 0x40 && fin <= 0x7e) {
            const seq = s.slice(i, j + 1);
            const key = mapCsi(seq);
            if (key) events.push({ type: 'key', value: key });
            else events.push({ type: 'unsupported', label: csiLabel(seq), seq });
            i = j + 1;
            continue;
          }
        }
        events.push({ type: 'unsupported', label: 'incomplete escape', seq: s.slice(i) });
        break;
      }
      if (s[i + 1] === 'O' && i + 2 < s.length) {
        const f = s[i + 2];
        if (ARROW[f]) events.push({ type: 'key', value: ARROW[f] });
        else events.push({ type: 'unsupported', label: f >= 'P' && f <= 'S' ? `F${f.charCodeAt(0) - 79}` : `SS3 ${f}`, seq: s.slice(i, i + 3) });
        i += 3;
        continue;
      }
      if (i === s.length - 1) {
        events.push({ type: 'key', value: 'esc' });
        i += 1;
        continue;
      }
      events.push({ type: 'unsupported', label: 'Alt/Meta 组合', seq: s.slice(i, i + 2) });
      i += 2;
      continue;
    }
    if (c === '\x16') {
      // Ctrl+V 控制字节：粘贴由 DOM paste 处理，这里静默，避免刷「协议发不了」。
      flush();
      events.push({ type: 'mouse-silent', seq: c });
      i += 1;
      continue;
    }
    if (code < 32) {
      flush();
      events.push({ type: 'unsupported', label: ctrlLabel(code), seq: c });
      i += 1;
      continue;
    }
    text += c;
    i += 1;
  }
  flush();
  return events;
}

/** KeyboardEvent 里协议表达不了、且不该交给 xterm 再编一串我们仍发不出去的序列。 */
export function unsupportedKeyEvent(ev) {
  if (!ev || ev.type !== 'keydown') return null;
  if (ev.isComposing) return null;
  const k = ev.key;
  if ((ev.ctrlKey || ev.metaKey) && (k === 'v' || k === 'V')) return null;
  if (ev.metaKey) return null; // 其它系统快捷键留给浏览器
  if (k === 'Enter' || k === 'Backspace' || k === 'Tab' || k === 'Escape') return null;
  if (k === 'ArrowUp' || k === 'ArrowDown' || k === 'ArrowLeft' || k === 'ArrowRight') return null;
  if (ev.ctrlKey && (k === 'c' || k === 'C')) return null;
  if (!ev.ctrlKey && !ev.altKey && k.length === 1) return null;
  if (k === 'Shift' || k === 'Control' || k === 'Alt' || k === 'Meta' || k === 'Process') return null;
  if (k === 'Dead') return null;
  if (/^F([1-9]|1[0-2])$/.test(k)) return k;
  if (k === 'Home' || k === 'End' || k === 'PageUp' || k === 'PageDown' || k === 'Insert' || k === 'Delete') return k;
  if (k === 'Tab' && ev.shiftKey) return 'Shift-Tab';
  if (ev.ctrlKey && k.length === 1) return `Ctrl-${k.toUpperCase()}`;
  if (ev.altKey) return `Alt-${k}`;
  return k || 'unknown key';
}

export class NativeInputPump {
  /**
   * @param {Object} hooks
   * @param {(text:string)=>void} hooks.sendText
   * @param {(key:string)=>void} hooks.sendKey
   * @param {()=>void} hooks.sendEnter
   * @param {(label:string)=>void} hooks.onUnsupported
   */
  constructor({ sendText, sendKey, sendEnter, onUnsupported }) {
    this.sendText = sendText;
    this.sendKey = sendKey;
    this.sendEnter = sendEnter;
    this.onUnsupported = onUnsupported;
    this._buf = '';
    this._timer = null;
    this._lastClickHint = 0;
  }

  onData(s) {
    for (const e of parseOnData(s)) {
      if (e.type === 'text') {
        this._buf += e.value;
        if (this._buf.length >= TEXT_FLUSH_CHARS) this.flush();
        else this._arm();
        continue;
      }
      this.flush();
      if (e.type === 'enter') this.sendEnter();
      else if (e.type === 'key') this.sendKey(e.value);
      else if (e.type === 'mouse-silent') continue;
      else if (e.type === 'mouse-click') {
        const now = Date.now();
        if (now - this._lastClickHint < CLICK_HINT_MS) continue;
        this._lastClickHint = now;
        this.onUnsupported(e.label);
      } else this.onUnsupported(e.label);
    }
  }

  flush() {
    clearTimeout(this._timer);
    this._timer = null;
    if (this._buf.length === 0) return;
    const text = this._buf;
    this._buf = '';
    this.sendText(text);
  }

  dispose() {
    this.flush();
  }

  _arm() {
    if (this._timer) return;
    this._timer = setTimeout(() => this.flush(), TEXT_FLUSH_MS);
  }
}
