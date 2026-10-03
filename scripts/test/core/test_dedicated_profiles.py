"""Literal expectations for the dedicated test identity boundaries."""

import subprocess
import unittest
from pathlib import Path

import yaml

from scripts.openbao import credentials

ROOT = Path(__file__).resolve().parents[3]
BINDINGS = {
    "test-flux-restart": ("test.flux-restart",),
    "test-cilium-connectivity": ("test.cilium-connectivity",),
    "test-node-reschedule": ("chainsaw.resilience.plex-cross-node-reschedule",),
    "test-conformance": ("conformance.quick", "conformance.certified"),
    "test-openbao-issuance": ("test.openbao-issuance",),
    "test-openbao-ha": ("test.openbao-ha",),
    "test-openbao-restore": ("test.openbao-restore-drill",),
    "test-openbao-lifecycle": ("test.agent-credentials",),
}


class DedicatedIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run(
            ["kustomize", "build", str(ROOT / "kubernetes/apps/kube-system/agent-access/app")],
            capture_output=True,
            text=True,
            check=True,
        )
        cls.documents = list(yaml.safe_load_all(result.stdout))

    def test_dedicated_suite_profile_and_account_correspondence(self):
        self.assertEqual(credentials.SUITE_PROFILE_BINDINGS, BINDINGS)
        for profile in BINDINGS:
            self.assertEqual(credentials.PROFILES[profile], "homelab-" + profile)
        self.assertEqual(
            BINDINGS["test-conformance"], ("conformance.quick", "conformance.certified")
        )

    def test_dedicated_accounts_are_precreated_and_tokenless(self):
        for profile in BINDINGS:
            with self.subTest(profile=profile):
                accounts = [
                    d
                    for d in self.documents
                    if d["kind"] == "ServiceAccount"
                    and d["metadata"]["name"] == "homelab-" + profile
                ]
                self.assertEqual(len(accounts), 1)
                self.assertEqual(accounts[0]["metadata"]["namespace"], "kube-system")
                self.assertIs(accounts[0]["automountServiceAccountToken"], False)
                self.assertNotIn("secrets", accounts[0])

    def test_conformance_has_one_explicit_administrator_binding(self):
        admins = [
            d
            for d in self.documents
            if d["kind"] in {"RoleBinding", "ClusterRoleBinding"}
            and d["roleRef"]["name"] == "cluster-admin"
        ]
        self.assertEqual(len(admins), 1)
        self.assertEqual(admins[0]["kind"], "ClusterRoleBinding")
        self.assertEqual(admins[0]["metadata"]["name"], "homelab-test-conformance")
        self.assertEqual(
            admins[0]["subjects"],
            [
                {
                    "kind": "ServiceAccount",
                    "name": "homelab-test-conformance",
                    "namespace": "kube-system",
                }
            ],
        )
