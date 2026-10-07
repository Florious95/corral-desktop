#!/usr/bin/env python3
"""Assemble accepted Windows/NodeProbe capabilities for Darwin, without changing them.
Build-time tools only; tmux is provided by the user's system environment.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PIN = json.loads((ROOT / 'Resources/RuntimeSources.json').read_text())


def command(*args):
    return subprocess.check_output([str(a) for a in args])


def git_file(repo, commit, path):
    return command('git', '-C', repo, 'show', f'{commit}:{path}')


def digest(data):
    return hashlib.sha256(data).hexdigest()


def macho(path):
    data = path.read_bytes()
    assert data[:4] == b'\xcf\xfa\xed\xfe' and struct.unpack_from('<I', data, 4)[0] == 0x0100000c, f'not arm64 Mach-O: {path}'


def assemble(args):
    assert digest(args.daemon.read_bytes()) == PIN['coreSHA256'], 'daemon differs from accepted Luna artifact'
    assert command('git', '-C', args.core_repository, 'rev-parse', PIN['coreCommit'] + '^{tree}').decode().strip() == PIN['coreTree']
    capability = git_file(args.core_repository, PIN['coreCommit'], PIN['coreManifestPath'])
    assert capability in args.daemon.read_bytes(), 'daemon does not embed the accepted capability bytes'
    cap = json.loads(capability)
    assert cap['platform'] == PIN['platform']
    assert cap['binary']['sha256'] == PIN['nodeprobeSHA256']
    assert cap['pi_extension']['sha256'] == PIN['piExtensionSHA256']
    assert digest(args.nodeprobe.read_bytes()) == cap['binary']['sha256']
    assert args.nodeprobe.stat().st_size == cap['binary']['size']
    macho(args.daemon)
    macho(args.nodeprobe)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.runtime-', dir=args.output.parent) as tmp:
        stage = Path(tmp)
        (stage / 'licenses').mkdir()
        shutil.copy2(args.daemon, stage / 'agentmirrord')
        shutil.copy2(args.nodeprobe, stage / 'nodeprobe')
        (stage / 'core-capability.json').write_bytes(capability)
        (stage / 'core-build.txt').write_bytes(command('go', 'version', '-m', args.daemon))
        (stage / 'licenses/Corral-Core-LICENSE').write_bytes(git_file(args.core_repository, PIN['coreCommit'], 'LICENSE'))
        coords = {'nodeprobe-pi-activity.js': cap['pi_extension']}
        coords.update({f'nodeprobe-{Path(c["path"]).name}': c for c in cap['corpora']})
        for name, coordinate in coords.items():
            data = git_file(args.windows_repository, PIN['windowsCommit'], 'src-tauri/resources/' + name)
            assert digest(data) == coordinate['sha256'], f'{name} capability mismatch'
            if 'size' in coordinate:
                assert len(data) == coordinate['size']
            (stage / name).write_bytes(data)
        for name in ['agentmirrord', 'nodeprobe']:
            (stage / name).chmod(0o755)
        assert digest((stage / 'nodeprobe').read_bytes()) == PIN['nodeprobeSHA256'], 'never re-sign the accepted nodeprobe'
        assert digest((stage / 'agentmirrord').read_bytes()) == PIN['coreSHA256']
        manifest = {'formatVersion': 1, 'platform': PIN['platform'], 'coreCommit': PIN['coreCommit'],
                    'coreTree': PIN['coreTree'], 'windowsCommit': PIN['windowsCommit'], 'files': {}}
        for path in sorted(stage.rglob('*')):
            if path.is_file():
                data = path.read_bytes()
                manifest['files'][str(path.relative_to(stage))] = {'sha256': digest(data), 'size': len(data),
                    'executable': bool(path.stat().st_mode & 0o111)}
        (stage / 'runtime-manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
        assert not args.output.exists(), 'remove/rename the previous build output explicitly before assembling'
        shutil.copytree(stage, args.output)
    print(json.dumps({'runtime': str(args.output), 'manifestSHA256': digest((args.output / 'runtime-manifest.json').read_bytes()), 'coreCommit': PIN['coreCommit']}))


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--core-repository', type=Path, required=True)
    p.add_argument('--daemon', type=Path, required=True)
    p.add_argument('--windows-repository', type=Path, required=True)
    p.add_argument('--nodeprobe', type=Path, default=Path.home() / '.local/bin/nodeprobe')
    p.add_argument('--output', type=Path, default=ROOT / '.build/runtime-bundle')
    assemble(p.parse_args())
