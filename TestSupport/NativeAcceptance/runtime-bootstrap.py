#!/usr/bin/env python3
"""Cold-start the packaged self-contained app with private HOME/launchd/port/tmux.
No host Pi settings, host tmux sockets, production 9900 or global input are used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import time
import traceback
from run import Run, ROOT, wait_for


class RuntimeRun(Run):
    def __init__(self, legacy, app):
        super().__init__(legacy, case='self-contained-runtime')
        self.bundle = app.resolve()
        self.runtime = self.bundle / 'Contents/Resources/Runtime'
        self.home = self.directory / 'home'
        self.label = 'com.corral.native.test.' + hashlib.sha256(str(self.directory).encode()).hexdigest()[:12]
        self.service = f'gui/{os.getuid()}/{self.label}'
        self.extra_socket = self.socket.parent / 'another-user-server'

    def tmux_on(self, sock, *args):
        return subprocess.check_output([str(self.runtime / 'tmux'), '-S', str(sock), *args],
                                       env=self.tmux_env, text=True).strip()

    def tmux(self, *args):
        return self.tmux_on(self.socket, *args)

    def adopt_owned_label(self):
        marker = self.directory / 'storage/com.corral.native.dev/runtime/service-owner.json'
        if marker.exists():
            owner = json.loads(marker.read_text())
            assert owner['label'].startswith('com.corral.native.test.')
            assert Path(owner['executable']).resolve().is_relative_to(marker.parent.resolve())
            self.label = owner['label']
            self.service = f'gui/{os.getuid()}/{self.label}'
            if hasattr(self, 'identity'): self.identity['launchdLabel'] = self.service

    def job_pid(self):
        result = subprocess.run(['launchctl', 'print', self.service], capture_output=True, text=True)
        found = re.search(r'\bpid = (\d+)', result.stdout)
        return int(found[1]) if result.returncode == 0 and found else None

    def start(self):
        self.home.mkdir(mode=0o700)
        settings = self.home / '.pi/agent'
        settings.mkdir(parents=True, mode=0o700)
        (settings / 'settings.json').write_text(json.dumps({'fullscreenCopyOnSelect': False, 'tuiMode': 'fullscreen',
            'defaultProjectTrust': 'never', 'cacheWarming': 'off', 'enableInstallTelemetry': False}))
        (settings / 'settings.json').chmod(0o600)
        self.socket.parent.mkdir(mode=0o700)
        self.tmux_env = {'HOME': str(self.home), 'PATH': str(self.runtime) + ':/usr/bin:/bin',
                         'LANG': 'en_US.UTF-8', 'LC_ALL': 'en_US.UTF-8', 'TERM': 'xterm-256color', 'TERMINFO_DIRS': str(self.runtime / 'terminfo') + ':/usr/share/terminfo'}
        self.tmux('new-session', '-d', '-s', 'RUNTIME-ANCHOR', '-x', '110', '-y', '32', '-c', str(self.home), '/bin/sleep', '3600')
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        assert port != 9900
        self.app_env = {'HOME': str(self.home), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
                        'CORRAL_NATIVE_ACCEPTANCE_DIRECTORY': str(self.directory), 'CORRAL_NATIVE_BACKGROUND': '1',
                        'CORRAL_NATIVE_ENDPOINT': f'ws://127.0.0.1:{port}/ws', 'CORRAL_NATIVE_BOOTSTRAP_RUNTIME': '1'}
        binary = self.bundle / 'Contents/MacOS/CorralApp'
        self.identity = {'app': str(self.bundle), 'appSHA256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                         'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
                         'port': port, 'launchdLabel': self.service, 'home': str(self.home),
                         'systemHID': 'NOT-RUN', 'runtimeManifestSHA256': hashlib.sha256((self.runtime / 'runtime-manifest.json').read_bytes()).hexdigest()}
        print('RUN_DIR=' + str(self.directory), flush=True)
        self.app = self.start_process([str(binary)], self.app_env, 'app')
        wait_for(lambda: self.command('state').get('connected'), 30)
        token = self.home / 'Library/Application Support/agentmirror/token'
        assert token.is_file() and token.stat().st_mode & 0o777 == 0o600
        self.token_before = token.read_bytes()
        self.adopt_owned_label()
        self.daemon_pid = wait_for(self.job_pid, 10)
        plugin = self.home / '.pi/agent/extensions/nodeprobe-pi-activity.js'
        assert plugin.read_bytes() == (self.runtime / 'nodeprobe-pi-activity.js').read_bytes()
        assert (self.home / '.pi/agent/plugins/agentmirror-probe/index.js').read_bytes() == plugin.read_bytes()
        self.plugin_mtime = plugin.stat().st_mtime_ns
        print('COLD_START_READY', json.dumps({'daemonPID': self.daemon_pid, 'tokenCreated': True, 'pluginInstalled': True}), flush=True)

    def verify(self):
        activity = self.directory / 'pi-activity'
        # Real Pi loads the extension by canonical auto-discovery, not --extension injection.
        pi_args = ['/usr/bin/env', '-i', 'HOME=' + str(self.home),
                  'PATH=' + str(self.runtime) + ':/opt/homebrew/bin:/usr/bin:/bin', 'TERM=xterm-256color',
                  'LANG=en_US.UTF-8', 'LC_ALL=en_US.UTF-8',
                  'PI_CODING_AGENT_DIR=' + str(self.home / '.pi/agent'), 'PI_TELEMETRY=0', 'PI_SKIP_VERSION_CHECK=1',
                  'NODEPROBE_PI_ACTIVITY_DIR=' + str(activity), '/opt/homebrew/bin/pi', '--offline',
                  '--no-skills', '--no-prompt-templates', '--no-context-files', '--session-dir', str(self.directory / 'pi-sessions')]
        for sock, name in [(self.socket, 'RUNTIME-PI'), (self.extra_socket, 'RUNTIME-PI-B')]:
            self.tmux_on(sock, 'new-session', '-d', '-s', name, '-x', '100', '-y', '30', '-c', str(self.home), *pi_args)
        def record():
            if not activity.exists(): return None
            records = [json.loads(p.read_text()) for p in activity.glob('*.json')]
            valid = [r for r in records if r.get('provider') == 'pi' and r.get('schema_version') == 2]
            return valid if len(valid) == 2 else None
        records = wait_for(record, 30)
        rec = records[0]
        for record in records:
            with socket.socket(socket.AF_UNIX) as peer:
                peer.settimeout(3)
                peer.connect(record['socket_path'])
                peer.sendall(b'{"challenge":"native-package-acceptance"}\n')
                reply = json.loads(peer.recv(65536))
            assert reply['challenge'] == 'native-package-acceptance' and reply['instance_id'] == record['instance_id']
            assert reply['pid'] == record['pid'] and reply['activity'] == 'idle'
        env = dict(self.tmux_env, NODEPROBE_FIXTURES=str(self.runtime / 'nodeprobe-titles.tsv'),
                   NODEPROBE_PROVIDERS=str(self.runtime / 'nodeprobe-providers.tsv'), NODEPROBE_PI_ACTIVITY_DIR=str(activity))
        pi_nodes = []
        for index, sock in enumerate([self.socket, self.extra_socket]):
            probe = subprocess.run([str(self.runtime / 'nodeprobe'), '-S', str(sock)], env=env, text=True, capture_output=True)
            (self.directory / f'nodeprobe-{index}.json').write_text(probe.stdout)
            (self.directory / f'nodeprobe-{index}.stderr').write_text(probe.stderr)
            assert probe.returncode == 0, (probe.returncode, probe.stdout, probe.stderr)
            report = json.loads(probe.stdout)
            pi_nodes.extend(n for n in report['nodes'] if n.get('provider') == 'pi')
        assert len(pi_nodes) == 2 and all(n['health'] == 'normal' and n['activity'] == 'idle' for n in pi_nodes), pi_nodes
        def discovered():
            state = self.command('state')
            return state if len(state['agents']) == 2 and any(not p['hidden'] for p in state['panes']) else None
        state = wait_for(discovered, 30)
        assert state['connected'] and state['agents']
        pane = next(p for p in state['panes'] if not p['hidden'])
        pane_socket, pane_id = pane['ref'].rsplit('\x1f', 1)
        assert Path(pane_socket).resolve().is_relative_to(self.socket.parent.resolve())
        self.command('terminal-click', ref=pane['ref'], x=60, y=80)
        marker = 'BOOTSTRAP' + self.nonce
        self.command('key', text=marker, plain=marker, code=0)
        wait_for(lambda: marker in self.tmux_on(pane_socket, 'capture-pane', '-p', '-t', pane_id), 10)
        wait_for(lambda: any(marker in row for p in self.command('state')['panes'] for row in p['rows']), 10)
        screenshot = self.capture('bundled-runtime-real-pi', state)
        print('PI_AUTO_DISCOVERED', json.dumps({'pids': [r['pid'] for r in records], 'directProbeNodes': len(pi_nodes),
                                               'independentTmuxServers': 2, 'agents': len(state['agents']), 'screenshot': str(screenshot)}), flush=True)
        # Owned crash recovery, then UI reopen without restarting a healthy daemon.
        subprocess.run(['launchctl', 'kill', 'SIGKILL', self.service], check=True)
        new_pid = wait_for(lambda: (pid if (pid := self.job_pid()) and pid != self.daemon_pid else None), 25)
        wait_for(lambda: self.command('state')['connected'] and self.command('state')['agents'], 30)
        self.app.terminate(); self.app.wait(timeout=10)
        assert self.job_pid() == new_pid, 'Closing the UI must not kill the service'
        self.app = self.start_process([str(self.bundle / 'Contents/MacOS/CorralApp')], self.app_env, 'app-reopened')
        wait_for(lambda: self.command('state')['connected'] and self.command('state')['agents'], 30)
        assert self.job_pid() == new_pid, 'Reopen must reuse the healthy owned daemon'
        assert (self.home / 'Library/Application Support/agentmirror/token').read_bytes() == self.token_before
        assert (self.home / '.pi/agent/extensions/nodeprobe-pi-activity.js').stat().st_mtime_ns == self.plugin_mtime
        self.receipts.append({'runtime': 'PASS', 'piPID': rec['pid'], 'oldDaemonPID': self.daemon_pid, 'newDaemonPID': new_pid,
                              'tokenStable': True, 'pluginStableOnReopen': True, 'autoDiscovery': True,
                              'realPiInputAndDesktopEcho': True})
        self.write_case_summary()
        print('PASS_SELF_CONTAINED_RUNTIME', flush=True)

    def cleanup(self):
        self.adopt_owned_label()
        # This unique job is the only service this runner may stop.
        subprocess.run(['launchctl', 'bootout', self.service], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if self.extra_socket.exists():
            self.tmux_on(self.extra_socket, 'kill-server')
        super().cleanup()


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--legacy-root', type=Path, required=True)
    p.add_argument('--app', type=Path, default=ROOT / '.build/CorralNativeDev.app')
    args = p.parse_args()
    run = RuntimeRun(args.legacy_root, args.app)
    try:
        run.start()
        run.verify()
    except Exception:
        (run.directory / 'failure.txt').write_text(traceback.format_exc())
        (run.directory / 'summary.json').write_text(json.dumps({'status': 'FAIL', 'identity': getattr(run, 'identity', {})}, indent=2))
        raise
    finally:
        run.cleanup()
