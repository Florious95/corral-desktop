#!/usr/bin/env python3
"""Equivalent of the Windows resource verifier, including all Darwin runtime files."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
manifest = json.loads((root / 'runtime-manifest.json').read_text())
assert manifest['formatVersion'] == 1 and manifest['platform'] == 'darwin/arm64'
required = {'agentmirrord', 'nodeprobe', 'tmux', 'nodeprobe-pi-activity.js', 'nodeprobe-titles.tsv', 'nodeprobe-providers.tsv', 'core-capability.json'}
assert required <= manifest['files'].keys()
for name, expected in manifest['files'].items():
    path = root / name
    assert not name.startswith('/') and '..' not in Path(name).parts
    assert not path.is_symlink() and path.resolve().is_relative_to(root) and path.is_file()
    data = path.read_bytes()
    assert len(data) == expected['size'], name
    assert hashlib.sha256(data).hexdigest() == expected['sha256'], name
for name in ['agentmirrord', 'nodeprobe', 'tmux']:
    assert manifest['files'][name]['executable'] and (root / name).stat().st_mode & 0o111
    assert 'arm64' in subprocess.check_output(['file', str(root / name)], text=True)
raw = (root / 'core-capability.json').read_bytes()
assert raw in (root / 'agentmirrord').read_bytes()
capability = json.loads(raw)
for name, coordinate in [('nodeprobe', capability['binary']), ('nodeprobe-pi-activity.js', capability['pi_extension'])]:
    assert manifest['files'][name]['sha256'] == coordinate['sha256']
    assert manifest['files'][name]['size'] == coordinate['size']
for coordinate in capability['corpora']:
    assert manifest['files']['nodeprobe-' + Path(coordinate['path']).name]['sha256'] == coordinate['sha256']
for path in [root / 'tmux', *(root / 'lib').glob('*')]:
    dependencies = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]
    assert all(line.strip().startswith(('/usr/lib/', '/System/Library/', '@loader_path/', '@rpath/')) for line in dependencies), path
print('Runtime verified: ' + manifest['coreCommit'])
