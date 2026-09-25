"""Fixed OpenBao diagnostic collector through the scoped Kubernetes identity."""

import os
import re
import select
import subprocess
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .configuration import SafeError, strict_json
from .verify import INVENTORY_ENDPOINTS

NAMESPACE = 'openbao'
STATEFULSET = 'openbao'
CONTAINER = 'openbao'
CONTEXT = 'homelab-diagnostic'
MAX_OUTPUT = 1_048_576
READ_PATHS = {
    'auth/homelab-jwt/config', 'auth/homelab-jwt/role/openbao-backup',
    'auth/homelab-jwt/role/openbao-acceptance', 'auth/homelab-jwt/role/openbao-config-reader',
    'auth/homelab-userpass/users/openbao-operator',
    'sys/policies/acl/openbao-operator', 'sys/policies/acl/openbao-backup',
    'sys/policies/acl/openbao-acceptance', 'sys/policies/acl/openbao-config-reader',
    'kubernetes/config', 'kubernetes/roles/openbao-acceptance',
}
LIST_PATHS = set(INVENTORY_ENDPOINTS.values())

# This body is supplied on stdin. A token exists only in the server-side shell and
# children, then is explicitly revoked. No shell tracing or raw stderr is enabled.
REMOTE_SCRIPT = '''set +x
set -eu
export BAO_ADDR=https://127.0.0.1:8200
export BAO_TLS_SERVER_NAME=openbao.lab.supermorphic.com
export BAO_MAX_RETRIES=0
BAO_TOKEN="$(bao write -field=token auth/homelab-jwt/login role=openbao-config-reader jwt=@/openbao/verify-token/token 2>/dev/null)" || exit 41
test -n "$BAO_TOKEN" || exit 41
export BAO_TOKEN
trap 'bao write -f auth/token/revoke-self >/dev/null 2>&1 || true' EXIT
case "$1" in
  GET) bao read -format=json "$2" 2>/dev/null ;;
  LIST) bao list -format=json "$2" 2>/dev/null ;;
  *) exit 42 ;;
esac
'''


def _run(argv: list[str], *, input_text: str | None = None, timeout: int = 15) -> str:
    process = None
    try:
        process = subprocess.Popen(argv, stdin=subprocess.PIPE if input_text is not None else None,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if input_text is not None:
            process.stdin.write(input_text.encode('utf-8'))
            process.stdin.close()
        deadline = time.monotonic() + timeout
        output = bytearray()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                raise SafeError('timeout')
            chunk = os.read(process.stdout.fileno(), min(65_536, MAX_OUTPUT + 1 - len(output)))
            if not chunk:
                break
            output.extend(chunk)
            if len(output) > MAX_OUTPUT:
                raise SafeError('invalid-response')
        process.wait(timeout=max(0.1, deadline - time.monotonic()))
        if process.returncode != 0:
            raise SafeError('read-denied')
        return output.decode('utf-8')
    except (OSError, subprocess.TimeoutExpired, UnicodeError, BrokenPipeError):
        raise SafeError('timeout') from None
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait()
        if process is not None and process.stdout is not None:
            process.stdout.close()


def _json(argv: list[str]) -> dict:
    value = strict_json(_run(argv), 'invalid-response')
    if not isinstance(value, dict):
        raise SafeError('invalid-response')
    return value


def _ready(resource: dict) -> bool:
    return any(item.get('type') == 'Ready' and item.get('status') == 'True'
               for item in resource.get('status', {}).get('conditions', []))


def route_ready(route: dict) -> bool:
    parents = route.get('status', {}).get('parents', [])
    return any(
        parent.get('parentRef', {}).get('name') == 'internal'
        and parent.get('parentRef', {}).get('namespace') == 'networking'
        and {'Accepted', 'ResolvedRefs'} <= {
            condition.get('type') for condition in parent.get('conditions', [])
            if condition.get('status') == 'True'
        }
        for parent in parents
    )


def backup_fresh(cronjob: dict) -> bool:
    if cronjob.get('spec', {}).get('suspend') is not False:
        return False
    value = cronjob.get('status', {}).get('lastSuccessfulTime')
    if not isinstance(value, str):
        return False
    try:
        succeeded = datetime.fromisoformat(value.replace('Z', '+00:00'))
        age = datetime.now(timezone.utc) - succeeded
    except (ValueError, TypeError):
        return False
    return timedelta(0) <= age <= timedelta(hours=36)


def source_phase(path: Path) -> str:
    """Require all four source Flux units to agree on their activation phase."""
    expected = {'openbao-prerequisites', 'openbao', 'openbao-access', 'openbao-acceptance'}
    try:
        docs = path.read_text().split('---')
    except OSError:
        raise SafeError('invalid-source') from None
    states = {}
    for document in docs:
        name = re.search(r'^\s*name:\s*(openbao(?:-prerequisites|-access|-acceptance)?)\s*$',
                         document, re.MULTILINE)
        suspended = re.search(r'^\s*suspend:\s*(true|false)\s*$', document, re.MULTILINE)
        if name and suspended:
            if name.group(1) in states:
                raise SafeError('invalid-source')
            states[name.group(1)] = suspended.group(1) == 'true'
    if set(states) != expected or len(set(states.values())) != 1:
        raise SafeError('source-mismatch')
    return 'staged-absent' if all(states.values()) else 'active'


def source_image(path: Path) -> str:
    try:
        values = path.read_text()
    except OSError:
        raise SafeError('invalid-source') from None
    tags = re.findall(r'^\s*tag:\s*"(2\.7\.0@sha256:[0-9a-f]{64})"\s*$', values, re.MULTILINE)
    if len(tags) != 1:
        raise SafeError('invalid-source')
    return 'quay.io/openbao/openbao:' + tags[0]


class DiagnosticReader:
    def __init__(self, kubeconfig: Path, source_revision: str):
        if not kubeconfig.is_file() or not re.fullmatch(r'[0-9a-f]{40}', source_revision):
            raise SafeError('invalid-source')
        self.kubeconfig = kubeconfig
        self.source_revision = source_revision
        self._pod_name = None
        self._pod_uid = None
        self._namespace_uid = None
        self._statefulset_uid = None
        self.configuration_requests = []
        self.used_broader_identity = False

    def _kubectl(self, *args: str) -> list[str]:
        return ['kubectl', '--kubeconfig', str(self.kubeconfig), '--context', CONTEXT, *args]

    def _get(self, namespace: str, kind: str, name: str) -> dict:
        return _json(self._kubectl('--namespace', namespace, 'get', kind, name, '-o', 'json',
                                   '--request-timeout=10s'))

    def preflight(self) -> dict:
        root = Path(__file__).resolve().parents[2]
        phase = source_phase(root / 'kubernetes/apps/security/openbao/ks.yaml')
        expected_image = source_image(root / 'kubernetes/apps/security/openbao/app/values.yaml')
        repository = self._get('flux-system', 'gitrepository', 'flux-system')
        revision = repository.get('status', {}).get('artifact', {}).get('revision', '')
        match = re.fullmatch(r'main@sha1:([0-9a-f]{40})', revision)
        if not match:
            raise SafeError('source-mismatch')
        deployed = match.group(1)
        units = [self._get('flux-system', 'kustomization', name) for name in
                 ('openbao-prerequisites', 'openbao', 'openbao-access', 'openbao-acceptance')]
        if phase == 'staged-absent' and all(unit.get('spec', {}).get('suspend') is True for unit in units):
            absent = _run(self._kubectl('get', 'namespace', NAMESPACE, '--ignore-not-found',
                                        '-o', 'json', '--request-timeout=10s'))
            if not absent.strip():
                return {'source_revision': self.source_revision, 'deployed_revision': deployed,
                        'phase': 'staged-absent'}
        if phase != 'active':
            raise SafeError('source-mismatch')
        if not all(unit.get('spec', {}).get('suspend') is False and _ready(unit)
                   and self.source_revision in unit.get('status', {}).get('lastAppliedRevision', '')
                   for unit in units):
            raise SafeError('source-mismatch')
        namespace = self._get(NAMESPACE, 'namespace', NAMESPACE)
        statefulset = self._get(NAMESPACE, 'statefulset', STATEFULSET)
        self._namespace_uid = namespace.get('metadata', {}).get('uid')
        self._statefulset_uid = statefulset.get('metadata', {}).get('uid')
        template_containers = statefulset.get('spec', {}).get('template', {}).get('spec', {}).get('containers', [])
        if (namespace.get('metadata', {}).get('name') != NAMESPACE
                or statefulset.get('metadata', {}).get('name') != STATEFULSET
                or statefulset.get('metadata', {}).get('namespace') != NAMESPACE
                or not self._namespace_uid or not self._statefulset_uid
                or statefulset.get('spec', {}).get('replicas') != 3
                or len([c for c in template_containers if c.get('name') == CONTAINER
                        and c.get('image') == expected_image]) != 1):
            raise SafeError('source-mismatch')
        pods = _json(self._kubectl('--namespace', NAMESPACE, 'get', 'pods', '-l',
                                   'app.kubernetes.io/name=openbao,app.kubernetes.io/instance=openbao,component=server',
                                   '-o', 'json', '--request-timeout=10s')).get('items')
        if not isinstance(pods, list) or len(pods) != 3:
            raise SafeError('source-mismatch')
        candidates = []
        for pod in pods:
            name = pod.get('metadata', {}).get('name')
            owners = pod.get('metadata', {}).get('ownerReferences', [])
            containers = pod.get('spec', {}).get('containers', [])
            if (name not in {'openbao-0', 'openbao-1', 'openbao-2'}
                    or pod.get('metadata', {}).get('namespace') != NAMESPACE
                    or not any(o.get('uid') == self._statefulset_uid and o.get('kind') == 'StatefulSet'
                               for o in owners)
                    or pod.get('spec', {}).get('serviceAccountName') != 'openbao'
                    or len([c for c in containers if c.get('name') == CONTAINER
                            and c.get('image') == expected_image]) != 1
                    or not pod.get('metadata', {}).get('uid')):
                raise SafeError('source-mismatch')
            if _ready(pod):
                candidates.append(pod)
        if not candidates:
            raise SafeError('read-denied')
        selected = sorted(candidates, key=lambda pod: pod['metadata']['name'])[0]
        self._pod_name = selected['metadata']['name']
        self._pod_uid = selected['metadata']['uid']
        self._expected_image = expected_image
        # These observations are bounded metadata reads. Missing integrations are
        # represented as inaccessible and can never produce a passing result.
        observations = {'kubernetes': 'ready' if len(candidates) == 3 else 'inaccessible',
                        'route': 'inaccessible',
                        'health': 'ready' if len(candidates) == 3 else 'inaccessible',
                        'backup': 'inaccessible'}
        try:
            route = self._get(NAMESPACE, 'httproute', 'openbao')
            observations['route'] = 'ready' if route_ready(route) else 'inaccessible'
        except SafeError:
            pass
        try:
            cronjob = self._get(NAMESPACE, 'cronjob', 'openbao-backup')
            observations['backup'] = 'ready' if backup_fresh(cronjob) else 'inaccessible'
        except SafeError:
            pass
        return {'source_revision': self.source_revision, 'deployed_revision': deployed,
                'phase': 'active', **observations}

    def request(self, method: str, path: str) -> object:
        if not ((method == 'GET' and path in READ_PATHS | {'sys/auth', 'sys/mounts'})
                or (method == 'LIST' and path in LIST_PATHS - {'sys/auth', 'sys/mounts'})):
            raise SafeError('invalid-source')
        if not self._pod_name or not self._pod_uid:
            raise SafeError('source-mismatch')
        pod = self._get(NAMESPACE, 'pod', self._pod_name)
        if (pod.get('metadata', {}).get('uid') != self._pod_uid
                or pod.get('metadata', {}).get('namespace') != NAMESPACE
                or not _ready(pod)
                or pod.get('spec', {}).get('serviceAccountName') != 'openbao'
                or not any(o.get('uid') == self._statefulset_uid for o in
                           pod.get('metadata', {}).get('ownerReferences', []))
                or not any(c.get('name') == CONTAINER for c in pod.get('spec', {}).get('containers', []))):
            raise SafeError('source-mismatch')
        if (getattr(self, '_expected_image', None) is not None and
                not any(c.get('name') == CONTAINER and c.get('image') == self._expected_image
                        for c in pod.get('spec', {}).get('containers', []))):
            raise SafeError('source-mismatch')
        self.configuration_requests.append((method, path))
        output = _run(self._kubectl('--namespace', NAMESPACE, 'exec', '-i', self._pod_name,
                                    '-c', CONTAINER, '--', 'sh', '-s', '--', method, path),
                      input_text=REMOTE_SCRIPT, timeout=20)
        value = strict_json(output, 'invalid-response')
        if method == 'LIST':
            if not isinstance(value, list):
                raise SafeError('incomplete-list')
            return {'keys': value}
        if not isinstance(value, dict) or not isinstance(value.get('data'), dict):
            raise SafeError('invalid-response')
        return value['data']
