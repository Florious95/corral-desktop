#!/usr/bin/env python3
"""Assemble accepted Windows/NodeProbe capabilities for Darwin, without changing them.
Build-time tools only; the resulting app has no Python/Homebrew runtime dependency.
"""
import argparse
import hashlib
import json
import os
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


def dependencies(path):
    return [line.strip().split(' (', 1)[0] for line in command('otool', '-L', path).decode().splitlines()[1:]]


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
        (stage / 'lib').mkdir()
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

        # Carry tmux's complete non-system dylib closure, not Homebrew absolute load paths.
        pending = [(args.tmux.resolve(), stage / 'tmux')]
        copied = {}
        kegs = set()
        while pending:
            source, target = pending.pop(0)
            if target.name in copied:
                assert copied[target.name] == source, 'dylib basename collision'
                continue
            macho(source)
            copied[target.name] = source
            shutil.copy2(source, target)
            target.chmod(0o755)
            parts = source.parts
            if 'Cellar' in parts:
                i = parts.index('Cellar')
                kegs.add(Path(*parts[:i + 3]))
            for dependency in dependencies(source):
                if dependency.startswith(('/usr/lib/', '/System/Library/')):
                    continue
                assert dependency.startswith('/'), f'unresolved source dependency: {dependency}'
                dep = Path(dependency)
                if dep.resolve() == source: # dylib's own install-name
                    command('install_name_tool', '-id', '@rpath/' + target.name, target)
                    continue
                destination = stage / 'lib' / dep.name
                replacement = '@loader_path/' + os.path.relpath(destination, target.parent)
                command('install_name_tool', '-change', dependency, replacement, target)
                pending.append((dep.resolve(), destination))
            command('codesign', '--force', '--sign', '-', target)
        for keg in sorted(kegs):
            licenses = []
            for folder in [keg, keg / 'share/doc' / keg.parent.name]:
                if folder.is_dir():
                    licenses += [p for p in folder.iterdir() if p.is_file() and p.name.upper().startswith(('LICENSE', 'LICENCE', 'COPYING', 'COPYRIGHT', 'NOTICE'))]
            assert licenses, f'missing dependency license: {keg}'
            for license in licenses:
                shutil.copy2(license, stage / 'licenses' / f'{keg.parent.name}-{license.name}')
        # The OS ships xterm-256color; include tmux's own entry when the formula provides it.
        terminfo = args.tmux.resolve().parents[1] / 'share/terminfo'
        if terminfo.is_dir():
            shutil.copytree(terminfo, stage / 'terminfo')
        for name in ['agentmirrord', 'nodeprobe', 'tmux']:
            (stage / name).chmod(0o755)
        for binary in [stage / 'tmux', *(stage / 'lib').glob('*')]:
            assert all(d.startswith(('/usr/lib/', '/System/Library/', '@loader_path/', '@rpath/')) for d in dependencies(binary)), binary
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
    p.add_argument('--tmux', type=Path, default=Path('/opt/homebrew/bin/tmux'))
    p.add_argument('--output', type=Path, default=ROOT / '.build/runtime-bundle')
    assemble(p.parse_args())
