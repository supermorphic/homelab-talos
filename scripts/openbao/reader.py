"""Observer-only Kubernetes checks and source-bound OpenBao reader evidence."""

import os
import re
import select
import subprocess
import time
from datetime import UTC, datetime, timedelta
from pathlib import Path

from .configuration import SafeError, strict_json
from .exporter import (  # re-export for existing acceptance callers
    decode_observation,
)
from .issuer import volume as issuer_volume

NAMESPACE = 'openbao'
STATEFULSET = 'openbao'
CONTAINER = 'openbao'
CONTEXT = 'homelab-observer'
MAX_OUTPUT = 1_048_576

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
        succeeded = datetime.fromisoformat(value)
        age = datetime.now(UTC) - succeeded
    except (ValueError, TypeError):
        return False
    return timedelta(0) <= age <= timedelta(hours=36)


def placement_ready(pods: list[dict]) -> bool:
    try:
        names = [pod['metadata']['name'] for pod in pods]
        nodes = [pod['spec']['nodeName'] for pod in pods]
        return (set(names) == {'openbao-0', 'openbao-1', 'openbao-2'}
                and len(names) == 3 and all(isinstance(node, str) and node for node in nodes)
                and len(set(nodes)) == 3)
    except (AttributeError, TypeError, KeyError):
        return False



def monitoring_ready(service: dict, monitor: dict, rules: dict) -> bool:
    try:
        labels = service['metadata']['labels']
        ports = service['spec']['ports']
        endpoints = monitor['spec']['endpoints']
        groups = rules['spec']['groups']
        return (
            service['metadata']['name'] == 'openbao-monitoring'
            and service['metadata']['namespace'] == NAMESPACE
            and monitor['metadata']['name'] == 'openbao'
            and monitor['metadata']['namespace'] == NAMESPACE
            and rules['metadata']['name'] == 'openbao'
            and rules['metadata']['namespace'] == NAMESPACE
            and len(ports) == 1 and ports[0]['name'] == 'monitoring'
            and ports[0]['port'] == 8203 and ports[0]['targetPort'] == 'monitoring'
            and ports[0].get('protocol', 'TCP') == 'TCP'
            and service['spec']['selector'] == {
                'app.kubernetes.io/name': 'openbao',
                'app.kubernetes.io/instance': 'openbao', 'component': 'server'}
            and all(labels.get(key) == value for key, value in
                    monitor['spec']['selector']['matchLabels'].items())
            and bool(monitor['spec']['selector']['matchLabels'])
            and len(endpoints) == 1 and endpoints[0]['port'] == 'monitoring'
            and endpoints[0]['path'] == '/v1/sys/metrics'
            and endpoints[0]['params']['format'] == ['prometheus']
            and endpoints[0]['scheme'] == 'https'
            and endpoints[0]['tlsConfig']['serverName'] == 'openbao.lab.supermorphic.com'
            and endpoints[0]['tlsConfig'].get('insecureSkipVerify') is not True
            and any(isinstance(group['rules'], list)
                    and any(isinstance(rule.get('alert'), str) and rule['alert'] for rule in group['rules'])
                    for group in groups)
        )
    except (AttributeError, TypeError, KeyError, ValueError):
        return False


def source_phase(path: Path) -> str:
    """Require all six source Flux units to agree on their activation phase."""
    expected = {'openbao-prerequisites', 'openbao', 'openbao-access',
                'openbao-acceptance', 'openbao-backup', 'openbao-monitoring'}
    try:
        docs = path.read_text().split('---')
    except OSError:
        raise SafeError('invalid-source') from None
    states = {}
    for document in docs:
        name = re.search(r'^\s*name:\s*(openbao(?:-prerequisites|-access|-acceptance|-backup|-monitoring)?)\s*$',
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


class ObserverReader:
    def __init__(self, kubeconfig: Path, source_revision: str):
        if not kubeconfig.is_file() or not re.fullmatch(r'[0-9a-f]{40}', source_revision):
            raise SafeError('invalid-source')
        self.kubeconfig = kubeconfig
        self.source_revision = source_revision
        self._pod_name = None
        self._pod_uid = None
        self._namespace_uid = None
        self._statefulset_uid = None
        self._configuration = None

    def _kubectl(self, *args: str) -> list[str]:
        return ['kubectl', '--kubeconfig', str(self.kubeconfig), '--context', CONTEXT, *args]

    def _get(self, namespace: str, kind: str, name: str) -> dict:
        return _json(self._kubectl('--namespace', namespace, 'get', kind, name, '-o', 'json',
                                   '--request-timeout=10s'))

    def preflight(self) -> dict:
        try:
            return self._preflight()
        except (AttributeError, TypeError, KeyError, ValueError, IndexError):
            raise SafeError('invalid-response') from None

    def _preflight(self) -> dict:
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
                 ('openbao-prerequisites', 'openbao', 'openbao-access', 'openbao-acceptance',
                  'openbao-backup', 'openbao-monitoring')]
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
        self._pod_uids = {}
        self._pod_nodes = {}
        expected_issuer = issuer_volume()
        for pod in pods:
            if expected_issuer not in pod.get('spec', {}).get('volumes', []):
                raise SafeError('source-mismatch')
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
            if name in self._pod_uids:
                raise SafeError('source-mismatch')
            self._pod_uids[name] = pod['metadata']['uid']
            self._pod_nodes[name] = pod.get('spec', {}).get('nodeName')
            if _ready(pod):
                candidates.append(pod)
        if not candidates:
            raise SafeError('read-denied')
        # These observations are bounded metadata reads. Missing integrations are
        # represented as inaccessible and can never produce a passing result.
        observations = {'kubernetes': 'ready' if len(candidates) == 3 else 'inaccessible',
                        'placement': 'ready' if placement_ready(pods) else 'inaccessible',
                        'route': 'inaccessible',
                        'health': 'inaccessible', 'backup': 'inaccessible',
                        'monitoring': 'inaccessible'}
        try:
            observations['health'] = self.configuration_observation()['health']
        except SafeError:
            pass
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
        try:
            service = self._get(NAMESPACE, 'service', 'openbao-monitoring')
            monitor = self._get(NAMESPACE, 'servicemonitor', 'openbao')
            rules = self._get(NAMESPACE, 'prometheusrule', 'openbao')
            observations['monitoring'] = ('ready' if monitoring_ready(service, monitor, rules)
                                          else 'inaccessible')
        except SafeError:
            pass
        return {'source_revision': self.source_revision, 'deployed_revision': deployed,
                'phase': 'active', **observations}

    def configuration_observation(self):
        if self._configuration is None:
            query = 'openbao_configuration_observation{namespace="openbao",service="openbao-config-reader",endpoint="metrics"}'
            response = _run(['bash', '-c',
                ('source scripts/lib/network.sh; source scripts/lib/flux-alerts.sh; '
                'flux_alerts_prometheus_query https://prometheus.lab.supermorphic.com '
                '"prometheus.lab.supermorphic.com:443:${HOMELAB_GATEWAY_VIP}" "$1"'),
                'openbao-observe', query], timeout=25)
            desired = Path(__file__).resolve().parents[2] / 'kubernetes/apps/security/openbao/config/desired.json'
            self._configuration = decode_observation(strict_json(response, 'invalid-response'), desired)
        return dict(self._configuration)
