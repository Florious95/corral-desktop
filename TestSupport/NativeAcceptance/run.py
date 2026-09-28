#!/usr/bin/env python3
"""Packaged native app -> real isolated agentmirrord -> private tmux PTYs.
AppKit events stay in the app; captures use only its exact WindowServer ID.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import socket
import subprocess
import tempfile
import time
import traceback

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent


def wait_for(fn, timeout=20):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = fn()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError('Timed out waiting for condition')


class Run:
    def __init__(self, legacy):
        self.legacy = legacy
        self.directory = Path(tempfile.mkdtemp(prefix='corral-native-acceptance-', dir='/tmp')).resolve()
        self.nonce = secrets.token_hex(4).upper()
        self.processes = []
        self.command_id = 0
        self.receipts = []
        self.socket = self.directory / ('tmux-'+str(os.getuid())) / 'acceptance'
        self.refs = {}

    def start_process(self, args, env, name):
        log = open(self.directory / (name + '.log'), 'wb')
        process = subprocess.Popen(args, env=env, stdout=log, stderr=subprocess.STDOUT)
        self.processes.append(process)
        return process

    def tmux(self, *args):
        return subprocess.check_output(['/opt/homebrew/bin/tmux', '-S', str(self.socket), *args], text=True).strip()

    def start(self):
        runtime = ROOT / 'TestSupport/Fixtures/runtime/nodeprobe'
        self.socket.parent.mkdir(mode=0o700)
        helper = self.directory / 'helpers'
        helper.mkdir()
        adapter = helper / 'tmux-format.py'
        adapter.write_text('''#!/usr/bin/python3
import os, subprocess, sys
args = sys.argv[1:]
scopes = [(args[i], args[i+1]) for i in range(len(args)-1) if args[i] in ('-S', '-L')]
if scopes != [('-S', %r)]: raise SystemExit(64)
if 'list-panes' in args and '-F' in args and '\\x1f' in args[args.index('-F')+1]:
    i = args.index('-F')+1
    args[i] = args[i].replace('\\x1f', '|')
    p = subprocess.run(['/opt/homebrew/bin/tmux', *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    sys.stdout.buffer.write(p.stdout.replace(b'|', b'\\x1f'))
    sys.stderr.buffer.write(p.stderr)
    raise SystemExit(p.returncode)
os.execv('/opt/homebrew/bin/tmux', ['tmux', *args])
''' % str(self.socket))
        wrapper = helper / 'tmux'
        wrapper.write_text('#!/bin/sh\n'
            '[ "$1" = "-S" ] && [ "$2" = '+shlex.quote(str(self.socket))+' ] || exit 64\n'
            'case "$*" in *\'\x1f\'*) exec /usr/bin/python3 '+shlex.quote(str(adapter))+' "$@";; esac\n'
            'exec /opt/homebrew/bin/tmux "$@"\n')
        wrapper.chmod(0o700)
        agent = self.directory / 'codex'
        subprocess.run(['clang', '-D_DARWIN_C_SOURCE', '-Os', str(HERE / 'terminal-fixture.c'), '-o', str(agent)], check=True)
        for suffix in 'ABCD':
            session = f'ACCEPT-{suffix}-{self.nonce}'
            self.tmux('new-session', '-d', '-s', session, '-x', '110', '-y', '32', '-c', str(self.directory),
                      str(agent), suffix, self.nonce, str(self.directory / f'input-{suffix}.bin'))
            self.tmux('set-option', '-t', session, 'status', 'off')
            self.tmux('select-pane', '-t', session, '-T', session)
        self.refs = {name.split('-')[1]: str(self.socket) + "\x1f" + ref for ref, name in
                     (line.split('\t') for line in self.tmux('list-panes', '-a', '-F', '#{pane_id}\t#{session_name}').splitlines())}
        token = secrets.token_hex(32)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        assert port != 9900
        env = {k: v for k, v in os.environ.items() if k in ('LANG', 'LC_CTYPE', 'LC_ALL', 'TMPDIR')}
        env.update(PATH=str(helper)+':/usr/bin:/bin:/opt/homebrew/bin',
                   AGENTMIRROR_TOKEN=token, AGENTMIRROR_NODEPROBE_BIN=str(runtime / 'nodeprobe'),
                   NODEPROBE_FIXTURES=str(runtime / 'titles.tsv'), NODEPROBE_PROVIDERS=str(runtime / 'providers.tsv'),
                   AGENTMIRROR_NODEPROBE_PI_EXTENSION=str(runtime / 'nodeprobe-pi-activity.js'),
                   AGENTMIRROR_E2E_DISCOVERY_SOCKET_DIRS=str(self.socket.parent))
        daemon = ROOT / '.build/native-acceptance-server/agentmirrord'
        server_identity = json.loads(daemon.with_name('build.json').read_text())
        assert server_identity['commit'] == 'a472d4437885060bc0eaf1838c9149e5242948cb'
        assert hashlib.sha256(daemon.read_bytes()).hexdigest() == server_identity['sha256']
        daemon_process = self.start_process([str(daemon), '-listen', f'127.0.0.1:{port}', '-state-dir', str(self.directory / 'server-state'),
                                            '-upload-dir', str(self.directory / 'uploads')], env, 'daemon')
        def listening():
            assert daemon_process.poll() is None, 'isolated daemon exited; see daemon.log'
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1): return True
            except OSError: return False
        wait_for(listening)
        proxy_env = dict(env, CORRAL_WEB_PACKAGE=str(self.legacy / 'package.json'),
                         CORRAL_ACCEPTANCE_RUN=str(self.directory), CORRAL_ACCEPTANCE_DAEMON_PORT=str(port))
        self.start_process(['node', str(HERE / 'wire-proxy.mjs')], proxy_env, 'proxy')
        wait_for(lambda: (self.directory / 'proxy-port').exists())
        proxy_port = int((self.directory / 'proxy-port').read_text())
        assert proxy_port != 9900
        app_env = dict(os.environ, CORRAL_NATIVE_ACCEPTANCE_DIRECTORY=str(self.directory), CORRAL_NATIVE_BACKGROUND='1',
                       CORRAL_NATIVE_ENDPOINT=f'ws://127.0.0.1:{proxy_port}/ws', CORRAL_NATIVE_TOKEN=token)
        app_env.pop('CORRAL_NATIVE_NO_RESIZE', None)
        app = ROOT / '.build/CorralNativeDev.app/Contents/MacOS/CorralApp'
        self.app = self.start_process([str(app)], app_env, 'app')
        self.identity = {'app': str(app), 'appSHA256': hashlib.sha256(app.read_bytes()).hexdigest(),
                         'baseHEAD': subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT, text=True).strip(),
                         'sourceTree': subprocess.check_output(['git','rev-parse','HEAD^{tree}'], cwd=ROOT, text=True).strip(),
                         'worktreeStatus': subprocess.check_output(['git','status','--porcelain'], cwd=ROOT, text=True),
                         'runnerSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                         'server': server_identity, 'daemonPort': port, 'clientPort': proxy_port, 'tmuxSocket': str(self.socket), 'refs': self.refs,
                         'origin': 'appkit-synthetic', 'systemHID': 'NOT-RUN', 'nativeOSDragTracking': 'NOT-RUN'}
        print(f'RUN_DIR={self.directory}', flush=True)
        wait_for(lambda: self.command('state').get('connected'), 25)
        self.state = wait_for(lambda: self.ready_state(), 25)
        print('APP_CONNECTED', json.dumps(self.state['agents']), flush=True)

    def ready_state(self):
        state = self.command('state')
        return state if len(state['agents']) == 4 and any(self.nonce in '\n'.join(p['rows']) for p in state['panes']) else None

    def command(self, op, **kwargs):
        self.command_id += 1
        data = {'id': self.command_id, 'op': op, **kwargs}
        path = self.directory / 'command.json'
        temporary = self.directory / 'command.tmp'
        temporary.write_text(json.dumps(data))
        temporary.replace(path)
        result_path = self.directory / 'result.json'
        def get():
            assert self.app.poll() is None, 'packaged app exited'
            if not result_path.exists(): return None
            result = json.loads(result_path.read_text())
            return result if result.get('id') == self.command_id else None
        result = wait_for(get, 25)
        self.receipts.append({'command': data, 'reply': result})
        (self.directory / 'commands.json').write_text(json.dumps(self.receipts, ensure_ascii=False, indent=2))
        assert result['ok'], result
        return result['state']

    def capture(self, name, state):
        path = self.directory / (name + '.png')
        subprocess.run(['screencapture', '-l', str(state['windowID']), '-o', '-x', str(path)], check=True)
        return path

    def session_id(self, suffix):
        return next(a['id'] for a in self.command('state')['agents'] if a['id'].endswith(self.refs[suffix]))

    def view(self, state, suffix, visible=True):
        return next(p for p in state['panes'] if p['ref'] == self.refs[suffix] and (not visible or not p['hidden']))

    def visible(self, suffix):
        def get():
            state = self.command('state')
            panes = [p for p in state['panes'] if not p['hidden'] and p['ref'] == self.refs[suffix]]
            return state if panes and self.nonce in '\n'.join(panes[0]['rows']) else None
        return wait_for(get)

    def sidebar(self, suffix, **kwargs):
        self.command('sidebar', session=self.session_id(suffix), **kwargs)
        return self.visible(suffix)

    def wire(self):
        return [json.loads(line) for line in (self.directory / 'wire.jsonl').read_text().splitlines()]

    def settle_geometry(self, state):
        expected = {p['ref'].split('\x1f')[-1]: (p['cols'], len(p['rows']))
                    for p in state['panes'] if not p['hidden']}
        def matches():
            actual = {ref: (int(cols), int(rows)) for ref, cols, rows in
                      (line.split('\t') for line in self.tmux('list-panes','-a','-F','#{pane_id}\t#{pane_width}\t#{pane_height}').splitlines())}
            return all(actual.get(ref) == size for ref, size in expected.items())
        start = time.monotonic()
        wait_for(matches, 30)
        self.receipts.append({'realPTYGeometry': expected, 'settleSeconds': time.monotonic()-start})

    def output_assertion(self, screenshot, suffix):
        output = subprocess.check_output(['swift', str(HERE / 'recognize.swift'), str(screenshot)], text=True)
        lines = json.loads(output)
        (screenshot.with_suffix('.ocr.json')).write_text(json.dumps(lines, indent=2))
        # Vision can return Cyrillic homoglyphs for these identical Latin glyphs.
        # Session A/B/C/D remain distinct; the stale-A negative control uses this
        # exact same normalization and must still reject the wrong session.
        homographs = str.maketrans({'А':'A','В':'B','С':'C','Е':'E','З':'3','О':'0','Ø':'0','O':'0'})
        matched = any(suffix + '/' + self.nonce in ''.join(line.split()).upper().translate(homographs) for line in lines)
        assert matched, {'expected': suffix + '/' + self.nonce, 'ocr': lines}
        return lines

    def run_suite(self):
        from PIL import Image, ImageChops
        state = self.visible('A')
        host = state['workspace']['tabs'][0]
        first = self.capture('session-A', state)
        self.output_assertion(first, 'A')
        state = self.sidebar('B', jitter=.2)
        assert state['previewUID'] == self.session_id('B')
        assert state['workspace']['tabs'] == [host], 'preview must preserve host root/title/focus'
        second = self.capture('preview-B', state)
        self.output_assertion(second, 'B')
        try:
            self.output_assertion(first, 'B')
        except AssertionError:
            self.receipts.append({'negativeControl': 'A image cannot satisfy B marker', 'result': 'EXPECTED_RED'})
        else: raise AssertionError('session image negative control did not reject stale A')
        assert any(e.get('type') == 'subscribe' and e['payload']['ref'] == self.refs['B'] for e in self.wire())
        pane = self.view(state, 'B')
        assert state['backingScale'] == pane['contentsScale'] == 2
        assert pane['font'] == 'Menlo-Regular' and pane['pointSize'] == 13
        x, y, _, _ = map(round, pane['pixelROI'])
        # Fixed 80-column x 25-row text sample at default Menlo 13pt, 2x. No resampling.
        roi = Image.open(second).crop((x, y, x+1280, y+800))
        roi_path = self.directory / 'retina-text-roi.png'
        roi.save(roi_path)
        verifier = self.legacy / 'scripts/verify_font_sharpness.py'
        sharp = subprocess.run(['python3', str(verifier), str(roi_path)], capture_output=True, text=True)
        (self.directory / 'sharpness.json').write_text(sharp.stdout)
        assert sharp.returncode == 0, sharp.stdout
        # Negative control changes only the captured image, never the pass thresholds.
        blurry = self.directory / 'retina-negative-1x.png'
        roi.resize((640,400), Image.Resampling.BILINEAR).resize((1280,800), Image.Resampling.BILINEAR).save(blurry)
        red = subprocess.run(['python3', str(verifier), str(blurry)], capture_output=True, text=True)
        (self.directory / 'sharpness-negative.json').write_text(red.stdout)
        assert red.returncode == 1, '1x interpolated capture must fail the unchanged sharpness gate'
        print('PASS preview A->B WindowServer/OCR, Retina, negative controls', flush=True)
        self.command('exit-preview')
        state = self.visible('A')
        assert state['workspace']['tabs'] == [host] and not state['previewUID']
        state = self.sidebar('B', count=2)
        assert len(state['workspace']['tabs']) == 2 and not state['previewUID']
        assert all(not tab['pinned'] for tab in state['workspace']['tabs'])
        self.command('new-tab')
        state = self.sidebar('C')
        assert len(state['workspace']['tabs']) == 3 and not state['previewUID']
        before_tab_count = len(state['workspace']['tabs'])
        state = self.command('key', text='t', code=17, modifiers=1<<20)
        assert len(state['workspace']['tabs']) == before_tab_count+1, 'Cmd+T creates a blank persistent Tab'
        state = self.sidebar('D')
        assert not state['previewUID']
        identities = {p['ref']:p['viewIdentity'] for p in state['panes']}
        before = [e for e in self.wire() if e.get('type') in ('subscribe','unsubscribe','resize')]
        for suffix in 'ABCDBA':
            state = self.sidebar(suffix)
            assert self.view(state, suffix)['viewIdentity'] == identities[self.refs[suffix]]
            assert not state['previewUID']
        for suffix in 'DCBA':
            tab = next(t for t in state['workspace']['tabs'] if t['activeUid'].endswith(self.refs[suffix]))
            self.command('tab', tab=tab['id'])
            state = self.visible(suffix)
            assert state['workspace']['activeTabId'] == tab['id']
            assert self.view(state, suffix)['viewIdentity'] == identities[self.refs[suffix]]
        after = [e for e in self.wire() if e.get('type') in ('subscribe','unsubscribe','resize')]
        assert before == after, 'warm switches must not re-subscribe/unsubscribe/resize'
        print('PASS permanent Tabs, +, Cmd+T, retained views and warm-switch wire silence', flush=True)
        for zone in ('top', 'bottom', 'left', 'right', 'center'):
            state = self.sidebar('A')
            self.settle_geometry(state)
            unhighlighted = self.capture('before-zone-'+zone, state)
            stage_x, stage_y, _, _ = self.view(state, 'A')['pixelROI']
            width, height = state['stageSize']
            x,y = {'top':(width/2,10), 'bottom':(width/2,height-10), 'left':(10,height/2),
                   'right':(width-10,height/2), 'center':(width/2,height/2)}[zone]
            sid = self.session_id('B')
            state = self.command('hover', session=sid, x=x, y=y)
            assert state['dropVisible'] and state['dropZone'] == zone
            predicted = state['dropFrame']
            highlighted = self.capture('zone-'+zone, state)
            px, py, pw, ph = predicted
            box = tuple(round(v) for v in (stage_x+2*(px+8),stage_y+2*(py+8),stage_x+2*(px+pw-8),stage_y+2*(py+ph-8)))
            difference = ImageChops.difference(Image.open(unhighlighted).convert('RGB').crop(box),
                                              Image.open(highlighted).convert('RGB').crop(box)).getchannel('B')
            changed = sum(difference.histogram()[4:]) / (difference.width*difference.height)
            assert changed > .5, (zone, 'WindowServer capture must contain the visible highlight', changed)
            self.receipts.append({'zone':zone, 'highlightChangedPixelFraction':changed})
            self.command('drop', session=sid, x=x, y=y)
            state = self.visible('B')
            actual = next(p['frame'] for p in state['projection'] if p['id'] == sid)
            assert actual == predicted, (zone, predicted, actual)
            assert len(state['projection']) == (1 if zone == 'center' else 2)
            assert all(p['frame'][2] >= 120 and p['frame'][3] >= 60 for p in state['projection'])
            self.settle_geometry(state)
            screenshot = self.capture('split-'+zone, state)
            self.output_assertion(screenshot, 'B')
            if zone != 'center': self.output_assertion(screenshot, 'A')
            if zone != 'center': self.command('close-pane', session=sid)
            else: self.command('drop', session=self.session_id('A'), x=width/2, y=height/2)
        state = self.visible('A')
        width,height=state['stageSize']
        self.command('drop', session=self.session_id('B'), x=width-10,y=height/2)
        state = self.visible('B')
        before_width = state['projection'][0]['frame'][2]
        state = self.command('splitter', path='root', delta=90)
        assert state['projection'][0]['frame'][2] == before_width+90
        self.settle_geometry(state)
        print('PASS all five AppKit destination zones, exact projected layout, minimum sizes and splitter', flush=True)
        state = self.command('terminal-click', ref=self.refs['A'])
        assert self.view(state,'A')['focused']
        self.input_checks('A')
        self.command('key', text='MOUSE-ON', code=0)
        wait_for(lambda: b'MOUSE-ON' in (self.directory/'input-A.bin').read_bytes())
        wait_for(lambda: self.view(self.command('state'),'A')['mouseMode'] != 'off')
        self.command('terminal-click', ref=self.refs['B'])
        before = (self.directory/'input-A.bin').read_bytes()
        self.command('terminal-click', ref=self.refs['A'])
        wait_for(lambda: re.fullmatch(rb'\x1b\[<0;(\d+);(\d+)M\x1b\[<0;\1;\2m',
                                     (self.directory/'input-A.bin').read_bytes()[len(before):]))
        print('PASS focused first click reaches SGR 1006 PTY press and release', flush=True)
        before = (self.directory/'input-A.bin').read_bytes()
        self.command('scroll', ref=self.refs['A'], delta=.5)
        assert (self.directory/'input-A.bin').read_bytes() == before, 'sub-cell precise scrolling accumulates without jumping a line'
        self.command('scroll', ref=self.refs['A'], delta=15.5)
        wait_for(lambda: b'\x1b[<64;' in (self.directory/'input-A.bin').read_bytes()[len(before):])
        wheel = (self.directory/'input-A.bin').read_bytes()[len(before):]
        assert wheel.count(b'\x1b[<64;') == 1, repr(wheel)
        print('PASS hit-tested scroll handler: precise accumulation and one SGR wheel step (OS dispatch NOT-RUN)', flush=True)
        self.tmux('send-keys','-t',self.refs['C'].split('\x1f')[-1],'-l','BACKGROUND-ORDER-1')
        self.tmux('send-keys','-t',self.refs['C'].split('\x1f')[-1],'-l','BACKGROUND-ORDER-2')
        self.sidebar('C')
        def background_delivered():
            text='\n'.join(self.view(self.command('state'),'C')['rows'])
            return 'BACKGROUND-ORDER-1'.encode().hex() in text and 'BACKGROUND-ORDER-2'.encode().hex() in text
        wait_for(background_delivered)
        print('PASS hidden Tab continues consuming ordered real PTY output', flush=True)
        summary = {'status':'PASS_APP_LOCAL', 'identity':self.identity, 'sharpness':json.loads(sharp.stdout),
                   'limitations':['OS NSDraggingSession tracking, system IME activation and OS wheel dispatch require a dedicated GUI environment'],
                   'commands':len(self.receipts)}
        (self.directory/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))

    def input_checks(self, suffix):
        path = self.directory / ('input-'+suffix+'.bin')
        baseline = path.read_bytes()
        for text,plain,code,modifiers,expected in [
            ('x','x',7,0,b'x'), ('\r','\r',36,0,b'\r'), ('\t','\t',48,0,b'\t'),
            ('\x1b','\x1b',53,0,b'\x1b'), ('\uf700','\uf700',126,0,b'\x1b[A'),
            ('\uf701','\uf701',125,0,b'\x1b[B'), ('\uf702','\uf702',123,0,b'\x1b[D'),
            ('\uf703','\uf703',124,0,b'\x1b[C'),
            ('\x03','c',8,1<<18,b'\x03'), ('\x04','d',2,1<<18,b'\x04')]:
            self.command('key',text=text,plain=plain,code=code,modifiers=modifiers)
            baseline += expected
            wait_for(lambda:path.read_bytes() == baseline, 5)
        for preedit, committed in [('zhong', '中文'), ('にほんご', '日本語')]:
            self.command('ime',ref=self.refs[suffix],marked=preedit)
            assert path.read_bytes() == baseline, 'IME preedit must not escape to the server'
            state = self.command('ime',ref=self.refs[suffix],marked=committed,commit=committed)
            baseline += committed.encode()
            wait_for(lambda:path.read_bytes()==baseline, 5)
            assert not self.view(state,suffix)['markedText']
        self.command('clipboard',text='two lines\nwithout enter')
        self.command('key',text='v',plain='v',code=9,modifiers=1<<20)
        baseline += b'two lines\nwithout enter'
        wait_for(lambda:path.read_bytes()==baseline,5)
        file_path = self.directory / 'a file.txt'
        file_path.write_text('isolated paste fixture')
        self.command('clipboard',file=str(file_path))
        self.command('key',text='v',plain='v',code=9,modifiers=1<<20)
        wait_for(lambda:len(path.read_bytes())>len(baseline),5)
        file_input = path.read_bytes()[len(baseline):].decode()
        # NSURL may canonically spell /private/tmp as /tmp. Require one quoted
        # path to the same real file, with no trailing Enter or extra argument.
        assert file_input.startswith("'") and file_input.endswith("'") and '\n' not in file_input
        arguments = shlex.split(file_input)
        assert len(arguments) == 1 and os.path.samefile(arguments[0], file_path)
        baseline += file_input.encode()
        from PIL import Image
        image = self.directory / 'paste.png'
        Image.new('RGB',(2,2),(120,80,30)).save(image)
        self.command('clipboard',image=str(image))
        self.command('key',text='\x16',plain='v',code=9,modifiers=1<<18)
        wait_for(lambda:len(path.read_bytes())>len(baseline),5)
        added = path.read_bytes()[len(baseline):].decode()
        assert added.startswith("'") and added.endswith(".png'"), repr(added)
        pasted = Image.open(added[1:-1]).convert('RGBA')
        expected = Image.open(image).convert('RGBA')
        assert pasted.size == expected.size and pasted.tobytes() == expected.tobytes()
        Path(added[1:-1]).unlink()
        print('PASS PTY keys/Enter/Tab/Esc/arrows/Ctrl+C/D, IME composition, text/file/image paste',flush=True)

    def cleanup(self):
        for process in reversed(self.processes):
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=3)
        if self.socket.exists():
            self.tmux('kill-server')
        (self.directory / 'identity.json').write_text(json.dumps(getattr(self, 'identity', {}), indent=2))
        (self.directory / 'commands.json').write_text(json.dumps(self.receipts, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--legacy-root', type=Path, required=True)
    parser.add_argument('--smoke', action='store_true')
    args = parser.parse_args()
    run = Run(args.legacy_root)
    try:
        run.start()
        if args.smoke: print('CAPTURE', run.capture('initial', run.state), flush=True)
        else: run.run_suite()
    except Exception:
        (run.directory/'failure.txt').write_text(traceback.format_exc())
        (run.directory/'summary.json').write_text(json.dumps({'status': 'FAIL', 'identity': getattr(run,'identity',{}),
            'lastCommand': run.receipts[-1].get('command') if run.receipts else None}, indent=2))
        raise
    finally:
        run.cleanup()


if __name__ == '__main__':
    main()
