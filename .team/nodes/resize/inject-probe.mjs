#!/usr/bin/env node
/**
 * paste-buffer -d -p + Enter（对齐 daemon Inject 多行路径）.
 * 提交量具：pane 里的 python 把每行写到 got.log，不靠 24 行 capture 窗口。
 */
import { spawnSync } from 'node:child_process';
import { writeFileSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const sock = join(here, 'ts');
const gotLog = join(here, 'got.log');
const py = join(here, 'tui-reader.py');
const N = 20;

const sleep = (ms) => spawnSync('sleep', [String(ms / 1000)]);

const tmux = (...args) => {
  const r = spawnSync('tmux', ['-S', sock, ...args], { encoding: 'utf8' });
  return { rc: r.status ?? 1, out: r.stdout || '', err: r.stderr || '' };
};

writeFileSync(py, `import sys, signal, tty, termios

log = open(sys.argv[1], "a", encoding="utf-8")
buf = []

def redraw():
    sys.stdout.write("\\r\\x1b[2K> " + "".join(buf))
    sys.stdout.flush()

def on_winch(_s, _f):
    buf.clear()
    redraw()

signal.signal(signal.SIGWINCH, on_winch)
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setcbreak(fd)
try:
    redraw()
    while True:
        ch = sys.stdin.read(1)
        if not ch:
            break
        if ch in ("\\n", "\\r"):
            line = "".join(buf)
            buf.clear()
            if line:
                log.write("GOT:" + line + "\\n")
                log.flush()
                sys.stdout.write("\\nGOT:" + line + "\\n")
            redraw()
        elif ch == "\\x7f":
            if buf:
                buf.pop()
            redraw()
        else:
            buf.append(ch)
            redraw()
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
`);

function killServer() {
  spawnSync('tmux', ['-S', sock, 'kill-server'], { encoding: 'utf8' });
}

function startSession() {
  killServer();
  writeFileSync(gotLog, '');
  const r = tmux(
    'new-session', '-d', '-s', 'probe', '-x', '80', '-y', '24', '--',
    'python3', py, gotLog,
  );
  if (r.rc !== 0) throw new Error(`new-session ${r.err || r.out}`);
  const list = tmux('list-sessions');
  if (list.rc !== 0) throw new Error(`list-sessions ${list.err}`);
  sleep(300);
}

function inject(n, { resizeBetween } = {}) {
  const marker = `AM-PROBE-${n}`;
  const load = spawnSync('tmux', ['-S', sock, 'load-buffer', '-'], {
    encoding: 'utf8',
    input: marker,
  });
  if ((load.status ?? 1) !== 0) throw new Error(`load-buffer ${load.stderr}`);
  const p = tmux('paste-buffer', '-d', '-t', 'probe');
  if (p.rc !== 0) throw new Error(`paste-buffer ${p.err}`);
  if (resizeBetween) {
    tmux('set-option', '-w', '-t', 'probe', 'window-size', 'latest');
    tmux('resize-window', '-t', 'probe', '-x', '48', '-y', '18');
    tmux('resize-window', '-t', 'probe', '-x', '80', '-y', '24');
  }
  const e = tmux('send-keys', '-t', 'probe', 'Enter');
  if (e.rc !== 0) throw new Error(`Enter ${e.err}`);
}

function score() {
  const text = readFileSync(gotLog, 'utf8');
  let ok = 0;
  const missing = [];
  for (let i = 1; i <= N; i++) {
    if (text.includes(`GOT:AM-PROBE-${i}`)) ok += 1;
    else missing.push(i);
  }
  const cap = tmux('capture-pane', '-t', 'probe', '-p', '-J', '-S', '-80');
  return { ok, missing, log: text, capture: cap.out };
}

function runCase(name, opts, extraAttach) {
  startSession();
  if (extraAttach) {
    const a = tmux(
      'new-session', '-d', '-s', 'tiny', '-x', '40', '-y', '12', '--',
      'tmux', '-S', sock, 'attach-session', '-t', 'probe',
    );
    if (a.rc !== 0) throw new Error(`tiny attach ${a.err}`);
    sleep(400);
  }
  for (let i = 1; i <= N; i++) {
    inject(i, opts);
    sleep(80);
  }
  sleep(250);
  const s = score();
  killServer();
  return { name, n: N, submitted: s.ok, failRate: (N - s.ok) / N, missing: s.missing, log: s.log, capture: s.capture };
}

const control = runCase('control_no_attach_no_resize', {});
const attached = runCase('attach_same_session', {}, true);
const resized = runCase('resize_between_paste_and_enter', { resizeBetween: true });

function windowSize() {
  return tmux('display-message', '-t', 'probe', '-p', '#{window_width}x#{window_height}').out.trim();
}

function geomRecovery() {
  startSession();
  const desktop = windowSize();
  tmux('resize-window', '-t', 'probe', '-x', '40', '-y', '12');
  sleep(120);
  const afterPhone = windowSize();
  sleep(200);
  const stillSmall = windowSize();
  tmux('resize-window', '-t', 'probe', '-x', '80', '-y', '24');
  sleep(120);
  const afterReassert = windowSize();
  const capSmall = (() => {
    tmux('resize-window', '-t', 'probe', '-x', '40', '-y', '12');
    sleep(80);
    return tmux('capture-pane', '-t', 'probe', '-p', '-J').out;
  })();
  killServer();
  return { desktop, afterPhone, stillSmall, afterReassert, capSmall };
}

const geom = geomRecovery();

const report = { n: N, control, attached, resized, geom };
writeFileSync(join(here, 'inject-probe.json'), JSON.stringify(report, null, 2));
writeFileSync(join(here, 'inject-control.capture.txt'), control.capture);
writeFileSync(join(here, 'inject-attached.capture.txt'), attached.capture);
writeFileSync(join(here, 'inject-resized.capture.txt'), resized.capture);
writeFileSync(join(here, 'geom-small.capture.txt'), geom.capSmall);
console.log(JSON.stringify({
  control: { submitted: control.submitted, failRate: control.failRate, missing: control.missing },
  attached: { submitted: attached.submitted, failRate: attached.failRate, missing: attached.missing },
  resized: { submitted: resized.submitted, failRate: resized.failRate, missing: resized.missing },
  geom,
}));
