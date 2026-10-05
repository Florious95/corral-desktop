#!/usr/bin/env python3
"""Packaged startup: explicit private token outranks an unavailable saved vault.
Uses real private daemon/PTYS; never probes or sends test traffic to 9900.
"""
import argparse
import json
from pathlib import Path
import traceback
from urllib.parse import urlsplit
from run import Run


class CredentialRun(Run):
    def start_process(self, args, env, name):
        if name == 'app':
            endpoint = urlsplit(env['CORRAL_NATIVE_ENDPOINT'])
            assert endpoint.port != 9900 and env['CORRAL_NATIVE_TOKEN']
            storage = self.directory / 'storage'
            namespace = storage / 'com.corral.native.dev'
            namespace.mkdir(parents=True, mode=0o700)
            storage.chmod(0o700)
            (namespace / 'devices.json').write_text(json.dumps([{
                'id': 'corral-native-development-endpoint', 'name': 'Saved private device',
                'endpoint': {'scheme': endpoint.scheme, 'host': endpoint.hostname, 'port': endpoint.port},
                'credentialHandle': 'intentionally-unavailable-saved-credential'}]))
            (namespace / 'devices.json').chmod(0o600)
            # The real PrivateFileCredentialVault rejects this mode on resolve.
            # A known explicit token must never consult it in the first place.
            unavailable = storage / 'credentials'
            unavailable.mkdir(mode=0o755)
            unavailable.chmod(0o755)
        return super().start_process(args, env, name)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--legacy-root', type=Path, required=True)
    args = parser.parse_args()
    run = CredentialRun(args.legacy_root, case='credential-priority')
    try:
        run.start()
        state = run.command('state')
        assert state['connected'] and state['lastError'] == ''
        assert len(state['agents']) == 4
        run.output_assertion(run.capture('authenticated-private-PTY', state), 'A')
        run.input_checks('A')
        run.write_case_summary()
        print('PASS credential priority: known token, unavailable vault bypassed, real auth/listing/PTY input', flush=True)
    except Exception:
        (run.directory / 'failure.txt').write_text(traceback.format_exc())
        (run.directory / 'summary.json').write_text(json.dumps({'status': 'FAIL', 'identity': getattr(run, 'identity', {})}, indent=2))
        raise
    finally:
        run.cleanup()
