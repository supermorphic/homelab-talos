"""Effective diagnostic grants must follow the current caller inventory."""
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]


class DiagnosticScopeTest(unittest.TestCase):
    def test_interactive_grants_are_explicit_and_exclude_openbao(self):
        docs = list(yaml.safe_load_all((ROOT / 'kubernetes/apps/kube-system/agent-access/app/rbac.yaml').read_text()))
        roles = {d['metadata']['name']: d for d in docs if d['kind'] == 'ClusterRole'}
        actual = set()
        for binding in docs:
            if binding['kind'] not in {'RoleBinding', 'ClusterRoleBinding'}:
                continue
            if not any(s.get('name') == 'homelab-diagnostic' for s in binding.get('subjects', [])):
                continue
            role = roles.get(binding['roleRef']['name'], {})
            for rule in role.get('rules', []):
                for resource in set(rule.get('resources', [])) & {'pods/exec', 'pods/portforward', '*'}:
                    self.assertEqual(binding['kind'], 'RoleBinding', 'Interactive authority must not be cluster-wide')
                    self.assertEqual(rule['verbs'], ['create'])
                    actual.add((binding['metadata']['namespace'], resource))
        self.assertEqual(actual, {
            ('kube-system', 'pods/exec'), ('kube-system', 'pods/portforward'),
            ('media', 'pods/exec'), ('media', 'pods/portforward'),
            ('homepage', 'pods/exec'), ('ntfy', 'pods/exec'),
            ('automation', 'pods/exec'), ('monitoring', 'pods/portforward'),
        })
