#!/usr/bin/env python3
"""Build the desktop-pinned real daemon from Git, without modifying its checkout."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
COMMIT = 'a472d4437885060bc0eaf1838c9149e5242948cb'
parser = argparse.ArgumentParser()
parser.add_argument('--repository', type=Path, required=True)
args = parser.parse_args()
output = ROOT / '.build/native-acceptance-server'
output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='corral-native-server-') as directory:
    archive = subprocess.check_output(['git', '-C', str(args.repository), 'archive', COMMIT])
    subprocess.run(['tar', '-xf', '-', '-C', directory], input=archive, check=True)
    binary = output / 'agentmirrord'
    command = ['go', 'build', '-mod=readonly', '-trimpath', '-buildvcs=false', '-o', str(binary), './cmd/agentmirrord']
    subprocess.run(command, cwd=directory, check=True)
    receipt = {
        'repository': 'https://github.com/Florious95/corral-core', 'commit': COMMIT,
        'tree': subprocess.check_output(['git', '-C', str(args.repository), 'rev-parse', COMMIT+'^{tree}'], text=True).strip(),
        'go': subprocess.check_output(['go', 'version'], text=True).strip(), 'command': command,
        'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
    }
    (output / 'build.json').write_text(json.dumps(receipt, indent=2))
    print(json.dumps(receipt, indent=2))
