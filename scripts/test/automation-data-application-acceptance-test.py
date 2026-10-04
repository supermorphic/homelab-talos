"""Independent credential-binding and denial oracles for attended acceptance."""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock

path = Path('scripts/test/lib/automation-data-application-acceptance.py')
spec = importlib.util.spec_from_file_location('acceptance', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AcceptanceTests(unittest.TestCase):
    def test_fixed_program_checks_authentication_identity_round_trip_and_exact_denials(self):
        # Execute the shipped shell program; substitute only its private filesystem paths.
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            binary = directory / 'bin'
            binary.mkdir()
            credential = directory / 'pgpass'
            credential.write_text(f'restore-postgresql:5432:{module.DATABASE}:{module.ROLE}:'
                                  'invented_password_for_fixture_only_0123456789\n')
            queries = directory / 'queries.jsonl'
            denial = directory / 'denial-state'
            psql = binary / 'psql'
            psql.write_text(f'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
query = sys.argv[sys.argv.index('--command') + 1]
with Path({str(queries)!r}).open('a') as output:
    output.write(json.dumps(query) + '\\n')
assert os.environ['PGUSER'] == {module.ROLE!r}
if os.environ.get('PGPASSWORD') == 'acceptance-wrong-password': sys.exit(1)
assert 'PGPASSWORD' not in os.environ
assert Path(os.environ['PGPASSFILE']).stat().st_mode & 0o777 == 0o600
if query.startswith('SELECT current_database()'):
    print({f'{module.DATABASE}:{module.ROLE}:{module.ROLE}'!r})
elif query.startswith('SELECT app.record_integration_fact('): pass
elif query.startswith('SELECT fact FROM app.integration_facts'):
    print('acceptance:synthetic-run')
else:
    print('ERROR: ' + Path({str(denial)!r}).read_text(), file=sys.stderr)
    sys.exit(1)
''')
            psql.chmod(0o700)
            program = module.client_command('restore-postgresql', 'synthetic-run')
            program = program.replace('/credentials/pgpass', str(credential))
            for name in ('application.pgpass', 'denial.out', 'denial.err'):
                program = program.replace('/tmp/' + name, str(directory / name))
            for sqlstate, succeeds in [('42501', True), ('42P01', False)]:
                denial.write_text(sqlstate)
                queries.write_text('')
                result = subprocess.run(['sh', '-eu'], input=program, capture_output=True,
                                        text=True, check=False, env={'PATH': str(binary) + ':' + os.environ['PATH']})
                self.assertEqual(result.returncode == 0, succeeds)
                self.assertNotIn('invented_password', result.stdout + result.stderr)
                recorded = [json.loads(line) for line in queries.read_text().splitlines()]
                identity, value = module.run_identity('synthetic-run')
                self.assertIn(f"SELECT app.record_integration_fact({identity},'{value}')", recorded)
                self.assertIn(f'SELECT fact FROM app.integration_facts WHERE id={identity}', recorded)
                if succeeds:
                    self.assertEqual(result.stdout, 'application_acceptance=passed\n')
                    self.assertEqual(len(recorded), 9)
                    self.assertFalse((directory / 'application.pgpass').exists())

    def test_fixed_credential_fixture_fill_and_clear_use_atomic_ownership_checks(self):
        fixture = {'apiVersion': 'v1', 'kind': 'Secret', 'type': 'Opaque',
                   'metadata': {'name': 'nocodb-restore-application-credential',
                                'namespace': 'automation-data', 'uid': 'synthetic-fixture',
                                'resourceVersion': '12',
                                'labels': {'homelab-talos/test': 'nocodb-restore-extension'},
                                'annotations': {'homelab-talos/credential-run': '',
                                                'kustomize.toolkit.fluxcd.io/ssa': 'IfNotPresent'}}, 'data': {}}
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            directory.chmod(0o700)
            module.write_restore_manifests(directory, '012345abcdef', 'synthetic-run',
                                           'invented_password_for_fixture_only_0123456789')
            completed = subprocess.CompletedProcess([], 0, stdout=json.dumps(fixture), stderr='')
            with mock.patch.object(module.subprocess, 'run', return_value=completed) as command:
                module.fill_restore_credential(Path('synthetic.config'), directory, '012345abcdef')
            self.assertEqual(command.call_count, 2)
            patch = json.loads(command.call_args.kwargs['input'])
            self.assertEqual(patch[:2], [
                {'op': 'test', 'path': '/metadata/uid', 'value': 'synthetic-fixture'},
                {'op': 'test', 'path': '/metadata/resourceVersion', 'value': '12'}])
            self.assertEqual(command.call_args.args[0][:3], ['kubectl', '--kubeconfig', 'synthetic.config'])
            self.assertNotIn('invented_password', ' '.join(command.call_args.args[0]))
            owner = json.loads((directory / 'application-credential-owner.json').read_text())
            self.assertEqual(owner, {'uid': 'synthetic-fixture', 'runHash': '012345abcdef'})
            fixture['metadata']['annotations']['homelab-talos/credential-run'] = '012345abcdef'
            completed.stdout = json.dumps(fixture)
            with mock.patch.object(module.subprocess, 'run', return_value=completed) as command:
                module.clear_restore_credential(Path('synthetic.config'), directory, '012345abcdef')
            patch = json.loads(command.call_args.kwargs['input'])
            self.assertIn({'op': 'replace', 'path': '/data', 'value': {}}, patch)
            self.assertIn({'op': 'replace', 'path': '/metadata/annotations/homelab-talos~1credential-run', 'value': ''}, patch)

    def test_fixed_credential_fixture_rejects_another_run_or_replaced_uid(self):
        fixture = {'kind': 'Secret', 'type': 'Opaque',
                   'metadata': {'name': 'nocodb-restore-application-credential', 'namespace': 'automation-data',
                                'uid': 'synthetic-other', 'resourceVersion': '12',
                                'labels': {'homelab-talos/test': 'nocodb-restore-extension'},
                                'annotations': {'homelab-talos/credential-run': 'another-run',
                                                'kustomize.toolkit.fluxcd.io/ssa': 'IfNotPresent'}},
                   'data': {'pgpass': 'c3ludGhldGlj'}}
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            directory.chmod(0o700)
            module.write_restore_manifests(directory, '012345abcdef', 'synthetic-run',
                                           'invented_password_for_fixture_only_0123456789')
            result = subprocess.CompletedProcess([], 0, stdout=json.dumps(fixture), stderr='')
            with mock.patch.object(module.subprocess, 'run', return_value=result) as command, \
                    self.assertRaisesRegex(module.PrivateFileError, 'fixture_ownership'):
                module.fill_restore_credential(Path('synthetic.config'), directory, '012345abcdef')
            self.assertEqual(command.call_count, 1)
            (directory / 'application-credential-owner.json').write_text(json.dumps({'uid': 'synthetic-owned', 'runHash': '012345abcdef'}))
            (directory / 'application-credential-owner.json').chmod(0o600)
            fixture['metadata']['annotations']['homelab-talos/credential-run'] = '012345abcdef'
            result.stdout = json.dumps(fixture)
            with mock.patch.object(module.subprocess, 'run', return_value=result) as command, \
                    self.assertRaisesRegex(module.PrivateFileError, 'fixture_ownership'):
                module.clear_restore_credential(Path('synthetic.config'), directory, '012345abcdef')
            self.assertEqual(command.call_count, 1)

    def test_wrong_extension_confirmation_stops_before_target_inspection(self):
        for scenario, base_name, base_value, extension_name in [
            ('nocodb-access.sh', 'NOCODB_ACCESS_TEST_CONFIRM', 'test:nocodb:access',
             'NOCODB_ACCESS_EXTENSION_CONFIRM'),
            ('nocodb-restore-drill.sh', 'NOCODB_RESTORE_CONFIRM', 'restore:nocodb:metadata',
             'NOCODB_RESTORE_EXTENSION_CONFIRM'),
        ]:
            result = subprocess.run(['bash', 'scripts/test/scenarios/' + scenario,
                                     '/absent-synthetic-kubeconfig'], capture_output=True, text=True, check=False,
                                    env={**os.environ, base_name: base_value, extension_name: 'wrong'})
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('extension confirmation', result.stderr)
            self.assertNotIn('Missing', result.stderr)

    def test_only_privilege_denial_is_accepted(self):
        class DatabaseError(Exception):
            sqlstate = '42P01'  # A missing fixture is not an access denial.
        with self.assertRaisesRegex(ValueError, 'privilege_denial_required'):
            module.require_denial(DatabaseError())
        DatabaseError.sqlstate = '42501'
        module.require_denial(DatabaseError())

    def test_manifest_uses_retained_password_only_for_isolated_target(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            directory.chmod(0o700)
            module.write_restore_manifests(directory, '012345abcdef', 'synthetic-run',
                                           'invented_password_for_fixture_only_0123456789')
            import yaml
            documents = list(yaml.safe_load_all((directory / 'application-probe.yaml').read_text()))
            self.assertEqual(len(documents), 1, 'the extension must not create a Secret')
            job = documents[0]
            import json
            credential = json.loads((directory / 'application-credential.json').read_text())
            self.assertEqual(credential['pgpass'],
                f'nc-restore-012345abcdef-db:5432:{module.DATABASE}:{module.ROLE}:'
                'invented_password_for_fixture_only_0123456789\n')
            pod = job['spec']['template']
            self.assertEqual(pod['metadata']['labels']['homelab-talos/role'], 'restore')
            self.assertFalse(pod['spec']['automountServiceAccountToken'])
            self.assertEqual(pod['spec']['containers'][0]['command'],
                             ['/bin/sh', '-eu', '/helpers/nocodb-application-probe.sh'])
            self.assertNotIn('args', pod['spec']['containers'][0])
            self.assertEqual(pod['spec']['volumes'][0]['secret']['secretName'],
                             'nocodb-restore-application-credential')
            command = (Path('kubernetes/apps/automation-data/postgresql/app/test-helpers') /
                       'nocodb-application-probe.sh').read_text()
            self.assertNotIn('invented-password', command)
            self.assertIn('42501', command)
            self.assertIn('env -i', command)
            self.assertNotIn('PGUSER=postgres', command)
            self.assertEqual((directory / 'application-probe.yaml').stat().st_mode & 0o777, 0o600)

    def test_unknown_target_is_rejected_before_creating_artifact(self):
        with tempfile.TemporaryDirectory() as root:
            directory = Path(root)
            directory.chmod(0o700)
            with self.assertRaises(ValueError):
                module.write_restore_manifests(directory, '../production', 'synthetic-run', 'unused')
            self.assertFalse((directory / 'application-probe.yaml').exists())


if __name__ == '__main__':
    unittest.main()
