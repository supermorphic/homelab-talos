"""Canonical routing rejects missing, ambiguous and unrelated authority."""

import copy
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

from scripts.openbao.configuration import SafeError
from scripts.test import catalog_validator

ROOT = Path(__file__).resolve().parents[3]


class AccessContractTests(unittest.TestCase):
    def setUp(self):
        self.catalog = yaml.safe_load((ROOT / "tests/catalog.yaml").read_text())

    def entry(self, suite_id):
        return copy.deepcopy(
            next(e for e in self.catalog["suites"] if e["metadata"]["id"] == suite_id)
        )

    def validate(self, entry):
        validate = getattr(catalog_validator, "validate_entry_access", None)
        self.assertTrue(callable(validate), "every suite needs access validation")
        validate(entry)

    def test_access_required_for_every_suite(self):
        for entry in self.catalog["suites"]:
            with self.subTest(suite=entry["metadata"]["id"]):
                self.assertIn("access", entry)
                self.validate(entry)
                entry = copy.deepcopy(entry)
                del entry["access"]
                with self.assertRaises(catalog_validator.ValidationFailure):
                    self.validate(entry)

    def test_foundation_callers_can_inherit_without_adding_undeclared_talos_access(self):
        access = self.router()
        for suite in (
            "verification.storage", "verification.monitoring", "verification.gatus",
            "verification.homepage", "verification.trivy", "verification.tailscale-operator",
            "verification.tailscale-subnet-router", "verification.ntfy", "verification.alertmanager-ntfy",
        ):
            with self.subTest(suite=suite):
                declaration = access.resolve_suite_access(ROOT, suite)
                parent = {**declaration, "run_id": "synthetic-run"}
                with patch.object(access, "validate_invocation", return_value=parent):
                    self.assertEqual(
                        access.validate_inherited_invocation(ROOT, "verification.foundation", Path("/synthetic/config")),
                        parent,
                    )
                parent = {**parent, "prerequisites": []}
                with patch.object(access, "validate_invocation", return_value=parent), self.assertRaises(SafeError):
                    access.validate_inherited_invocation(ROOT, "verification.foundation", Path("/synthetic/config"))

    def test_provisioning_keeps_person_supplied_webhook_credentials(self):
        entry = self.entry("test.automation-data-provisioning")
        self.assertEqual(
            entry["access"],
            {"profile": "test-runner", "prerequisites": ["application-credential"]},
        )
        self.assertEqual(entry["metadata"]["execution_owner"], "human")
        self.assertEqual(entry["confirmation"]["expected"], "test:automation-data:provisioning")

    def test_new_komga_acceptance_declares_attended_application_key(self):
        entry = self.entry("test.komga-acceptance")
        self.assertEqual(
            entry["access"], {"profile": "observer", "prerequisites": ["application-credential"]}
        )
        self.assertEqual(entry["metadata"]["execution_owner"], "human")
        self.validate(entry)

    def test_dedicated_binding_is_exact(self):
        cases = {
            "test.flux-restart": "test-flux-restart",
            "test.cilium-connectivity": "test-cilium-connectivity",
            "chainsaw.resilience.plex-cross-node-reschedule": "test-node-reschedule",
            "conformance.quick": "test-conformance",
            "conformance.certified": "test-conformance",
            "test.openbao-issuance": "test-openbao-issuance",
            "test.openbao-ha": "test-openbao-ha",
            "test.openbao-restore-drill": "test-openbao-restore",
            "test.agent-credentials": "test-openbao-lifecycle",
        }
        for suite_id, profile in cases.items():
            with self.subTest(suite=suite_id):
                entry = self.entry(suite_id)
                self.assertEqual(entry.get("access", {}).get("profile"), profile)
                self.validate(entry)
                unrelated = self.entry("test.storage-provisioning")
                unrelated["access"] = {"profile": profile, "prerequisites": []}
                with self.assertRaises(catalog_validator.ValidationFailure):
                    self.validate(unrelated)

    def test_profile_checks_only_for_identity_audits(self):
        entry = self.entry("verification.metrics-server")
        entry["access"] = {
            "profile": "observer",
            "prerequisites": [],
            "profile_checks": ["observer"],
        }
        with self.assertRaises(catalog_validator.ValidationFailure):
            self.validate(entry)
        entry = self.entry("verification.agent-access")
        self.validate(entry)
        entry["access"]["profile_checks"] = ["test-conformance"]
        with self.assertRaises(catalog_validator.ValidationFailure):
            self.validate(entry)

    def test_invalid_authority_and_attendance_rejected(self):
        for profile in ("unknown", "report-publisher", "campaign-coordinator", None):
            entry = self.entry("test.storage-provisioning")
            entry["access"] = {"profile": profile, "prerequisites": []}
            with (
                self.subTest(profile=profile),
                self.assertRaises(catalog_validator.ValidationFailure),
            ):
                self.validate(entry)
        entry = self.entry("test.openbao-ha")
        entry["metadata"]["execution_owner"] = "shared"
        with self.assertRaises(catalog_validator.ValidationFailure):
            self.validate(entry)

    def test_physical_and_host_local_boundaries(self):
        for suite_id in ("test.nocodb-local-integration", "test.web-research-local-integration"):
            entry = self.entry(suite_id)
            self.assertIsNone(entry.get("access", {}).get("profile"))
            self.validate(entry)
        entry = self.entry("test.resilience.node-abrupt-loss")
        self.validate(entry)
        entry["access"].pop("operator_boundary", None)
        with self.assertRaises(catalog_validator.ValidationFailure):
            self.validate(entry)

    def router(self):
        spec = importlib.util.find_spec("scripts.test.access")
        self.assertIsNotNone(spec, "canonical access router is required")
        from scripts.test import access

        return access

    def test_fixture_catalog_cannot_issue(self):
        access = self.router()
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "catalog.yaml"
            fixture.write_text("schema_version: 3\nsuites: []\n")
            with (
                patch.dict(os.environ, {"TEST_CATALOG_PATH": str(fixture)}),
                self.assertRaises(SafeError),
            ):
                access.resolve_suite_access(ROOT, "test.storage-provisioning")

    def test_resolver_uses_canonical_binding_and_rejects_unknown_suite(self):
        access = self.router()
        result = access.resolve_suite_access(ROOT, "test.storage-provisioning")
        self.assertEqual(result["profile"], "test-runner")
        self.assertEqual(result["suite_id"], "test.storage-provisioning")
        self.assertEqual(len(result["catalog_digest"]), 64)
        with self.assertRaises(SafeError):
            access.resolve_suite_access(ROOT, "test.nonexistent")

    def test_optional_variant_resolves_before_issuance(self):
        access = self.router()
        self.assertEqual(
            access.resolve_suite_access(ROOT, "test.nocodb-access-source-pair")["profile"],
            "debugger",
        )
        self.assertIn(
            "application-credential",
            access.resolve_suite_access(ROOT, "test.nocodb-restore-drill-extension")[
                "prerequisites"
            ],
        )
        with (
            patch.dict(
                os.environ,
                {"NOCODB_ACCESS_EXTENSION_CONFIRM": "test:nocodb:access:source-pairs-v3"},
            ),
            self.assertRaises(SafeError),
        ):
            access.resolve_suite_access(ROOT, "test.nocodb-access")

    def test_n8n_persistence_retains_attended_application_credential(self):
        entry = self.entry("test.n8n-persistence")
        self.assertEqual(entry["metadata"]["execution_owner"], "human")
        self.assertEqual(entry["access"]["profile"], "test-runner")
        self.assertIn("application-credential", entry["access"]["prerequisites"])
        self.assertEqual(entry["confirmation"]["expected"], "chaos:n8n-persistence")

    def test_flux_alert_retains_attended_ntfy_credential(self):
        entry = self.entry("test.e2e.flux-alert-delivery")
        self.assertEqual(entry["metadata"]["execution_owner"], "human")
        self.assertEqual(entry["access"]["profile"], "test-runner")
        self.assertIn("application-credential", entry["access"]["prerequisites"])
        self.assertEqual(entry["confirmation"]["expected"], "test:flux-alert:firing-resolved")
