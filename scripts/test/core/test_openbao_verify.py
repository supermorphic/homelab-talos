import json
import copy
import unittest
from pathlib import Path

from scripts.openbao.configuration import SafeError, load_document
from scripts.openbao.verify import run
from scripts.openbao.reader import (DiagnosticReader, source_phase, _run, route_ready,
                                    backup_fresh, placement_ready, health_quorum,
                                    monitoring_ready)
from unittest.mock import patch
import tempfile
import sys
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[3]
DESIRED = ROOT / 'kubernetes/apps/security/openbao/config/desired.json'

# Handwritten OpenBao 2.7 API shapes. These are intentionally independent of
# desired.json so a source edit cannot silently rewrite the live oracle.
AUTH_MOUNTS = {
    'homelab-jwt/': {'type': 'jwt', 'description': 'Homelab machine JWT authentication',
                     'config': {'default_lease_ttl': '10m', 'max_lease_ttl': '600s',
                                'force_no_cache': False, 'token_type': 'default-service'},
                     'local': False, 'seal_wrap': False},
    'homelab-userpass/': {'type': 'userpass', 'description': 'Homelab operator login',
                          'config': {'default_lease_ttl': '1h', 'max_lease_ttl': '3600s',
                                     'force_no_cache': False, 'token_type': 'default-service'},
                          'local': False, 'seal_wrap': False},
    'token/': {'type': 'token'},
}
SECRET_MOUNTS = {
    'kubernetes/': {'type': 'kubernetes', 'description': 'Bound Kubernetes TokenRequest issuance',
                    'config': {'default_lease_ttl': '600s', 'max_lease_ttl': '10m',
                               'force_no_cache': False}, 'local': False, 'seal_wrap': False},
    'cubbyhole/': {'type': 'cubbyhole'}, 'identity/': {'type': 'identity'},
    'sys/': {'type': 'system'},
}


def jwt_role(subject, audience, policy):
    return {'role_type': 'jwt', 'bound_audiences': [audience], 'bound_subject': subject,
            'user_claim': 'sub', 'token_policies': [policy],
            'token_no_default_policy': True,
            'token_ttl': '5m' if policy == 'openbao-config-reader' else '10m',
            'token_max_ttl': 300 if policy == 'openbao-config-reader' else 600,
            'token_type': 'service'}


READER_CAPABILITIES = {
    'sys/auth': 'read', 'sys/mounts': 'read',
    'sys/storage/raft/configuration': 'read', 'sys/policies/acl': 'list',
    'auth/homelab-jwt/config': 'read', 'auth/homelab-jwt/role': 'list',
    'auth/homelab-userpass/users': 'list', 'kubernetes/config': 'read',
    'kubernetes/roles': 'list', 'auth/token/revoke-self': 'update',
}
for policy_name in ('openbao-operator', 'openbao-backup', 'openbao-acceptance',
                    'openbao-config-reader'):
    READER_CAPABILITIES[f'sys/policies/acl/{policy_name}'] = 'read'
for role_name in ('openbao-backup', 'openbao-acceptance', 'openbao-config-reader'):
    READER_CAPABILITIES[f'auth/homelab-jwt/role/{role_name}'] = 'read'
READER_CAPABILITIES['auth/homelab-userpass/users/openbao-operator'] = 'read'
READER_CAPABILITIES['kubernetes/roles/openbao-acceptance'] = 'read'


def policy(paths):
    return {'policy': json.dumps({'path': {path: {'capabilities': capabilities}
                                           for path, capabilities in paths.items()}})}


LIVE_READS = {
    'auth/homelab-jwt/config': {'bound_issuer': 'https://kubernetes.default.svc.cluster.local',
                                 'default_role': '', 'provider_config': {'provider': 'kubernetes'}},
    'auth/homelab-jwt/role/openbao-backup': jwt_role(
        'system:serviceaccount:openbao:openbao-backup', 'openbao-kubernetes-broker',
        'openbao-backup'),
    'auth/homelab-jwt/role/openbao-acceptance': jwt_role(
        'system:serviceaccount:openbao-acceptance:openbao-acceptance',
        'openbao-kubernetes-broker', 'openbao-acceptance'),
    'auth/homelab-jwt/role/openbao-config-reader': jwt_role(
        'system:serviceaccount:openbao:openbao', 'openbao-config-verification',
        'openbao-config-reader'),
    'auth/homelab-userpass/users/openbao-operator': {
        'policies': ['openbao-operator'], 'token_no_default_policy': True,
        'token_ttl': '1h', 'token_max_ttl': 3600},
    'sys/policies/acl/openbao-operator': policy({
        '*': ['sudo', 'list', 'delete', 'update', 'read', 'create']}),
    'sys/policies/acl/openbao-backup': policy({
        'sys/storage/raft/snapshot': ['read'], 'auth/token/revoke-self': ['update']}),
    'sys/policies/acl/openbao-acceptance': policy({
        'kubernetes/creds/openbao-acceptance': ['update'],
        'auth/token/revoke-self': ['update']}),
    'sys/policies/acl/openbao-config-reader': policy({
        path: [capability] for path, capability in READER_CAPABILITIES.items()}),
    'kubernetes/config': {'kubernetes_host': 'https://kubernetes.default.svc:443',
                          'disable_local_ca_jwt': False},
    'kubernetes/roles/openbao-acceptance': {
        'allowed_kubernetes_namespaces': ['openbao-acceptance'],
        'allowed_kubernetes_namespace_selector': '',
        'service_account_name': 'openbao-issued-reader', 'kubernetes_role_name': '',
        'generated_role_rules': '', 'token_default_ttl': '10m', 'token_max_ttl': 600,
        'token_default_audiences': ['https://kubernetes.default.svc.cluster.local']},
}

LIVE_INVENTORIES = {
    'auth-method': list(AUTH_MOUNTS), 'secret-mount': list(SECRET_MOUNTS),
    'jwt-role': ['openbao-backup', 'openbao-acceptance', 'openbao-config-reader'],
    'userpass-user': ['openbao-operator'],
    'policy': ['default', 'root', 'openbao-operator', 'openbao-backup',
               'openbao-acceptance', 'openbao-config-reader'],
    'issuance-role': ['openbao-acceptance'],
}


class FakeReader:
    def __init__(self):
        self.configuration_requests = []
        self.used_broader_identity = False
        self.source_revision = 'a' * 40
        self.deployed_revision = 'a' * 40
        self.phase = 'active'
        self.fail_path = None
        self.inventories = copy.deepcopy(LIVE_INVENTORIES)

    def preflight(self):
        return {'source_revision': self.source_revision, 'deployed_revision': self.deployed_revision,
                'phase': self.phase, 'kubernetes': 'ready', 'placement': 'ready',
                'route': 'ready', 'health': 'ready', 'backup': 'ready',
                'monitoring': 'ready'}

    def request(self, method, path):
        self.configuration_requests.append((method, path))
        if path == self.fail_path:
            raise SafeError('read-denied')
        if path in {'sys/auth', 'sys/mounts', 'auth/homelab-jwt/role',
                    'auth/homelab-userpass/users', 'sys/policies/acl', 'kubernetes/roles'}:
            kind = next(kind for kind, endpoint in {
                'auth-method': 'sys/auth', 'secret-mount': 'sys/mounts',
                'jwt-role': 'auth/homelab-jwt/role', 'userpass-user': 'auth/homelab-userpass/users',
                'policy': 'sys/policies/acl', 'issuance-role': 'kubernetes/roles'}.items()
                if endpoint == path)
            if kind in {'auth-method', 'secret-mount'}:
                originals = AUTH_MOUNTS if kind == 'auth-method' else SECRET_MOUNTS
                return {name: copy.deepcopy(originals.get(name, {'type': 'system'}))
                        for name in self.inventories[kind]}
            return {'keys': self.inventories[kind]}
        return copy.deepcopy(LIVE_READS[path])


class VerifyTest(unittest.TestCase):
    def test_active_preflight_uses_independent_health_placement_monitoring(self):
        with tempfile.TemporaryDirectory() as directory:
            kubeconfig = Path(directory) / 'config'
            kubeconfig.write_text('synthetic')
            reader = DiagnosticReader(kubeconfig, 'a' * 40)
            ready = {'conditions': [{'type': 'Ready', 'status': 'True'}]}
            pods = [{'metadata': {'name': f'openbao-{i}', 'namespace': 'openbao',
                                  'uid': f'pod-{i}', 'ownerReferences': [
                                      {'uid': 'statefulset-uid', 'kind': 'StatefulSet'}]},
                     'spec': {'nodeName': f'node-{i}', 'serviceAccountName': 'openbao',
                              'containers': [{'name': 'openbao', 'image': 'synthetic-image'}]},
                     'status': ready} for i in range(3)]
            service = {'metadata': {'name': 'openbao-monitoring', 'namespace': 'openbao',
                                    'labels': {'app.kubernetes.io/name': 'openbao'}},
                       'spec': {'selector': {'app.kubernetes.io/name': 'openbao',
                                             'app.kubernetes.io/instance': 'openbao',
                                             'component': 'server'},
                                'ports': [{'name': 'monitoring', 'port': 8203,
                                           'targetPort': 'monitoring'}]}}
            monitor = {'metadata': {'name': 'openbao', 'namespace': 'openbao'},
                       'spec': {'selector': {'matchLabels': {'app.kubernetes.io/name': 'openbao'}},
                                'endpoints': [{'port': 'monitoring', 'path': '/v1/sys/metrics',
                                               'params': {'format': ['prometheus']},
                                               'scheme': 'https', 'tlsConfig': {
                                                   'serverName': 'openbao.lab.supermorphic.com'}}]}}
            rules = {'metadata': {'name': 'openbao', 'namespace': 'openbao'},
                     'spec': {'groups': [{'rules': [{'alert': 'OpenBaoSealed', 'expr': 'up == 0'}]}]}}
            objects = {
                ('flux-system', 'gitrepository', 'flux-system'): {
                    'status': {'artifact': {'revision': 'main@sha1:' + 'a' * 40}}},
                ('openbao', 'namespace', 'openbao'): {'metadata': {'name': 'openbao',
                                                                  'uid': 'namespace-uid'}},
                ('openbao', 'statefulset', 'openbao'): {
                    'metadata': {'name': 'openbao', 'namespace': 'openbao',
                                 'uid': 'statefulset-uid'},
                    'spec': {'replicas': 3, 'template': {'spec': {'containers': [
                        {'name': 'openbao', 'image': 'synthetic-image'}]}}}},
                ('openbao', 'httproute', 'openbao'): {'status': {'parents': [{
                    'parentRef': {'name': 'internal', 'namespace': 'networking'},
                    'conditions': [{'type': 'Accepted', 'status': 'True'},
                                   {'type': 'ResolvedRefs', 'status': 'True'}]}]}},
                ('openbao', 'cronjob', 'openbao-backup'): {
                    'spec': {'suspend': False}, 'status': {'lastSuccessfulTime':
                        datetime.now(timezone.utc).isoformat()}},
                ('openbao', 'service', 'openbao-monitoring'): service,
                ('openbao', 'servicemonitor', 'openbao'): monitor,
                ('openbao', 'prometheusrule', 'openbao'): rules,
            }
            for name in ('openbao-prerequisites', 'openbao', 'openbao-access',
                         'openbao-acceptance'):
                objects[('flux-system', 'kustomization', name)] = {
                    'spec': {'suspend': False},
                    'status': {**ready, 'lastAppliedRevision': 'main@sha1:' + 'a' * 40}}
            statuses = {f'openbao-{i}': {'initialized': True, 'sealed': False,
                        'storage_type': 'raft', 'ha_enabled': True,
                        'cluster_id': 'synthetic-cluster', **({'is_self': True} if i == 1 else {})}
                        for i in range(3)}
            raft = {'config': {'servers': [{'node_id': f'openbao-{i}',
                    'voter': True, 'leader': i == 1} for i in range(3)]}}
            with (patch('scripts.openbao.reader.source_phase', return_value='active'),
                  patch('scripts.openbao.reader.source_image', return_value='synthetic-image'),
                  patch('scripts.openbao.reader._json', return_value={'items': pods}),
                  patch.object(reader, '_get', side_effect=lambda ns, kind, name:
                               objects[(ns, kind, name)]),
                  patch.object(reader, '_status', side_effect=lambda name: statuses[name]),
                  patch.object(reader, 'request', return_value=raft) as raft_read):
                observed = reader.preflight()
                self.assertEqual(observed['health'], 'ready')
                self.assertEqual(observed['placement'], 'ready')
                self.assertEqual(observed['monitoring'], 'ready')
                raft_read.assert_called_once_with('GET', 'sys/storage/raft/configuration')
                statuses['openbao-2']['sealed'] = True
                observed = reader.preflight()
                self.assertEqual(observed['health'], 'inaccessible')
                pods[2]['spec']['nodeName'] = 'node-1'
                observed = reader.preflight()
                self.assertEqual(observed['placement'], 'inaccessible')

    def test_independent_placement_health_and_raft_oracles(self):
        pods = [{'metadata': {'name': f'openbao-{index}'},
                 'spec': {'nodeName': f'node-{index}'}} for index in range(3)]
        statuses = {f'openbao-{index}': {'initialized': True, 'sealed': False,
                    'storage_type': 'raft', 'ha_enabled': True,
                    'cluster_id': 'synthetic-cluster', **({'is_self': True} if index == 1 else {})}
                    for index in range(3)}
        raft = {'config': {'servers': [
            {'node_id': f'openbao-{index}', 'voter': True, 'leader': index == 1}
            for index in range(3)]}}
        self.assertTrue(placement_ready(pods))
        self.assertTrue(health_quorum(statuses, raft))
        moved = json.loads(json.dumps(pods))
        moved[2]['spec']['nodeName'] = 'node-1'
        self.assertFalse(placement_ready(moved))
        sealed = json.loads(json.dumps(statuses))
        sealed['openbao-2']['sealed'] = True
        self.assertFalse(health_quorum(sealed, raft))
        nonvoter = json.loads(json.dumps(raft))
        nonvoter['config']['servers'][2]['voter'] = False
        self.assertFalse(health_quorum(statuses, nonvoter))
        two_leaders = json.loads(json.dumps(raft))
        two_leaders['config']['servers'][2]['leader'] = True
        self.assertFalse(health_quorum(statuses, two_leaders))

    def test_monitoring_requires_fixed_service_endpoint_and_alert_rules(self):
        service = {'metadata': {'name': 'openbao-monitoring', 'namespace': 'openbao',
                   'labels': {'app.kubernetes.io/name': 'openbao'}},
                   'spec': {'selector': {'app.kubernetes.io/name': 'openbao',
                                         'app.kubernetes.io/instance': 'openbao',
                                         'component': 'server'},
                            'ports': [{'name': 'monitoring', 'port': 8203,
                                       'targetPort': 'monitoring'}]}}
        monitor = {'metadata': {'name': 'openbao', 'namespace': 'openbao'},
                   'spec': {'selector': {'matchLabels': {'app.kubernetes.io/name': 'openbao'}},
                            'endpoints': [{'port': 'monitoring', 'path': '/v1/sys/metrics',
                                           'params': {'format': ['prometheus']},
                                           'scheme': 'https', 'tlsConfig': {
                                               'serverName': 'openbao.lab.supermorphic.com'}}]}}
        rules = {'metadata': {'name': 'openbao', 'namespace': 'openbao'},
                 'spec': {'groups': [{'name': 'openbao', 'rules': [{'alert': 'OpenBaoSealed',
                                                                  'expr': 'up == 0'}]}]}}
        self.assertTrue(monitoring_ready(service, monitor, rules))
        missing_rules = json.loads(json.dumps(rules))
        missing_rules['spec']['groups'][0]['rules'] = []
        self.assertFalse(monitoring_ready(service, monitor, missing_rules))
        wrong_path = json.loads(json.dumps(monitor))
        wrong_path['spec']['endpoints'][0]['path'] = '/health'
        self.assertFalse(monitoring_ready(service, wrong_path, rules))
        wrong_format = json.loads(json.dumps(monitor))
        wrong_format['spec']['endpoints'][0]['params']['format'] = ['json']
        self.assertFalse(monitoring_ready(service, wrong_format, rules))
        wrong_tls = json.loads(json.dumps(monitor))
        wrong_tls['spec']['endpoints'][0]['tlsConfig']['serverName'] = 'other.example'
        self.assertFalse(monitoring_ready(service, wrong_tls, rules))
        broad_service = json.loads(json.dumps(service))
        broad_service['spec']['selector'] = {'app.kubernetes.io/name': 'openbao'}
        self.assertFalse(monitoring_ready(broad_service, monitor, rules))

    def test_malformed_kubernetes_shape_raises_fixed_safe_error(self):
        with tempfile.TemporaryDirectory() as directory:
            kubeconfig = Path(directory) / 'config'
            kubeconfig.write_text('synthetic')
            reader = DiagnosticReader(kubeconfig, 'a' * 40)
            with patch.object(reader, '_get', return_value={'status': ['synthetic-private-marker']}):
                with self.assertRaises(SafeError) as caught:
                    reader.preflight()
            self.assertEqual(str(caught.exception), 'invalid-response')
            self.assertNotIn('synthetic-private-marker', str(caught.exception))

    def test_route_and_backup_observations_require_real_conditions(self):
        route = {'status': {'parents': [{'parentRef': {'name': 'internal', 'namespace': 'networking'},
            'conditions': [
            {'type': 'Accepted', 'status': 'True'},
            {'type': 'ResolvedRefs', 'status': 'True'}]}]}}
        self.assertTrue(route_ready(route))
        self.assertFalse(route_ready({'status': {'parents': [{'conditions': [
            {'type': 'Accepted', 'status': 'False'}]}]}}))
        self.assertFalse(backup_fresh({'spec': {'suspend': False}, 'status': {}}))

    def test_collector_bounds_stdout_before_parsing(self):
        with patch('scripts.openbao.reader.MAX_OUTPUT', 16):
            with self.assertRaises(SafeError):
                _run([sys.executable, '-c', 'print("x" * 32)'])

    def test_source_phase_rejects_mixed_activation(self):
        source = ROOT / 'kubernetes/apps/security/openbao/ks.yaml'
        self.assertEqual(source_phase(source), 'staged-absent')
        with tempfile.TemporaryDirectory() as directory:
            altered = Path(directory) / 'ks.yaml'
            altered.write_text(source.read_text().replace('suspend: true', 'suspend: false', 1))
            with self.assertRaises(SafeError):
                source_phase(altered)

    def test_reader_rejects_unlisted_query_and_pod_replacement(self):
        with tempfile.TemporaryDirectory() as directory:
            kubeconfig = Path(directory) / 'config'
            kubeconfig.write_text('synthetic')
            reader = DiagnosticReader(kubeconfig, 'a' * 40)
            with self.assertRaises(SafeError):
                reader.request('POST', 'sys/auth')
            with self.assertRaises(SafeError):
                reader.request('GET', 'sys/raw')
            reader._pod_name = 'openbao-0'
            reader._pod_uid = 'expected-uid'
            reader._statefulset_uid = 'expected-owner'
            reader._pod_uids = {'openbao-0': 'expected-uid'}
            reader._pod_nodes = {'openbao-0': 'node-0'}
            reader._expected_image = 'synthetic-image'
            changed = {'metadata': {'uid': 'replacement-uid', 'ownerReferences': [
                {'uid': 'expected-owner'}]}, 'spec': {'serviceAccountName': 'openbao',
                'containers': [{'name': 'openbao'}]}, 'status': {'conditions': [
                {'type': 'Ready', 'status': 'True'}]}}
            with patch.object(reader, '_get', return_value=changed):
                with self.assertRaises(SafeError) as caught:
                    reader.request('GET', 'kubernetes/config')
            self.assertEqual(str(caught.exception), 'source-mismatch')
            self.assertEqual(reader.configuration_requests, [])

    def test_complete_inventory_and_all_reads_are_observational(self):
        reader = FakeReader()
        result = run(DESIRED, reader)
        self.assertEqual(result['status'], 'pass')
        self.assertTrue(all(method in {'GET', 'LIST'} for method, path in reader.configuration_requests))
        self.assertFalse(reader.used_broader_identity)

    def test_forbidden_reader_fails_without_raw_values(self):
        reader = FakeReader()
        reader.fail_path = 'auth/homelab-jwt/role/openbao-config-reader'
        result = run(DESIRED, reader)
        self.assertEqual(result['status'], 'inaccessible')
        self.assertNotIn('synthetic-private-marker', json.dumps(result))
        self.assertFalse(reader.used_broader_identity)

    def test_reader_role_drift_and_untrusted_names_are_sanitized(self):
        class DriftReader(FakeReader):
            def request(self, method, path):
                result = super().request(method, path)
                if path == 'auth/homelab-jwt/role/openbao-config-reader':
                    return dict(result, bound_audiences=['synthetic-private-marker'])
                return result
        reader = DriftReader()
        reader.inventories['policy'].append('synthetic-private-marker')
        result = run(DESIRED, reader)
        self.assertEqual(result['status'], 'drift')
        self.assertIn({'kind': 'jwt-role', 'name': 'openbao-config-reader',
                       'field': 'bound_audiences', 'state': 'changed'}, result['differences'])
        self.assertNotIn('synthetic-private-marker', json.dumps(result))

    def test_partial_inventory_fails_closed(self):
        reader = FakeReader()
        reader.inventories['policy'] = None
        with self.assertRaises(SafeError) as caught:
            run(DESIRED, reader)
        self.assertEqual(str(caught.exception), 'incomplete-list')

    def test_source_deployment_mismatch_blocks_reads(self):
        reader = FakeReader()
        reader.deployed_revision = 'other'
        with self.assertRaises(SafeError) as caught:
            run(DESIRED, reader)
        self.assertEqual(str(caught.exception), 'source-mismatch')
        self.assertEqual(reader.configuration_requests, [])

    def test_untrusted_observation_cannot_be_echoed(self):
        reader = FakeReader()
        original = reader.preflight
        reader.preflight = lambda: dict(original(), monitoring='synthetic-private-marker')
        with self.assertRaises(SafeError) as caught:
            run(DESIRED, reader)
        self.assertEqual(str(caught.exception), 'invalid-response')

    def test_transport_shape_error_is_safe_at_run_boundary(self):
        reader = FakeReader()
        reader.preflight = lambda: (_ for _ in ()).throw(AttributeError('synthetic-private-marker'))
        with self.assertRaises(SafeError) as caught:
            run(DESIRED, reader)
        self.assertEqual(str(caught.exception), 'invalid-response')
        self.assertNotIn('synthetic-private-marker', str(caught.exception))

    def test_staged_absence_cannot_pass(self):
        reader = FakeReader()
        reader.phase = 'staged-absent'
        result = run(DESIRED, reader)
        self.assertEqual(result['status'], 'staged-absent')
        self.assertEqual(reader.configuration_requests, [])

    def test_reader_audience_matches_projected_token(self):
        role = next(obj for obj in load_document(DESIRED)['objects']
                    if obj.kind == 'jwt-role' and obj.name == 'openbao-config-reader')
        self.assertEqual(role.fields['bound_audiences'], ['openbao-config-verification'])
        values = (ROOT / 'kubernetes/apps/security/openbao/app/values.yaml').read_text()
        self.assertIn('audience: openbao-config-verification', values)


if __name__ == '__main__':
    unittest.main()
