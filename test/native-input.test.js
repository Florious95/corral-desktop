import { test } from 'node:test';
import assert from 'node:assert/strict';
import { parseOnData, NativeInputPump, unsupportedKeyEvent, TEXT_FLUSH_MS, classifyMouseBtn, consumeTerminalReplies } from '../src/term/nativeInput.js';

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

test('immediate text delivery preserves typing, IME and Enter order without a timer', async () => {
  const sent = [];
  const pump = new NativeInputPump({
    deferText: false,
    sendText: t => sent.push(['text', t]),
    sendEnter: () => sent.push(['enter']),
    sendKey: k => sent.push(['key', k]),
  });
  pump.onData('a');
  assert.deepEqual(sent, [['text', 'a']], 'single keystroke is sent in the input turn');
  pump.onData('中文😀\r');
  assert.deepEqual(sent, [['text', 'a'], ['text', '中文😀'], ['enter']]);
  pump.dispose();
  await sleep(TEXT_FLUSH_MS + 10);
  assert.equal(sent.length, 3, 'dispose or a stale timer cannot replay text');
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

test('parseOnData: SGR wheel/right silent; left button is mouse-click', () => {
  assert.equal(parseOnData('\x1b[<64;1;1M')[0].type, 'mouse-silent');
  assert.equal(parseOnData('\x1b[<65;1;1m')[0].type, 'mouse-silent');
  assert.equal(parseOnData('\x1b[<2;1;1M')[0].type, 'mouse-silent');
  const click = parseOnData('\x1b[<0;10;10M');
  assert.equal(click[0].type, 'mouse-click');
  assert.equal(click[0].label, '鼠标点击');
  assert.equal(parseOnData('\x1b[<0;10;10m')[0].type, 'mouse-click');
});

test('parseOnData: X10 mouse three-byte report is not printable text', () => {
  const motion = String.fromCharCode(32 + 35, 32 + 8, 32 + 8);
  const ev = parseOnData('\x1b[M' + motion);
  assert.equal(ev.length, 1);
  assert.equal(ev[0].type, 'mouse-silent');
  const click = parseOnData('\x1b[M' + String.fromCharCode(32, 32 + 1, 32 + 1));
  assert.equal(click[0].type, 'mouse-click');
  const right = parseOnData('\x1b[M' + String.fromCharCode(32 + 2, 32 + 1, 32 + 1));
  assert.equal(right[0].type, 'mouse-silent');
});

test('classifyMouseBtn: only left button (including modifiers) is click', () => {
  assert.equal(classifyMouseBtn(35), 'silent');
  assert.equal(classifyMouseBtn(64), 'silent');
  assert.equal(classifyMouseBtn(65), 'silent');
  assert.equal(classifyMouseBtn(0), 'click');
  assert.equal(classifyMouseBtn(4), 'click');
  assert.equal(classifyMouseBtn(2), 'silent');
  assert.equal(classifyMouseBtn(3), 'silent');
  for (let modifiers = 0; modifiers < 32; modifiers += 4) {
    assert.equal(classifyMouseBtn(32 + modifiers), 'click', 'left drag is input');
    for (const button of [33, 34, 35, 64, 65, 128]) {
      assert.equal(classifyMouseBtn(button + modifiers), 'silent');
    }
  }
});

test('NativeInputPump preserves complete SGR and X10 left drag gestures across chunk boundaries', () => {
  for (const protocol of ['sgr', 'x10']) {
    const report = (button, row, release = false) => protocol === 'sgr'
      ? `\x1b[<${button};100;${row}${release ? 'm' : 'M'}`
      : '\x1b[M' + String.fromCharCode(button + 32, 132, row + 32);
    const gesture = [report(0, 100), report(32, 101), report(32, 102),
      report(protocol === 'sgr' ? 0 : 3, 102, true)];
    const input = gesture.join('');
    for (let split = 1; split < input.length; split++) {
      const sent = [];
      const pump = new NativeInputPump({
        sendText: () => assert.fail('mouse bytes became text'),
        sendKey: () => assert.fail('mouse bytes became keys'),
        sendEnter: () => assert.fail('mouse bytes became enter'),
        sendBytes: (bytes) => sent.push(...bytes),
        onUnsupported: () => assert.fail('drag is supported'),
      });
      const inputMethod = protocol === 'sgr' ? 'onData' : 'onBinary';
      pump[inputMethod](input.slice(0, split));
      pump[inputMethod](input.slice(split));
      assert.deepEqual(sent, Array.from(input, (char) => char.charCodeAt(0)), `${protocol} split ${split}`);
      pump.dispose();
    }
  }
});

test('NativeInputPump forwards SGR left click bytes and blocks right click', () => {
  const sent = [];
  const hints = [];
  const pump = new NativeInputPump({
    sendText: () => {}, sendKey: () => {}, sendEnter: () => {},
    sendBytes: (bytes) => sent.push(new TextDecoder().decode(bytes)),
    onUnsupported: (l) => hints.push(l),
  });
  const leftPress = '\x1b[<0;2;2M';
  const leftRelease = '\x1b[<0;2;2m';
  const modified = [4, 8, 16].flatMap((button) => [
    `\x1b[<${button};3;3M`,
    `\x1b[<${button};3;3m`,
  ]);
  pump.onData(leftPress);
  pump.onData(leftRelease);
  for (const seq of modified) pump.onData(seq);
  pump.onData('\x1b[<2;2;2M');
  pump.onData('\x1b[<2;2;2m');
  pump.onData('\x1b[<3;2;2M');
  pump.onData('\x1b[<3;2;2m');
  pump.onData('\x1b[<64;2;2M');
  assert.deepEqual(sent, [leftPress, leftRelease, ...modified]);
  assert.deepEqual(hints, []);
  pump.dispose();
});

test('NativeInputPump forwards X10 left press/release but blocks right/release reports', () => {
  const sent = [];
  const pump = new NativeInputPump({
    sendText: () => {}, sendKey: () => {}, sendEnter: () => {},
    sendBytes: (bytes) => sent.push(bytes),
    onUnsupported: () => { throw new Error('blocked mouse must not hint'); },
  });
  const left = '\x1b[M' + String.fromCharCode(32, 33, 34);
  const middle = '\x1b[M' + String.fromCharCode(33, 33, 34);
  const right = '\x1b[M' + String.fromCharCode(34, 33, 34);
  const release = '\x1b[M' + String.fromCharCode(35, 33, 34);
  const wheel = '\x1b[M' + String.fromCharCode(96, 33, 34);
  const highCoordinateLeft = '\x1b[M' + String.fromCharCode(32, 200, 201);
  pump.onData(left);
  pump.onData(release);
  pump.onData(middle);
  pump.onData(release);
  pump.onData(right);
  pump.onData(release);
  pump.onData(wheel);
  pump.onBinary(highCoordinateLeft);
  assert.deepEqual(sent.slice(0, 2).map((bytes) => new TextDecoder().decode(bytes)), [left, release]);
  assert.deepEqual(Array.from(sent[2]), [27, 91, 77, 32, 200, 201]);
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

test('unsupportedKeyEvent lets intentional terminal keys through to xterm', () => {
  assert.equal(unsupportedKeyEvent({ type: 'keydown', key: 'a' }), null);
  assert.equal(unsupportedKeyEvent({ type: 'keydown', key: 'Enter' }), null);
  assert.equal(unsupportedKeyEvent({ type: 'keydown', key: 'c', ctrlKey: true }), null);
  assert.equal(unsupportedKeyEvent({ type: 'keydown', key: 'd', ctrlKey: true }), null);
  assert.equal(unsupportedKeyEvent({ type: 'keydown', key: 'F5' }), null);
  assert.equal(unsupportedKeyEvent({ type: 'keydown', key: 'Home' }), null);
});

test('NativeInputPump uplinks intentional non-text keys via sendBytes', () => {
  const sent = [];
  const pump = new NativeInputPump({
    sendText: () => {},
    sendKey: () => {},
    sendEnter: () => {},
    sendBytes: (bytes) => sent.push(bytes),
    onUnsupported: () => {},
  });
  for (const sequence of ['\x01', '\x05', '\x12', '\x04', '\x1b[H', '\x1b[F', '\x1b[3~', '\x1bOP', '\x1b[15~', '\x1b[Z', '\x1bx']) {
    pump.onData(sequence);
  }
  assert.deepEqual(sent.map((bytes) => new TextDecoder().decode(bytes)), [
    '\x01', '\x05', '\x12', '\x04', '\x1b[H', '\x1b[F', '\x1b[3~', '\x1bOP', '\x1b[15~', '\x1b[Z', '\x1bx',
  ]);
  pump.dispose();
});

test('NativeInputPump preserves split escape sequences and order', () => {
  const sent = [];
  const pump = new NativeInputPump({
    sendText: () => {},
    sendKey: () => {},
    sendEnter: () => sent.push('enter'),
    sendBytes: (bytes) => sent.push(new TextDecoder().decode(bytes)),
    onUnsupported: () => {},
  });
  pump.onData('\x1b');
  pump.onData('[');
  pump.onData('15~');
  pump.onData('\r');
  assert.deepEqual(sent, ['\x1b[15~', 'enter']);
  pump.dispose();
});

test('NativeInputPump keeps a bare Escape as the named key', async () => {
  const keys = [];
  const bytes = [];
  const pump = new NativeInputPump({
    sendText: () => {},
    sendKey: (key) => keys.push(key),
    sendEnter: () => {},
    sendBytes: (value) => bytes.push(value),
    onUnsupported: () => {},
  });
  pump.onData('\x1b');
  await sleep(TEXT_FLUSH_MS + 20);
  assert.deepEqual(keys, ['esc']);
  assert.deepEqual(bytes, []);
  pump.dispose();
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
