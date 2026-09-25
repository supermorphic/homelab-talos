"""Observational comparison of source-owned OpenBao configuration."""

from pathlib import Path
import json
import subprocess
import sys

from .configuration import SafeError, load_document
from .drift import compare, compare_inventory, sanitize

INVENTORY_ENDPOINTS = {
    'auth-method': 'sys/auth',
    'secret-mount': 'sys/mounts',
    'jwt-role': 'auth/homelab-jwt/role',
    'userpass-user': 'auth/homelab-userpass/users',
    'policy': 'sys/policies/acl',
    'issuance-role': 'kubernetes/roles',
}


def _keys(value: object, kind: str) -> set[str]:
    if not isinstance(value, dict):
        raise SafeError('incomplete-list')
    # sys/auth and sys/mounts return maps, while LIST endpoints return `keys`.
    keys = list(value) if kind in {'auth-method', 'secret-mount'} and 'keys' not in value else value.get('keys')
    if (not isinstance(keys, list) or not all(isinstance(key, str) and key for key in keys)
            or len(keys) != len(set(keys))):
        raise SafeError('incomplete-list')
    return set(keys)


def run(desired_path: Path, reader) -> dict:
    document = load_document(desired_path)
    state = reader.preflight()
    if (not isinstance(state, dict) or state.get('source_revision') != state.get('deployed_revision')
            or not state.get('source_revision')):
        raise SafeError('source-mismatch')
    phase = state.get('phase')
    if phase == 'staged-absent':
        return {'status': 'staged-absent', 'source_revision': state['source_revision'],
                'deployed_revision': state['deployed_revision']}
    if phase != 'active':
        raise SafeError('source-mismatch')
    differences = []
    snapshots = {}
    for kind, endpoint in INVENTORY_ENDPOINTS.items():
        try:
            response = reader.request('GET' if kind in {'auth-method', 'secret-mount'} else 'LIST', endpoint)
        except SafeError:
            raise SafeError('incomplete-list') from None
        expected = set(document['inventories'][kind]) | set(document['builtin_exceptions'].get(kind, []))
        differences.extend(compare_inventory(expected, _keys(response, kind), kind))
        snapshots[kind] = response
    inaccessible = False
    for spec in document['objects']:
        if spec.kind in {'auth-method', 'secret-mount'}:
            response = snapshots[spec.kind].get(spec.name)
        else:
            try:
                response = reader.request('GET', spec.path)
            except SafeError:
                response = SafeError('read-denied')
                inaccessible = True
        differences.extend(compare(spec, response))
    result = sanitize(differences, source=desired_path)
    result['status'] = 'inaccessible' if inaccessible else 'drift' if differences else 'pass'
    result['source_revision'] = state['source_revision']
    result['deployed_revision'] = state['deployed_revision']
    result['phase'] = phase
    result['observations'] = {key: state.get(key, 'inaccessible') for key in
                              ('kubernetes', 'route', 'health', 'backup')}
    if result['status'] == 'pass' and any(value != 'ready' for value in result['observations'].values()):
        result['status'] = 'inaccessible'
    return result


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(json.dumps({'status': 'inaccessible', 'classification': 'invalid-source'}))
        return 2
    root = Path(__file__).resolve().parents[2]
    desired = root / 'kubernetes/apps/security/openbao/config/desired.json'
    try:
        status = subprocess.run(['git', 'status', '--porcelain'], cwd=root,
                                capture_output=True, text=True, timeout=5, check=True)
        revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root,
                                  capture_output=True, text=True, timeout=5, check=True).stdout.strip()
        if status.stdout or len(revision) != 40:
            raise SafeError('source-mismatch')
        from .reader import DiagnosticReader
        result = run(desired, DiagnosticReader(Path(argv[1]), revision))
        print(json.dumps(result, sort_keys=True))
        return 0 if result['status'] == 'pass' else 1
    except (SafeError, OSError, subprocess.SubprocessError):
        error = sys.exc_info()[1]
        code = str(error) if isinstance(error, SafeError) else 'source-mismatch'
        print(json.dumps({'status': 'inaccessible', 'classification': code}, sort_keys=True))
        return 1


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
