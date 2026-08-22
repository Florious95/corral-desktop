import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseOnData, NativeInputPump, unsupportedKeyEvent, TEXT_FLUSH_MS, CLICK_HINT_MS, classifyMouseBtn, consumeTerminalReplies } from '../src/term/nativeInput.js';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

test('parseOnData: printable run stays one text event', () => {
  assert.deepEqual(parseOnData('hello'), [{ type: 'text', value: 'hello' }]);
});

test('parseOnData: CR / LF / CRLF are bare enter', () => {
  assert.deepEqual(parseOnData('\r'), [{ type: 'enter' }]);
  assert.deepEqual(parseOnData('\n'), [{ type: 'enter' }]);
  assert.deepEqual(parseOnData('\r\n'), [{ type: 'enter' }]);
});

test('parseOnData: type then enter does not glue', () => {
  assert.deepEqual(parseOnData('hi\r'), [
    { type: 'text', value: 'hi' },
    { type: 'enter' },
  ]);
});

test('parseOnData: closed-set keys', () => {
  assert.deepEqual(parseOnData('\x1b'), [{ type: 'key', value: 'esc' }]);
  assert.deepEqual(parseOnData('\x03'), [{ type: 'key', value: 'ctrl_c' }]);
  assert.deepEqual(parseOnData('\t'), [{ type: 'key', value: 'tab' }]);
  assert.deepEqual(parseOnData('\x7f'), [{ type: 'key', value: 'backspace' }]);
  assert.deepEqual(parseOnData('\b'), [{ type: 'key', value: 'backspace' }]);
  assert.deepEqual(parseOnData('\x1b[A'), [{ type: 'key', value: 'up' }]);
  assert.deepEqual(parseOnData('\x1b[B'), [{ type: 'key', value: 'down' }]);
  assert.deepEqual(parseOnData('\x1b[C'), [{ type: 'key', value: 'right' }]);
  assert.deepEqual(parseOnData('\x1b[D'), [{ type: 'key', value: 'left' }]);
  assert.deepEqual(parseOnData('\x1bOA'), [{ type: 'key', value: 'up' }]);
});

test('parseOnData: unsupported is labeled, not remapped', () => {
  const d = parseOnData('\x04');
  assert.equal(d[0].type, 'unsupported');
  assert.equal(d[0].label, 'Ctrl-D');
  const home = parseOnData('\x1b[H');
  assert.equal(home[0].type, 'unsupported');
  const f1 = parseOnData('\x1bOP');
  assert.equal(f1[0].type, 'unsupported');
  assert.match(f1[0].label, /F1/);
});

test('NativeInputPump merges burst text into one sendText', async () => {
  const sent = [];
  const pump = new NativeInputPump({
    sendText: (t) => sent.push(['text', t]),
    sendKey: (k) => sent.push(['key', k]),
    sendEnter: () => sent.push(['enter']),
    onUnsupported: (l) => sent.push(['no', l]),
  });
  pump.onData('ab');
  pump.onData('c');
  assert.deepEqual(sent, []);
  await sleep(TEXT_FLUSH_MS + 20);
  assert.deepEqual(sent, [['text', 'abc']]);
  pump.dispose();
});

test('NativeInputPump flushes text before enter / keys', () => {
  const sent = [];
  const pump = new NativeInputPump({
    sendText: (t) => sent.push(['text', t]),
    sendKey: (k) => sent.push(['key', k]),
    sendEnter: () => sent.push(['enter']),
    onUnsupported: (l) => sent.push(['no', l]),
  });
  pump.onData('ok\r');
  assert.deepEqual(sent, [['text', 'ok'], ['enter']]);
  pump.onData('\x1b[A');
  assert.deepEqual(sent[2], ['key', 'up']);
  pump.dispose();
});

test('parseOnData: SGR motion 35 is silent, not CSI unsupported', () => {
  const ev = parseOnData('\x1b[<35;30;34M');
  assert.equal(ev.length, 1);
  assert.equal(ev[0].type, 'mouse-silent');
});

test('parseOnData: SGR wheel 64/65 silent; click 0 is mouse-click', () => {
  assert.equal(parseOnData('\x1b[<64;1;1M')[0].type, 'mouse-silent');
  assert.equal(parseOnData('\x1b[<65;1;1m')[0].type, 'mouse-silent');
  const click = parseOnData('\x1b[<0;10;10M');
  assert.equal(click[0].type, 'mouse-click');
  assert.equal(click[0].label, '鼠标点击');
});

test('parseOnData: X10 mouse three-byte report is not printable text', () => {
  const motion = String.fromCharCode(32 + 35, 32 + 8, 32 + 8);
  const ev = parseOnData('\x1b[M' + motion);
  assert.equal(ev.length, 1);
  assert.equal(ev[0].type, 'mouse-silent');
  const click = parseOnData('\x1b[M' + String.fromCharCode(32, 32 + 1, 32 + 1));
  assert.equal(click[0].type, 'mouse-click');
});

test('classifyMouseBtn: 32+ is motion, 64/65 wheel, 0-2 click', () => {
  assert.equal(classifyMouseBtn(35), 'silent');
  assert.equal(classifyMouseBtn(64), 'silent');
  assert.equal(classifyMouseBtn(65), 'silent');
  assert.equal(classifyMouseBtn(0), 'click');
  assert.equal(classifyMouseBtn(2), 'click');
});

test('NativeInputPump: motion does not hint; click hints at most once per window', () => {
  const hints = [];
  const pump = new NativeInputPump({
    sendText: () => {}, sendKey: () => {}, sendEnter: () => {},
    onUnsupported: (l) => hints.push(l),
  });
  pump.onData('\x1b[<35;30;34M');
  pump.onData('\x1b[<35;31;34M');
  pump.onData('\x1b[<64;1;1M');
  assert.deepEqual(hints, []);
  pump.onData('\x1b[<0;2;2M');
  pump.onData('\x1b[<0;3;3M');
  assert.deepEqual(hints, ['鼠标点击']);
  pump.dispose();
});

test('NativeInputPump: Ctrl-D still hints (user key, not mouse noise)', () => {
  const hints = [];
  const pump = new NativeInputPump({
    sendText: () => {}, sendKey: () => {}, sendEnter: () => {},
    onUnsupported: (l) => hints.push(l),
  });
  pump.onData('\x04');
  assert.deepEqual(hints, ['Ctrl-D']);
  pump.dispose();
});

test('unsupportedKeyEvent lets mapped keys through', () => {
  assert.equal(unsupportedKeyEvent({ type: 'keydown', key: 'a' }), null);
  assert.equal(unsupportedKeyEvent({ type: 'keydown', key: 'Enter' }), null);
  assert.equal(unsupportedKeyEvent({ type: 'keydown', key: 'c', ctrlKey: true }), null);
  assert.equal(unsupportedKeyEvent({ type: 'keydown', key: 'd', ctrlKey: true }), 'Ctrl-D');
  assert.equal(unsupportedKeyEvent({ type: 'keydown', key: 'F5' }), 'F5');
  assert.equal(unsupportedKeyEvent({ type: 'keydown', key: 'Home' }), 'Home');
});

const OSC11 = '\x1b]11;rgb:fbfb/fafa/f8f8\x07';

test('bad state: raw parseOnData treats OSC 11 reply as text (and may emit esc)', () => {
  const ev = parseOnData(OSC11);
  const text = ev.filter((e) => e.type === 'text').map((e) => e.value).join('');
  assert.equal(text.includes('11;rgb:fbfb/fafa/f8f8'), true);
  const splitEsc = parseOnData('\x1b');
  assert.deepEqual(splitEsc, [{ type: 'key', value: 'esc' }]);
});

function recordPump() {
  const rec = { text: [], keys: [], enter: 0, unsupported: [] };
  const pump = new NativeInputPump({
    sendText: (t) => rec.text.push(t),
    sendKey: (k) => rec.keys.push(k),
    sendEnter: () => { rec.enter += 1; },
    onUnsupported: (l) => rec.unsupported.push(l),
  });
  return { rec, pump };
}

test('good state: NativeInputPump drops OSC 11 reply — zero uplink', () => {
  const { rec, pump } = recordPump();
  pump.onData(OSC11);
  pump.flush();
  assert.deepEqual(rec, { text: [], keys: [], enter: 0, unsupported: [] });
  pump.dispose();
});

test('good state: split OSC 11 then remainder still zero uplink', () => {
  const { rec, pump } = recordPump();
  pump.onData('\x1b]11;rgb:fbfb');
  pump.onData('/fafa/f8f8\x07');
  pump.flush();
  assert.deepEqual(rec.text, []);
  assert.deepEqual(rec.keys, []);
  pump.dispose();
});

test('consumeTerminalReplies strips DA / CPR / DSR / DCS; keeps arrows and SGR mouse', () => {
  const a = consumeTerminalReplies('\x1b[?1;2c\x1b[24;80R\x1b[0n\x1bP1$r\x1b\\hello\x1b[A');
  assert.equal(a.kept, 'hello\x1b[A');
  assert.equal(a.hold, '');
  const m = consumeTerminalReplies('\x1b[<0;10;10M');
  assert.equal(m.kept, '\x1b[<0;10;10M');
  const right = consumeTerminalReplies('\x1b[C');
  assert.equal(right.kept, '\x1b[C');
});

test('pump still uplinks type / arrows / Ctrl-C / enter', () => {
  const { rec, pump } = recordPump();
  pump.onData('hi');
  pump.flush();
  pump.onData('\x1b[A');
  pump.onData('\x1b[B');
  pump.onData('\x1b[C');
  pump.onData('\x1b[D');
  pump.onData('\x03');
  pump.onData('\r');
  assert.deepEqual(rec.text, ['hi']);
  assert.deepEqual(rec.keys, ['up', 'down', 'right', 'left', 'ctrl_c']);
  assert.equal(rec.enter, 1);
  pump.dispose();
});

