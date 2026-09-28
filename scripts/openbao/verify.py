"""Observational comparison of source-owned OpenBao configuration."""

import json
import re
import subprocess
import sys
from pathlib import Path

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
    try:
        return _compare_live(desired_path, reader)
    except (AttributeError, TypeError, KeyError, ValueError, IndexError):
        raise SafeError('invalid-response') from None


def _compare_live(desired_path: Path, reader) -> dict:
    state = reader.preflight()
    if (not isinstance(state, dict) or state.get('source_revision') != state.get('deployed_revision')
            or not isinstance(state.get('source_revision'), str)
            or not re.fullmatch(r'[0-9a-f]{40}', state['source_revision'])):
        raise SafeError('source-mismatch')
    phase = state.get('phase')
    if phase == 'staged-absent':
        return {'status': 'staged-absent', 'source_revision': state['source_revision'],
                'deployed_revision': state['deployed_revision']}
    if phase != 'active':
        raise SafeError('source-mismatch')
    observation_keys = ('kubernetes', 'placement', 'route', 'health', 'backup', 'monitoring')
    if any(state.get(key) not in {'ready', 'inaccessible'} for key in observation_keys):
        raise SafeError('invalid-response')
    result = compare_configuration(desired_path, reader)
    result['source_revision'] = state['source_revision']
    result['deployed_revision'] = state['deployed_revision']
    result['phase'] = phase
    result['observations'] = {key: state[key] for key in observation_keys}
    if result['status'] == 'pass' and any(value != 'ready' for value in result['observations'].values()):
        result['status'] = 'inaccessible'
    return result


def compare_configuration(desired_path: Path, reader) -> dict:
    """Compare only OpenBao APIs; transport and Kubernetes checks are separate."""
    document = load_document(desired_path)
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
    return result


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(json.dumps({'status': 'inaccessible', 'classification': 'invalid-source'}))
        return 2
    root = Path(__file__).resolve().parents[2]
    try:
        status = subprocess.run(['git', 'status', '--porcelain'], cwd=root,
                                capture_output=True, text=True, timeout=5, check=True)
        revision = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=root,
                                  capture_output=True, text=True, timeout=5, check=True).stdout.strip()
        if status.stdout or len(revision) != 40:
            raise SafeError('source-mismatch')
        from .reader import ObserverReader
        reader = ObserverReader(Path(argv[1]), revision)
        state = reader.preflight()
        if state['source_revision'] != state['deployed_revision']:
            raise SafeError('source-mismatch')
        if state['phase'] == 'staged-absent':
            result = {'status': 'staged-absent', **state}
        else:
            result = reader.configuration_observation()
            result.update(source_revision=revision, deployed_revision=state['deployed_revision'],
                          phase='active', observations={key: state[key] for key in
                          ('kubernetes', 'placement', 'route', 'health', 'backup', 'monitoring')})
            if any(value != 'ready' for value in result['observations'].values()):
                result['status'] = 'inaccessible'
        print(json.dumps(result, sort_keys=True))
        return 0 if result['status'] == 'pass' else 1
    except (SafeError, OSError, subprocess.SubprocessError, AttributeError, TypeError,
            KeyError, ValueError, IndexError):
        error = sys.exc_info()[1]
        code = str(error) if isinstance(error, SafeError) else 'invalid-response'
        print(json.dumps({'status': 'inaccessible', 'classification': code}, sort_keys=True))
        return 1


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
