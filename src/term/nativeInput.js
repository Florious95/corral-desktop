/*
 * xterm onData → protocol input.text / input.keys / input.bytes (CLIENT-CONTRACT §0.3 / §3.5).
 * 不把 keydown 映射成字符；只吃 xterm 已经编好的输入，协议不认识的序列走 bytes。
 */

export const TEXT_FLUSH_MS = 32;
export const TEXT_FLUSH_CHARS = 64;
/** @deprecated clicks are now forwarded as bytes; retained for import compatibility. */
export const CLICK_HINT_MS = 3000;
const ARROW = { A: 'up', B: 'down', C: 'right', D: 'left' };

export const REPLY_HOLD_MAX = 8192;

const encoder = new TextEncoder();
const toBytes = (value) => encoder.encode(value);
// X10 stores each report byte in one JS code unit; do not UTF-8-expand coordinates > 127.
const toMouseBytes = (value) => Uint8Array.from(value, (char) => char.charCodeAt(0) & 0xff);
const binaryString = (value) => {
  if (typeof value === 'string') return value;
  if (!value || typeof value.length !== 'number') return '';
  let raw = '';
  for (let i = 0; i < value.length; i += 1) raw += String.fromCharCode(value[i] & 0xff);
  return raw;
};

function findStringTerm(buf, from) {
  for (let j = from; j < buf.length; j += 1) {
    if (buf.charCodeAt(j) === 0x07) return j + 1;
    if (buf[j] === '\x1b' && buf[j + 1] === '\\') return j + 2;
  }
  return -1;
}

function readCsi(buf, i) {
  let j = i + 2;
  if (j >= buf.length) return { incomplete: true };
  while (j < buf.length) {
    const cc = buf.charCodeAt(j);
    if (cc >= 0x30 && cc <= 0x3f) { j += 1; continue; }
    break;
  }
  while (j < buf.length) {
    const cc = buf.charCodeAt(j);
    if (cc >= 0x20 && cc <= 0x2f) { j += 1; continue; }
    break;
  }
  if (j >= buf.length) return { incomplete: true };
  const fin = buf.charCodeAt(j);
  if (fin < 0x40 || fin > 0x7e) return { incomplete: true };
  return { seq: buf.slice(i, j + 1), next: j + 1, fin: buf[j] };
}

/**
 * Drop xterm automatic replies so they never become input.text / keys.
 * Keep user keys: CSI … A/B/C/D (arrows) vs CPR `…R`, DA `…c`, DSR `…n`.
 * Incomplete OSC/DCS/CSI at the tail goes to `hold` (caller concatenates).
 */
export function consumeTerminalReplies(chunk, hold = '') {
  const buf = hold + (typeof chunk === 'string' ? chunk : '');
  let kept = '';
  let i = 0;
  while (i < buf.length) {
    if (buf[i] !== '\x1b') {
      kept += buf[i];
      i += 1;
      continue;
    }
    if (i + 1 >= buf.length) return { kept: kept + buf[i], hold: '' };
    const n = buf[i + 1];
    if (n === ']' || n === 'P') {
      const end = findStringTerm(buf, i + 2);
      if (end < 0) return { kept, hold: buf.slice(i) };
      i = end;
      continue;
    }
    if (n === '[') {
      const csi = readCsi(buf, i);
      if (csi.incomplete) return { kept, hold: buf.slice(i) };
      if (csi.fin === 'c' || csi.fin === 'n' || csi.fin === 'R') {
        i = csi.next;
        continue;
      }
      kept += csi.seq;
      i = csi.next;
      continue;
    }
    kept += buf[i];
    i += 1;
  }
  return { kept, hold: '' };
}

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
 * 鼠标协议分类：只把左键（SGR button 0）作为可直通 PTY 的点击。
 * 右键/中键、滚轮与移动报告都拦截；滚轮仍由 scroll_wheel 独立处理。
 * SGR 的修饰位（4/8/16）仍保留左键语义，X10 的 release code 3 不带按键归属，故不转发。
 * @returns {'silent'|'click'}
 */
export function classifyMouseBtn(btn) {
  if (!Number.isFinite(btn)) return 'silent';
  if (btn >= 32) return 'silent';
  return (btn & 3) === 0 ? 'click' : 'silent';
}

function mouseEvent(kind, seq) {
  if (kind === 'click') return { type: 'mouse-click', label: '鼠标点击', seq };
  return { type: 'mouse-silent', seq };
}

/**
 * @param {string} s xterm onData payload
 * @returns {Array<{type:'text',value:string}|{type:'enter'}|{type:'key',value:string}|{type:'unsupported',label:string,seq:string}>}
 */
export function parseOnData(s, { holdIncomplete = false } = {}) {
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
          if (holdIncomplete) events.push({ type: 'incomplete', seq: s.slice(i) });
          else events.push(mouseEvent('silent', s.slice(i)));
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
            if (holdIncomplete) events.push({ type: 'incomplete', seq: s.slice(i) });
            else events.push(mouseEvent('silent', s.slice(i)));
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
        if (holdIncomplete) events.push({ type: 'incomplete', seq: s.slice(i) });
        else events.push({ type: 'unsupported', label: 'incomplete escape', seq: s.slice(i) });
        break;
      }
      if (s[i + 1] === 'O') {
        if (i + 2 >= s.length) {
          if (holdIncomplete) events.push({ type: 'incomplete', seq: s.slice(i) });
          else events.push({ type: 'unsupported', label: 'incomplete escape', seq: s.slice(i) });
          break;
        }
        const f = s[i + 2];
        if (ARROW[f]) events.push({ type: 'key', value: ARROW[f] });
        else events.push({ type: 'unsupported', label: f >= 'P' && f <= 'S' ? `F${f.charCodeAt(0) - 79}` : `SS3 ${f}`, seq: s.slice(i, i + 3) });
        i += 3;
        continue;
      }
      if (i === s.length - 1) {
        if (holdIncomplete) events.push({ type: 'incomplete', seq: s.slice(i) });
        else events.push({ type: 'key', value: 'esc' });
        break;
      }
      events.push({ type: 'unsupported', label: 'Alt/Meta 组合', seq: s.slice(i, i + 2) });
      i += 2;
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

/** Deprecated compatibility hook: Cmd+B is no longer consumed by the desktop shell. */
export function isLocalSidebarToggle() { return false; }

/** Deprecated compatibility hook: xterm's encoded data is always allowed through. */
export function unsupportedKeyEvent() { return null; }

export class NativeInputPump {
  /**
   * @param {Object} hooks
   * @param {(text:string)=>void} hooks.sendText
   * @param {(key:string)=>void} hooks.sendKey
   * @param {(bytes:Uint8Array)=>void} hooks.sendBytes
   * @param {()=>void} hooks.sendEnter
   * @param {(label:string)=>void} hooks.onUnsupported
   */
  constructor({ sendText, sendKey, sendBytes, sendEnter, onUnsupported }) {
    this.sendText = sendText;
    this.sendKey = sendKey;
    this.sendBytes = sendBytes;
    this.sendEnter = sendEnter;
    this.onUnsupported = onUnsupported || (() => {});
    this._buf = '';
    this._timer = null;
    this._inputTimer = null;
    this._inputHold = '';
    this._replyHold = '';
    this._x10Button = null;
  }

  onData(s) {
    const raw = this._inputHold + (typeof s === 'string' ? s : '');
    this._inputHold = '';
    clearTimeout(this._inputTimer);
    this._inputTimer = null;
    const stripped = consumeTerminalReplies(raw, this._replyHold);
    this._replyHold = stripped.hold.length > REPLY_HOLD_MAX ? '' : stripped.hold;
    if (stripped.kept.length === 0) return;
    for (const e of parseOnData(stripped.kept, { holdIncomplete: true })) {
      if (e.type === 'incomplete') {
        this._inputHold = e.seq;
        this._armInputHold();
        continue;
      }
      if (e.type === 'text') {
        this._buf += e.value;
        if (this._buf.length >= TEXT_FLUSH_CHARS) this.flush();
        else this._arm();
        continue;
      }
      this.flush();
      if (e.type === 'enter') this.sendEnter();
      else if (e.type === 'key') this.sendKey(e.value);
      else if (e.type === 'mouse-silent') {
        // X10 release (button 3) has no button identity. Forward it only when
        // the matching X10 press we saw was left; right/middle releases stay blocked.
        if (e.seq?.startsWith('\x1b[M')) {
          const button = e.seq.length >= 4 ? e.seq.charCodeAt(3) - 32 : NaN;
          if (button === 1 || button === 2) this._x10Button = 'blocked';
          else if (button === 3) {
            const wasLeft = this._x10Button === 'left';
            this._x10Button = null;
            if (wasLeft) {
              if (this.sendBytes) this.sendBytes(toMouseBytes(e.seq));
              else this.onUnsupported('鼠标点击');
            }
          }
        }
      } else if (e.type === 'mouse-click') {
        if (e.seq?.startsWith('\x1b[M')) this._x10Button = 'left';
        if (this.sendBytes) this.sendBytes(toMouseBytes(e.seq));
        else this.onUnsupported(e.label);
      } else if (this.sendBytes) this.sendBytes(toBytes(e.seq));
      else this.onUnsupported(e.label);
    }
  }

  onBinary(data) {
    const raw = binaryString(data);
    if (raw.length > 0) this.onData(raw);
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
    clearTimeout(this._inputTimer);
    this._inputTimer = null;
    const hold = this._inputHold;
    this._inputHold = '';
    this._replyHold = '';
    if (hold) {
      this.flush();
      if (hold === '\x1b') this.sendKey('esc');
      else if (this.sendBytes) this.sendBytes(toBytes(hold));
      else this.onUnsupported('incomplete escape');
    }
    this.flush();
  }

  _arm() {
    if (this._timer) return;
    this._timer = setTimeout(() => this.flush(), TEXT_FLUSH_MS);
  }

  _armInputHold() {
    clearTimeout(this._inputTimer);
    this._inputTimer = setTimeout(() => {
      this._inputTimer = null;
      const hold = this._inputHold;
      this._inputHold = '';
      if (!hold) return;
      this.flush();
      if (hold === '\x1b') this.sendKey('esc');
      else if (this.sendBytes) this.sendBytes(toBytes(hold));
      else this.onUnsupported('incomplete escape');
    }, TEXT_FLUSH_MS);
  }
}
