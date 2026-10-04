"""Nested verification retains its parent's authority without selecting another profile."""

import unittest
from unittest.mock import patch

import yaml

from scripts.openbao.configuration import SafeError
from scripts.test import access
from scripts.test.core import test_openbao_invocations as fixtures


class InheritedInvocationTests(unittest.TestCase):
    setUp = fixtures.InvocationTests.setUp

    def inherit(self, suite, path):
        function = getattr(access, "validate_inherited_invocation", None)
        self.assertTrue(callable(function), "nested execution needs checked inheritance")
        return function(self.repo, suite, path)

    def test_same_suite_and_read_only_observer_child_keep_parent_run_and_profile(self):
        path = access.prepare_invocation(self.repo, "test.cilium-connectivity", "parent-run")
        for suite in (
            "test.cilium-connectivity",
            "verification.cilium",
            "verification.flux",
            "diagnostics.cluster",
        ):
            binding = self.inherit(suite, path)
            self.assertEqual(binding["suite_id"], "test.cilium-connectivity")
            self.assertEqual(binding["profile"], "test-cilium-connectivity")
            self.assertEqual(binding["run_id"], "parent-run")

    def test_other_mutating_or_probe_child_cannot_adopt_a_parent(self):
        path = access.prepare_invocation(self.repo, "test.cilium-connectivity", "parent-run")
        for suite in ("test.flux-restart", "test.storage-provisioning", "probe.qbittorrent"):
            with self.subTest(suite=suite), self.assertRaises(SafeError):
                self.inherit(suite, path)

    def test_nested_child_cannot_add_an_unmet_prerequisite(self):
        path = access.prepare_invocation(self.repo, "test.storage-provisioning", "parent-run")
        with self.assertRaises(SafeError):
            self.inherit("verification.agent-access", path)

    def test_observer_parent_cannot_select_debugger_for_a_nested_verifier(self):
        path = access.prepare_invocation(self.repo, "verification.flux", "parent-run")
        with self.assertRaises(SafeError):
            self.inherit("verification.cilium", path)

    def test_legacy_config_cannot_be_adopted_as_parent(self):
        path = self.repo / ".kube/config"
        path.parent.mkdir(exist_ok=True)
        path.write_text("apiVersion: v1\nkind: Config\ncurrent-context: diagnostic\n")
        with self.assertRaises(SafeError):
            self.inherit("verification.metrics-server", path)

    def test_routing_digest_change_rejects_preparation_before_installing_authority(self):
        declaration = access.resolve_suite_access(self.repo, "verification.metrics-server")
        catalog_path = self.repo / "tests/catalog.yaml"
        catalog = yaml.safe_load(catalog_path.read_text())
        entry = next(
            e for e in catalog["suites"] if e["metadata"]["id"] == "verification.metrics-server"
        )
        entry["access"]["profile"] = "debugger"
        catalog_path.write_text(yaml.safe_dump(catalog))
        with patch("scripts.openbao.credentials.install_invocation_kubeconfig") as install:
            with self.assertRaises(SafeError):
                access.prepare_invocation(
                    self.repo,
                    "verification.metrics-server",
                    "run",
                    expected_catalog_digest=declaration["catalog_digest"],
                )
            install.assert_not_called()

    def test_inherited_invocation_rejects_a_different_initial_routing_digest(self):
        path = access.prepare_invocation(self.repo, "verification.metrics-server", "run")
        with self.assertRaises(SafeError):
            access.validate_inherited_invocation(
                self.repo, "verification.metrics-server", path, expected_catalog_digest="0" * 64
            )
