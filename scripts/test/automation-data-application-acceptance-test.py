"""Independent credential-binding and denial oracles for attended acceptance."""
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

path = Path('scripts/test/lib/automation-data-application-acceptance.py')
spec = importlib.util.spec_from_file_location('acceptance', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class AcceptanceTests(unittest.TestCase):
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
            secret, job = list(yaml.safe_load_all((directory / 'application-probe.yaml').read_text()))
            self.assertEqual(secret['stringData']['pgpass'],
                f'nc-restore-012345abcdef-db:5432:{module.DATABASE}:{module.ROLE}:'
                'invented_password_for_fixture_only_0123456789\n')
            pod = job['spec']['template']
            self.assertEqual(pod['metadata']['labels']['homelab-talos/role'], 'restore')
            self.assertFalse(pod['spec']['automountServiceAccountToken'])
            command = pod['spec']['containers'][0]['args'][0]
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
