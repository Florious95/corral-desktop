#!/usr/bin/env python3
"""Packaged native app -> real isolated agentmirrord -> private tmux PTYs.
AppKit events stay in the app; captures use only its exact WindowServer ID.
"""
import argparse
import base64
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
    def __init__(self, legacy, case='parity', no_resize=False, server_binary=None, pi_session=None):
        self.legacy = legacy
        self.case = case
        self.no_resize = no_resize
        self.server_binary = server_binary
        self.suffixes = 'ABCDEFGHIJ' if case.startswith('many-sessions') else 'ABCD'
        if case == 'session-liveness': self.suffixes = [f'S{i:02}' for i in range(50)]
        # A real Pi TUI (offline, no extensions) on a private copy of a long session.
        self.pi_session = pi_session
        if case in ('pi-scrollbar-drag', 'mobile-shared-anchor'): self.suffixes = 'ABCDP'
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
        for suffix in self.suffixes:
            session = f'ACCEPT-{suffix}-{self.nonce}'
            if suffix == 'P':
                transcript = self.directory / 'pi-session.jsonl'
                transcript.write_bytes(self.pi_session.read_bytes())
                # Pi's fullscreen copy-on-select defaults to the HOST clipboard.
                # Isolate its config as well as Corral's pasteboard: a TUI selection
                # must never run pbcopy or load the operator's resources/credentials.
                pi_config = self.directory / 'pi-config'
                pi_config.mkdir(mode=0o700)
                (pi_config / 'settings.json').write_text(json.dumps({
                    'fullscreenCopyOnSelect': False, 'tuiMode': 'fullscreen',
                    'defaultProjectTrust': 'never', 'cacheWarming': 'off',
                    'enableInstallTelemetry': False, 'enableAnalytics': False}))
                self.tmux('new-session', '-d', '-s', session, '-x', '110', '-y', '32', '-c', str(self.directory),
                          '/usr/bin/env', 'PI_CODING_AGENT_DIR=' + str(pi_config), 'PI_TELEMETRY=0',
                          'PI_SKIP_VERSION_CHECK=1', '/opt/homebrew/bin/pi', '--offline', '--no-extensions', '--no-skills', '--no-prompt-templates',
                          '--no-context-files', '--session', str(transcript), '--session-dir', str(self.directory / 'pi-sessions'))
                self.tmux('set-option', '-t', session, 'status', 'off')
                continue
            self.tmux('new-session', '-d', '-s', session, '-x', '110', '-y', '32', '-c', str(self.directory),
                      str(agent), suffix, self.nonce, str(self.directory / f'input-{suffix}.bin'),
                      ('empty' if suffix == 'F' else 'busy') if self.case == 'many-sessions-stress'
                      else 'busy' if self.case == 'session-liveness' else 'normal')
            self.tmux('set-option', '-t', session, 'status', 'off')
            self.tmux('select-pane', '-t', session, '-T', session)
        self.refs = {name.split('-')[1]: str(self.socket) + "\x1f" + ref for ref, name in
                     (line.split('\t') for line in self.tmux('list-panes', '-a', '-F', '#{pane_id}\t#{session_name}').splitlines())}
        token = secrets.token_hex(32)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        assert port != 9900
        self.daemon_port = port
        env = {k: v for k, v in os.environ.items() if k in ('LANG', 'LC_CTYPE', 'LC_ALL', 'TMPDIR')}
        env.update(PATH=str(helper)+':/usr/bin:/bin:/opt/homebrew/bin',
                   AGENTMIRROR_TOKEN=token, AGENTMIRROR_NODEPROBE_BIN=str(runtime / 'nodeprobe'),
                   NODEPROBE_FIXTURES=str(runtime / 'titles.tsv'), NODEPROBE_PROVIDERS=str(runtime / 'providers.tsv'),
                   AGENTMIRROR_NODEPROBE_PI_EXTENSION=str(runtime / 'nodeprobe-pi-activity.js'),
                   AGENTMIRROR_E2E_DISCOVERY_SOCKET_DIRS=str(self.socket.parent))
        daemon = self.server_binary or ROOT / '.build/native-acceptance-server/agentmirrord'
        assert daemon.resolve().is_relative_to((ROOT / '.build').resolve()), 'only a private test binary copy is accepted'
        server_identity = json.loads(daemon.with_name('build.json').read_text())
        if not self.server_binary:
            assert server_identity['commit'] == 'f664ec3fde8c96b8d326802dfc92020a2ff818a3', 'rebuild the daemon with build-server.py'
        assert hashlib.sha256(daemon.read_bytes()).hexdigest() == server_identity['sha256']
        daemon_process = self.start_process([str(daemon), '-listen', f'127.0.0.1:{port}', '-state-dir', str(self.directory / 'server-state'),
                                            '-upload-dir', str(self.directory / 'uploads')], env, 'daemon')
        def listening():
            assert daemon_process.poll() is None, 'isolated daemon exited; see daemon.log'
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1): return True
            except OSError: return False
        wait_for(listening)
        self.daemon_env = env
        proxy_env = dict(env, CORRAL_WEB_PACKAGE=str(self.legacy / 'package.json'),
                         CORRAL_ACCEPTANCE_RUN=str(self.directory), CORRAL_ACCEPTANCE_DAEMON_PORT=str(port))
        self.start_process(['node', str(HERE / 'wire-proxy.mjs')], proxy_env, 'proxy')
        wait_for(lambda: (self.directory / 'proxy-port').exists())
        proxy_port = int((self.directory / 'proxy-port').read_text())
        assert proxy_port != 9900
        app_env = dict(os.environ, CORRAL_NATIVE_ACCEPTANCE_DIRECTORY=str(self.directory), CORRAL_NATIVE_BACKGROUND='1',
                       CORRAL_NATIVE_ENDPOINT=f'ws://127.0.0.1:{proxy_port}/ws', CORRAL_NATIVE_TOKEN=token)
        app_env.pop('CORRAL_NATIVE_NO_RESIZE', None)
        if self.no_resize: app_env['CORRAL_NATIVE_NO_RESIZE'] = '1'
        app = ROOT / '.build/CorralNativeDev.app/Contents/MacOS/CorralApp'
        self.app = self.start_process([str(app)], app_env, 'app')
        self.identity = {'app': str(app), 'appSHA256': hashlib.sha256(app.read_bytes()).hexdigest(),
                         'baseHEAD': subprocess.check_output(['git','rev-parse','HEAD'], cwd=ROOT, text=True).strip(),
                         'sourceTree': subprocess.check_output(['git','rev-parse','HEAD^{tree}'], cwd=ROOT, text=True).strip(),
                         'worktreeStatus': subprocess.check_output(['git','status','--porcelain'], cwd=ROOT, text=True),
                         'runnerSHA256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                         'server': server_identity, 'daemonPort': port, 'clientPort': proxy_port, 'tmuxSocket': str(self.socket), 'refs': self.refs,
                         'origin': 'appkit-synthetic', 'systemHID': 'NOT-RUN', 'nativeOSDragTracking': 'NOT-RUN',
                         'case': self.case, 'noResize': self.no_resize,
                         'piIsolatedConfig': str(self.directory / 'pi-config') if self.pi_session else None,
                         'piCopyOnSelect': False if self.pi_session else None}
        print(f'RUN_DIR={self.directory}', flush=True)
        wait_for(lambda: self.command('state').get('connected'), 25)
        self.state = wait_for(lambda: self.ready_state(), 25)
        self.ids = {suffix: next(a['id'] for a in self.state['agents'] if a['id'].endswith(ref)) for suffix, ref in self.refs.items()}
        print('APP_CONNECTED', json.dumps(self.state['agents']), flush=True)

    def ready_state(self):
        state = self.command('state')
        return state if len(state['agents']) == len(self.suffixes) and any(self.nonce in '\n'.join(p['rows']) for p in state['panes']) else None

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
        if self.case != 'session-liveness':
            (self.directory / 'commands.json').write_text(json.dumps(self.receipts, ensure_ascii=False, indent=2))
        assert result['ok'], result
        return result['state']

    def capture(self, name, state):
        path = self.directory / (name + '.png')
        subprocess.run(['screencapture', '-l', str(state['windowID']), '-o', '-x', str(path)], check=True)
        return path

    def session_id(self, suffix):
        if hasattr(self, 'ids'): return self.ids[suffix]
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

    def live_subscriptions(self):
        live = set()
        for event in self.wire():
            if event.get('direction') != 'client-to-daemon': continue
            if event.get('type') == 'subscribe': live.add(event['payload']['ref'])
            elif event.get('type') == 'unsubscribe': live.discard(event['payload']['ref'])
        return live

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

    def run_many_sessions(self):
        identities = {}
        for gesture, order in [('preview', self.suffixes), ('permanent', self.suffixes), ('return', self.suffixes[::-1])]:
            for index, suffix in enumerate(order, 1):
                try:
                    if gesture == 'preview' and suffix == 'F' and self.case == 'many-sessions-stress':
                        self.command('sidebar', session=self.session_id(suffix))
                        state = self.command('state')
                        pane = self.view(state, suffix)
                        assert not ''.join(pane['rows']).strip(), 'sixth PTY must start genuinely empty'
                        assert pane['focused'] and pane['frame'][2] > 120 and pane['frame'][3] > 60
                        self.capture('sixth-empty-before-input', state)
                        self.command('key', text='x', plain='x', code=7)
                        wait_for(lambda: (self.directory/'input-F.bin').read_bytes() == b'x')
                    state = self.sidebar(suffix, count=2 if gesture == 'permanent' else 1)
                except Exception:
                    self.capture(f'{gesture}-{index}-{suffix}-failure', self.command('state'))
                    raise
                pane = self.view(state, suffix)
                if gesture != 'preview' and suffix in identities:
                    assert pane['viewIdentity'] == identities[suffix], 'switching must retain the terminal view'
                if gesture == 'permanent': identities[suffix] = pane['viewIdentity']
                if self.case == 'many-sessions-stress' and suffix != 'F':
                    previous = max(map(int, re.findall(r'LIVE-(\d+)', '\n'.join(pane['rows']))))
                    def advanced():
                        current = self.command('state')
                        values = re.findall(r'LIVE-(\d+)', '\n'.join(self.view(current, suffix)['rows']))
                        return current if values and max(map(int, values)) > previous else None
                    state = wait_for(advanced)
                else:
                    marker = f'{gesture}-{suffix}'
                    self.command('key', text=marker, code=0)
                    def echoed():
                        current = self.command('state')
                        return current if marker.encode().hex() in ''.join(self.view(current, suffix)['rows']) else None
                    state = wait_for(echoed)
                screenshot = self.capture(f'{gesture}-{index}-{suffix}', state)
                self.output_assertion(screenshot, suffix)
                if not self.no_resize: self.settle_geometry(state)
                if gesture == 'preview':
                    expected = {self.refs['A'], self.refs[suffix]}
                    live = self.live_subscriptions()
                    assert set(state['subscribed']) == live == expected, ('departed previews must release their subscriptions', suffix, live, expected)
                print(f'PASS {gesture} {index}/10 {suffix}: real PTY -> WindowServer OCR', flush=True)
            if gesture == 'preview' and self.case == 'many-sessions-stress':
                order = 'BCDEFGHIJABCDEFGHIF' * 3
                self.command('sidebar-sequence', sessions=[self.session_id(s) for s in order])
                state = self.visible('F')
                self.output_assertion(self.capture('rapid-preview-final-F', state), 'F')
                assert set(state['subscribed']) == self.live_subscriptions() == {self.refs['A'], self.refs['F']}
                assert len(state['panes']) == 2, 'abandoned preview viewports must be released'
                print('PASS 54 rapid previews under sustained PTY output; empty/idle sixth remains interactive', flush=True)
        assert len(identities) == 10 and len(state['subscribed']) == 10
        assert len(state['workspace']['tabs']) == 10
        self.write_case_summary()

    def run_session_liveness(self):
        latencies = []
        send_latencies = []
        identities = {}
        host = self.suffixes[0]

        def verify(suffix, label):
            state = self.visible(suffix)
            pane = self.view(state, suffix)
            assert state['connected'] and not state['lastError'], state['lastError']
            assert pane['focused'] and pane['hitTestMatches'], 'visible terminal must own focus and hit testing'
            assert len([p for p in state['panes'] if not p['hidden']]) == 1, 'exactly one preview surface'
            before_live = max(map(int, re.findall(r'LIVE-(\d+)', '\n'.join(pane['rows']))))
            path = self.directory / f'input-{suffix}.bin'
            baseline = path.read_bytes()
            marker = f'{label}-{suffix}'.encode()
            ack = state['inputAckSequence']
            state = self.command('key', text=marker.decode(), code=0)
            dispatched = state['lastKeyDispatchTime']
            wait_for(lambda: path.read_bytes() == baseline + marker, 3)
            timing = [json.loads(line) for line in path.with_suffix('.bin.timing.jsonl').read_text().splitlines()]
            received = next(e['at'] for e in timing if e['offset'] + e['length'] >= len(baseline) + len(marker))
            latency = (received - dispatched) * 1000
            latencies.append(latency)
            assert latency >= 0, ('invalid timing receipt', suffix, latency)
            # "Key sent" ends at the observed WebSocket write. The frozen Core
            # subsequently runs tmux commands; retain its separate PTY latency.
            written = next(e['at'] for e in reversed(self.wire()) if e.get('type') == 'input' and
                           e['payload']['ref'] == self.refs[suffix] and base64.b64decode(e['payload']['bytes']) == marker)
            send_latency = max(0, written - dispatched * 1000)  # proxy clock has 1 ms resolution
            send_latencies.append(send_latency)
            assert send_latency < 100, ('native key-to-socket deadline (ms)', suffix, send_latency)

            def advanced():
                current = self.command('state')
                assert current['connected'], current['lastError']
                numbers = re.findall(r'LIVE-(\d+)', '\n'.join(self.view(current, suffix)['rows']))
                return current if numbers and max(map(int, numbers)) > before_live and current['inputAckSequence'] > ack and current['inputAckSucceeded'] else None

            state = wait_for(advanced, 5)
            screenshot = self.capture(label+'-'+suffix, state)
            self.output_assertion(screenshot, suffix)
            return state

        for suffix in self.suffixes:
            self.command('sidebar', session=self.ids[suffix])
            state = verify(suffix, 'preview')
            expected = {self.refs[host], self.refs[suffix]}
            assert set(state['subscribed']) == self.live_subscriptions() == expected
            assert len(state['panes']) == len(expected), 'departed previews must release their physical views'
            print(f'PASS preview {suffix}: live output, focus/hit-test, key-to-PTY {latencies[-1]:.2f} ms', flush=True)
        for iteration in range(3):
            order = self.suffixes[::-1] if iteration % 2 == 0 else self.suffixes
            switched = self.command('sidebar-sequence', sessions=[self.ids[s] for s in order])
            assert len(switched['switchSamples']) == 50
            assert all(s['requested'] == s['visible'] and s['milliseconds'] < 100 for s in switched['switchSamples']), 'every local click must advance the stage within 100 ms'
            state = verify(order[-1], f'rapid-{iteration}')
            assert len(state['panes']) == len({host, order[-1]})
            assert set(state['subscribed']) == self.live_subscriptions() == {self.refs[host], self.refs[order[-1]]}
        for suffix in self.suffixes:
            self.command('sidebar', session=self.ids[suffix], count=2)
            state = verify(suffix, 'permanent')
            identities[suffix] = self.view(state, suffix)['viewIdentity']
            print(f'PASS permanent {suffix}: live output and key-to-PTY {latencies[-1]:.2f} ms', flush=True)
        assert len(state['workspace']['tabs']) == len(state['panes']) == len(state['subscribed']) == 50
        for iteration in range(3):
            order = self.suffixes[::-1] if iteration % 2 == 0 else self.suffixes
            switched = self.command('sidebar-sequence', sessions=[self.ids[s] for s in order])
            assert len(switched['switchSamples']) == 50
            assert all(s['requested'] == s['visible'] and s['milliseconds'] < 100 for s in switched['switchSamples'])
            state = verify(order[-1], f'warm-{iteration}')
            assert all(self.view(state, s, visible=False)['viewIdentity'] == identities[s] for s in self.suffixes)
        self.input_checks(self.suffixes[0])
        (self.directory/'latency.json').write_text(json.dumps({'samples':latencies, 'maximumMs':max(latencies),
            'p95Ms': sorted(latencies)[int(len(latencies)*.95)], 'boundary':'AppKit key dispatch -> read(STDIN_FILENO)',
            'nativeKeyToSocketMs': send_latencies, 'nativeKeyToSocketMaxMs': max(send_latencies),
            'deliveryDeadlineSeconds': 3, 'nativeSendDeadlineMs': 100}, indent=2))
        self.write_case_summary()

    def run_mouse_drag_backlog(self, seconds=5, rate=120):
        """Pi's TUI mode: a held drag becomes SGR motion reports. Hand stops -> PTY stops."""
        self.visible('A')
        state = self.command('terminal-click', ref=self.refs['A'])
        assert self.view(state, 'A')['focused']
        path = self.directory / 'input-A.bin'
        self.command('key', text='MOUSE-ANY', code=0)
        wait_for(lambda: b'MOUSE-ANY' in path.read_bytes())
        wait_for(lambda: self.view(self.command('state'), 'A')['mouseMode'] == 'anyEvent')
        time.sleep(1)
        before = len(path.read_bytes())
        wire_before = len(self.wire())
        drag = self.command('terminal-drag', ref=self.refs['A'], seconds=seconds, rate=rate,
                            path=[.05, .1, .9, .85])['lastDrag']
        timing_path = path.with_suffix('.bin.timing.jsonl')
        def settled():
            entries = [json.loads(line) for line in timing_path.read_text().splitlines()]
            last = max((e['at'] for e in entries if e['offset'] + e['length'] > before), default=0)
            return last if last and time.time() - last > 3 else None
        last_receipt = wait_for(settled, 180)
        reports = re.findall(rb'\x1b\[<(\d+);(\d+);(\d+)([Mm])', path.read_bytes()[before:])
        motions = [r for r in reports if int(r[0]) & 32 and not int(r[0]) & 64]
        assert reports and reports[0][3] == b'M' and not int(reports[0][0]) & 32, 'the press must arrive first'
        assert reports[-1][3] == b'm', 'the release must arrive last'
        inputs = [e for e in self.wire()[wire_before:] if e.get('direction') == 'client-to-daemon' and e.get('type') == 'input']
        summary = {'dragEvents': drag['events'], 'dragSeconds': drag['releasedWall'] - drag['startedWall'],
                   'motionReportsAtPTY': len(motions), 'inputMessages': len(inputs),
                   'releaseTailMilliseconds': round((last_receipt - drag['releasedWall']) * 1000, 1),
                   'finalMotionCell': [int(v) for v in motions[-1][1:3]] if motions else None,
                   'releaseCell': [int(v) for v in reports[-1][1:3]]}
        self.receipts.append({'mouseDragBacklog': summary})
        (self.directory / 'mouse-drag-backlog.json').write_text(json.dumps(summary, indent=2))
        print('MOUSE_DRAG_BACKLOG', json.dumps(summary), flush=True)
        assert summary['finalMotionCell'] == summary['releaseCell'], 'the latest pointer position must reach the PTY'
        assert summary['releaseTailMilliseconds'] <= 500, ('RED: input kept replaying after the hand stopped', summary)
        print('PASS mouse drag: latest position delivered, PTY quiet within 500 ms of release', flush=True)

    def run_pi_scrollbar_drag(self, seconds=10, rate=120, cycles=5):
        """User benchmark: shake a long Pi transcript's scrollbar at full amplitude for 10 s."""
        self.command('sidebar', session=self.session_id('P'), count=2)
        def pi_pane():
            pane = next((p for p in self.command('state')['panes'] if p['ref'] == self.refs['P'] and not p['hidden']), None)
            return pane if pane and pane['mouseMode'] != 'off' else None
        if not wait_for(pi_pane, 30)['focused']: self.command('terminal-click', ref=self.refs['P'], x=60, y=200)
        assert pi_pane()['focused']
        time.sleep(4)
        wire_before = len(self.wire())
        # Pi shows its auto-hiding scrollbar on scroll activity; grab it right away in the last column.
        self.command('scroll', ref=self.refs['P'], delta=40, precise=True)
        drag = self.command('terminal-drag', ref=self.refs['P'], seconds=seconds, rate=rate, cycles=cycles,
                            column=-1, path=[1, .03, 1, .78])['lastDrag']
        ref = self.refs['P']
        def settled():
            events = self.wire()[wire_before:]
            acks = [e['at'] for e in events if e.get('type') == 'input_ack']
            return events if acks and time.time() * 1000 - acks[-1] > 3000 else None
        events = wait_for(settled, 240)
        released = drag['releasedWall'] * 1000
        inputs = [e for e in events if e.get('direction') == 'client-to-daemon' and e.get('type') == 'input']
        acks = [e['at'] for e in events if e.get('type') == 'input_ack']
        frames = [e['at'] for e in events if e.get('binary') and e.get('ref') == ref and e.get('kind') == 2]
        # The visible motion ends at the first 1.5 s pause; a later lone repaint (scrollbar auto-hide) is not motion.
        render_tail, previous = 0, released
        for at in frames:
            if at <= released: continue
            if at - previous > 1500: break
            render_tail, previous = at - released, at
        histogram = [sum(1 for at in frames if released + i * 1000 < at <= released + (i + 1) * 1000) for i in range(40)]
        summary = {'dragEvents': drag['events'], 'dragSeconds': round(drag['releasedWall'] - drag['startedWall'], 2),
                   'inputMessages': len(inputs), 'framesDuringDrag': sum(1 for at in frames if at <= released),
                   'injectionTailMilliseconds': round(acks[-1] - released, 1),
                   'renderTailMilliseconds': round(render_tail, 1), 'framesPerSecondAfterRelease': histogram}
        (self.directory / 'pi-session.jsonl').unlink()
        self.receipts.append({'piScrollbarDrag': summary})
        (self.directory / 'pi-scrollbar-drag.json').write_text(json.dumps(summary, indent=2))
        print('PI_SCROLLBAR_DRAG', json.dumps(summary), flush=True)
        assert summary['framesDuringDrag'] > 20, 'the drag must actually move the Pi transcript'
        assert summary['injectionTailMilliseconds'] <= 500, ('RED: stale drag input kept reaching Pi', summary)
        assert summary['renderTailMilliseconds'] <= 2000, ('RED: Pi kept moving after the hand stopped', summary)
        print('PASS Pi scrollbar: input and transcript stop with the hand', flush=True)

    def pane_size(self, suffix):
        ref = self.refs[suffix].split('\x1f')[-1]
        sizes = dict((line.split('\t')[0], tuple(map(int, line.split('\t')[1:]))) for line in
                     self.tmux('list-panes', '-a', '-F', '#{pane_id}\t#{pane_width}\t#{pane_height}').splitlines())
        return sizes[ref]

    def run_mobile_shared_anchor(self, phone=(46, 44)):
        """A phone shares Pi: the desktop keeps the phone's PTY grid, hung from the pane's bottom-left."""
        from PIL import Image
        self.command('sidebar', session=self.session_id('P'), count=2)
        def pi_pane(state=None):
            state = state or self.command('state')
            pane = next((p for p in state['panes'] if p['ref'] == self.refs['P'] and not p['hidden']), None)
            return pane if pane and pane['mouseMode'] != 'off' else None
        wait_for(pi_pane, 30)
        desktop = pi_pane()
        wait_for(lambda: self.pane_size('P') == (desktop['cols'], len(desktop['rows'])), 15)
        wire_before = len(self.wire())
        mobile_log = self.directory / 'mobile.jsonl'
        mobile = self.start_process(['node', str(HERE / 'mobile-client.mjs'), str(self.daemon_port), self.refs['P'],
                                     str(phone[0]), str(phone[1]), str(mobile_log)],
                                    dict(self.daemon_env, CORRAL_WEB_PACKAGE=str(self.legacy / 'package.json')), 'mobile')
        wait_for(lambda: self.pane_size('P') == phone, 15)
        summary = {'phone': phone, 'desktopGridBefore': [desktop['cols'], len(desktop['rows'])], 'checks': []}
        def check(name, window):
            self.command('resize-window', width=window[0], height=window[1])
            time.sleep(3)
            state = self.command('state')
            view = pi_pane(state)
            pane = next(p for p in state['projectionWindow'] if p['id'] == self.session_id('P'))['frame']
            frame = view['frame']
            tmux_last = self.tmux('capture-pane', '-p', '-t', self.refs['P'].split('\x1f')[-1]).rstrip('\n').split('\n')[-1].rstrip()
            shot = self.capture('anchor-' + name, state)
            result = {'name': name, 'window': window, 'ptyGrid': list(self.pane_size('P')),
                      'localGrid': [view['cols'], len(view['rows'])], 'viewFrame': frame, 'paneFrame': pane,
                      'leftAligned': abs(frame[0] - pane[0]) < .5, 'bottomAligned': abs(frame[1] - pane[1]) < .5,
                      'overflowsTop': frame[1] + frame[3] > pane[1] + pane[3] + .5,
                      'lastRowMatchesPTY': view['rows'][-1].rstrip() == tmux_last, 'hitTestMatches': view['hitTestMatches'],
                      'screenshot': shot.name}
            # The pane's bottom three rows, exactly as WindowServer shows them, must hold the PTY's last line.
            scale = state['backingScale']
            top = state['windowFrame'][3] - pane[1]
            cell = frame[3] / max(1, len(view['rows']))
            strip = Image.open(shot).crop((round(pane[0] * scale), round((top - 3 * cell) * scale),
                                           round((pane[0] + pane[2]) * scale), round(top * scale)))
            strip_path = self.directory / ('anchor-' + name + '-bottom.png')
            strip.save(strip_path)
            ocr = json.loads(subprocess.check_output(['swift', str(HERE / 'recognize.swift'), str(strip_path)], text=True))
            words = [w for w in re.findall(r'[A-Za-z0-9.]{4,}', tmux_last)]
            result['bottomStripOCR'] = ocr
            result['bottomStripHasPTYLastLine'] = bool(words) and any(w in ''.join(ocr).replace(' ', '') for w in words)
            summary['checks'].append(result)
        check('wide', (1400, 860))
        check('short', (1000, 420))
        marker = 'ANCHOR' + self.nonce
        self.command('key', text=marker, code=0)
        typed = wait_for(lambda: marker in self.tmux('capture-pane', '-p', '-t', self.refs['P'].split('\x1f')[-1]), 10)
        summary['typedReachedPTY'] = bool(typed)
        summary['typedVisibleOnDesktop'] = any(marker in row for row in pi_pane()['rows'])
        summary['desktopResizesWhilePhonePresent'] = [e['payload'] for e in self.wire()[wire_before:]
            if e.get('direction') == 'client-to-daemon' and e.get('type') == 'resize']
        mobile.terminate(); mobile.wait(timeout=5)
        self.command('resize-window', width=1400, height=860)
        def taken_over():
            view = pi_pane()
            grid = (view['cols'], len(view['rows']))
            return grid if grid != phone and self.pane_size('P') == grid else None
        try: summary['takeoverGrid'] = list(wait_for(taken_over, 15))
        except AssertionError: summary['takeoverGrid'] = None
        (self.directory / 'pi-session.jsonl').unlink()
        self.receipts.append({'mobileSharedAnchor': summary})
        (self.directory / 'mobile-shared-anchor.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False))
        print('MOBILE_SHARED_ANCHOR', json.dumps({k: v for k, v in summary.items() if k != 'checks'}, ensure_ascii=False), flush=True)
        for c in summary['checks']:
            print('ANCHOR_CHECK', json.dumps({k: v for k, v in c.items() if k != 'bottomStripOCR'}), flush=True)
        failures = [name for name, ok in [
            ('no desktop resize while the phone is attached', not summary['desktopResizesWhilePhonePresent']),
            ('phone keeps its PTY grid', all(c['ptyGrid'] == list(phone) for c in summary['checks'])),
            ('desktop keeps the remote grid locally', all(c['localGrid'] == list(phone) for c in summary['checks'])),
            ('bottom-left anchored', all(c['leftAligned'] and c['bottomAligned'] for c in summary['checks'])),
            ('short pane clips the top', summary['checks'][1]['overflowsTop']),
            ('bottom row is the PTY bottom row', all(c['lastRowMatchesPTY'] for c in summary['checks'])),
            ('WindowServer bottom strip shows the PTY last line', all(c['bottomStripHasPTYLastLine'] for c in summary['checks'])),
            ('input still reaches the PTY', summary['typedReachedPTY'] and summary['typedVisibleOnDesktop']),
            ('desktop takes over after the phone leaves', summary['takeoverGrid'] is not None)] if not ok]
        assert not failures, ('RED', failures)
        print('PASS mobile-shared anchor: remote grid kept, bottom-left anchored, top clipped, input live, takeover', flush=True)

    def run_window_resize(self):
        state = self.sidebar('A')
        width, height = state['stageSize']
        self.command('drop', session=self.session_id('B'), x=width-10, y=height/2)
        state = self.visible('B')
        first_width = state['projection'][0]['frame'][2]
        self.command('splitter', path='root', delta=round((width-6)/3)-first_width)
        initial_grids = {p['ref']: (p['cols'], len(p['rows'])) for p in self.command('state')['panes'] if not p['hidden']}
        for width, height in [(1400, 860), (1000, 720), (800, 700), (640, 600), (480, 480), (480, 360), (1400, 860)]:
            state = self.command('resize-window', width=width, height=height)
            screenshot = self.capture(f'window-{width}x{height}', state)
            assert state['windowFrame'][2:] == [width, height], ('window must accept the requested size', state['windowFrame'])
            assert state['workspaceFrame'][2:] == [width, height], ('workspace must follow its host', state['workspaceFrame'])
            sx, sy, sw, sh = state['stageFrame']
            assert sx >= 0 and sy >= 0 and sx+sw <= width and sy+sh <= height
            assert len(state['projection']) == 2
            expected_first = min(max((sw - 6) // 3, 120), sw - 6 - 120)
            assert abs(state['projection'][0]['frame'][2] - expected_first) <= 1, 'ratio adapts only when a pane minimum requires it'
            for suffix in 'AB':
                pane = self.view(state, suffix)
                x, y, w, h = pane['frame']
                assert w >= 120 and h >= 60 and x >= 0 and y >= 0 and x+w <= width and y+h <= height, pane['frame']
                projected = next(p['frame'] for p in state['projection'] if p['id'] == self.session_id(suffix))
                assert [w, h] == projected[2:], ('terminal and pane chrome must share the same rectangle', pane['frame'], projected)
                assert (pane['cols'],len(pane['rows'])) != initial_grids[pane['ref']] or width == 1400, 'terminal grid must follow window size'
                self.output_assertion(screenshot, suffix)
            if not self.no_resize: self.settle_geometry(state)
            detail = 'local grids with remote resize blocked' if self.no_resize else 'native grids match real PTY geometry'
            print(f'PASS window {width}x{height}: both panes visible; {detail}', flush=True)
        if self.no_resize:
            assert not any(e.get('type')=='resize' for e in self.wire()), 'inspection must not resize the remote PTY'
        self.write_case_summary()

    def write_case_summary(self):
        (self.directory/'summary.json').write_text(json.dumps({'status':'PASS_APP_LOCAL', 'case':self.case,
            'identity':self.identity, 'commands':len(self.receipts)},ensure_ascii=False,indent=2))

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
        (self.directory / 'pi-session.jsonl').unlink(missing_ok=True)
        (self.directory / 'identity.json').write_text(json.dumps(getattr(self, 'identity', {}), indent=2))
        (self.directory / 'commands.json').write_text(json.dumps(self.receipts, ensure_ascii=False, indent=2))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--legacy-root', type=Path, required=True)
    parser.add_argument('--smoke', action='store_true')
    parser.add_argument('--case', choices=['parity','many-sessions','many-sessions-stress','window-resize','session-liveness','mouse-drag-backlog','pi-scrollbar-drag','mobile-shared-anchor'], default='parity')
    parser.add_argument('--no-resize', action='store_true')
    parser.add_argument('--server-binary', type=Path)
    parser.add_argument('--pi-session', type=Path, help='Pi transcript copied privately for pi-scrollbar-drag')
    args = parser.parse_args()
    assert args.case not in ('pi-scrollbar-drag', 'mobile-shared-anchor') or args.pi_session, '--pi-session is required'
    run = Run(args.legacy_root, args.case, args.no_resize, args.server_binary, args.pi_session)
    try:
        run.start()
        if args.smoke: print('CAPTURE', run.capture('initial', run.state), flush=True)
        elif args.case == 'session-liveness': run.run_session_liveness()
        elif args.case.startswith('many-sessions'): run.run_many_sessions()
        elif args.case == 'window-resize': run.run_window_resize()
        elif args.case == 'mouse-drag-backlog': run.run_mouse_drag_backlog()
        elif args.case == 'pi-scrollbar-drag': run.run_pi_scrollbar_drag()
        elif args.case == 'mobile-shared-anchor': run.run_mobile_shared_anchor()
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
