"""Rendered application authority and independent admission request cases."""

import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
PLATFORM = ROOT / 'kubernetes/apps/applications/career-ops/platform'


def render(path):
    return list(yaml.safe_load_all(subprocess.check_output(['kustomize', 'build', str(path)], text=True)))


class ApplicationScaffoldTests(unittest.TestCase):
    def test_platform_precedes_connection(self):
        units = {d['metadata']['name']: d for d in render(ROOT / 'kubernetes/apps')}
        self.assertIn('career-ops-platform', list(units))
        self.assertIn({'name': 'career-ops-platform'}, units['career-ops-connection']['spec']['dependsOn'])
        self.assertTrue({'cilium', 'internal-gateway', 'automation-data-postgresql', 'longhorn-config',
                         'kube-prometheus-stack'} <= {d['name'] for d in units['career-ops-platform']['spec']['dependsOn']})

    def test_connection_starts_suspended(self):
        units = {d['metadata']['name']: d for d in render(ROOT / 'kubernetes/apps')}
        self.assertIn('career-ops-connection', list(units))
        self.assertIs(units['career-ops-connection']['spec']['suspend'], True)

    def test_namespace_restricts_pods_and_gateway_access(self):
        self.assertTrue(PLATFORM.is_dir(), 'platform boundary is missing')
        namespace = next(d for d in render(PLATFORM) if d['kind'] == 'Namespace')
        self.assertEqual(namespace['metadata']['name'], 'career-ops')
        self.assertEqual(namespace['metadata']['labels']['pod-security.kubernetes.io/enforce'], 'restricted')
        self.assertEqual(namespace['metadata']['labels']['gateway.supermorphic.com/access'], 'internal')
        self.assertEqual({k:v for k,v in namespace['metadata']['labels'].items() if k.startswith('gateway.')}, {'gateway.supermorphic.com/access': 'internal'})

    def test_controller_denies_remote_bases(self):
        docs = render(ROOT / 'kubernetes/flux/clusters/prod/flux-system')
        controller = next(d for d in docs if d['kind'] == 'Deployment' and d['metadata']['name'] == 'kustomize-controller')
        self.assertIn('--no-remote-bases=true', controller['spec']['template']['spec']['containers'][0]['args'])


if __name__ == '__main__':
    unittest.main()
