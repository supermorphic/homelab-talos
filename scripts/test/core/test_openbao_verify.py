import json
import unittest
from pathlib import Path

from scripts.openbao.configuration import SafeError, load_document
from scripts.openbao.verify import run
from scripts.openbao.reader import DiagnosticReader, source_phase, _run, route_ready, backup_fresh
from unittest.mock import patch
import tempfile
import sys

ROOT = Path(__file__).resolve().parents[3]
DESIRED = ROOT / 'kubernetes/apps/security/openbao/config/desired.json'


class FakeReader:
    def __init__(self):
        self.document = load_document(DESIRED)
        self.configuration_requests = []
        self.used_broader_identity = False
        self.source_revision = 'abc123'
        self.deployed_revision = 'abc123'
        self.phase = 'active'
        self.fail_path = None
        self.inventories = {kind: list(names) + self.document['builtin_exceptions'].get(kind, [])
                            for kind, names in self.document['inventories'].items()}

    def preflight(self):
        return {'source_revision': self.source_revision, 'deployed_revision': self.deployed_revision,
                'phase': self.phase, 'kubernetes': 'ready', 'route': 'ready',
                'health': 'ready', 'backup': 'ready'}

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
                return {name: dict(next(obj.fields for obj in self.document['objects']
                                        if obj.kind == kind and obj.name == name))
                        if name in self.document['inventories'][kind] else {'type': 'system'}
                        for name in self.inventories[kind]}
            return {'keys': self.inventories[kind]}
        for obj in self.document['objects']:
            if obj.path == path:
                return dict(obj.fields)
        raise AssertionError(path)


class VerifyTest(unittest.TestCase):
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
