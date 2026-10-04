"""Only the two declared audits can issue separate base-profile check configs."""

import copy
import io
import json
import os
import unittest
from contextlib import redirect_stdout
from unittest.mock import patch

import yaml

from scripts.openbao import credentials, workstation
from scripts.openbao.configuration import SafeError
from scripts.test import access
from scripts.test.core import test_openbao_invocations as fixtures


class AuditProfileAccessTests(unittest.TestCase):
    def setUp(self):
        fixtures.InvocationTests.setUp(self)

    def parent(self, suite="verification.agent-access"):
        return access.prepare_invocation(self.repo, suite, "synthetic-audit")

    def test_all_five_profiles_separately_bound_to_each_declared_audit(self):
        for suite in ("verification.agent-access", "test.agent-credentials"):
            parent = self.parent(suite)
            for profile in (
                "observer",
                "debugger",
                "test-runner",
                "report-publisher",
                "campaign-coordinator",
            ):
                with self.subTest(suite=suite, profile=profile):
                    child = access.prepare_profile_check(self.repo, parent, profile)
                    binding = access.validate_invocation(self.repo, child)
                    self.assertEqual(binding["profile"], profile)
                    self.assertEqual(binding["profile_check"], profile)
                    self.assertEqual(binding["audit_parent"], str(parent))
                    self.assertEqual(binding["suite_id"], suite)
                    self.assertEqual(binding["run_id"], "synthetic-audit")
                    config = yaml.safe_load(child.read_text())
                    self.assertEqual(len(config["contexts"]), 1)
                    self.assertEqual(len(config["users"]), 1)
                    with self.assertRaises(SafeError):
                        access.validate_inherited_invocation(self.repo, suite, child)
                    self.assertEqual(child.stat().st_mode & 0o777, 0o600)

    def test_no_ordinary_dedicated_or_recursive_profile_overrides(self):
        ordinary = self.parent("test.storage-provisioning")
        parent = self.parent()
        child = access.prepare_profile_check(self.repo, parent, "observer")
        for source, profile in (
            (ordinary, "debugger"),
            (parent, "test-conformance"),
            (parent, "diagnostic"),
            (child, "debugger"),
        ):
            with self.subTest(source=source, profile=profile), self.assertRaises(SafeError):
                access.prepare_profile_check(self.repo, source, profile)

    def test_changed_run_profile_parent_catalog_or_missing_parent_denies_refresh(self):
        parent = self.parent()
        child = access.prepare_profile_check(self.repo, parent, "debugger")
        original = access.validate_invocation(self.repo, child)
        path = child.parent / "binding.json"
        for override in (
            {"run_id": "other-run"},
            {"profile": "test-conformance"},
            {"audit_parent": str(child)},
            {"purpose": "report-publisher"},
            {"catalog_digest": "0" * 64},
        ):
            with self.subTest(override=override):
                workstation.write_private(path, {**copy.deepcopy(original), **override})
                with self.assertRaises(SafeError):
                    access.validate_invocation(self.repo, child)
        workstation.write_private(path, original)
        access.remove_invocation(self.repo, parent)
        with self.assertRaises(SafeError):
            access.validate_invocation(self.repo, child)
        access.remove_invocation(self.repo, child)
        self.assertFalse(child.exists())

    def test_exec_issues_only_checked_profile_for_600_seconds_and_revokes_login(self):
        parent = self.parent()
        for profile in (
            "observer",
            "debugger",
            "test-runner",
            "report-publisher",
            "campaign-coordinator",
        ):
            child = access.prepare_profile_check(self.repo, parent, profile)
            broker = fixtures.CurrentBroker()
            with (
                patch.object(
                    credentials, "__file__", str(self.repo / "scripts/openbao/credentials.py")
                ),
                patch.object(credentials, "BaoClient", return_value=broker),
                patch.object(credentials.time, "time", return_value=fixtures.NOW),
                patch.dict(
                    os.environ,
                    {
                        "KUBERNETES_EXEC_INFO": json.dumps(
                            {
                                "apiVersion": "client.authentication.k8s.io/v1",
                                "kind": "ExecCredential",
                                "spec": {"interactive": False},
                            }
                        )
                    },
                ),
                redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(credentials.main(["exec", "invocation", str(child)]), 0)
            self.assertEqual(
                [call[0] for call in broker.calls],
                [workstation.LOGIN_PATH, f"kubernetes/creds/{profile}", "auth/token/revoke-self"],
            )
            self.assertEqual(broker.calls[1][1]["ttl"], 600)


if __name__ == "__main__":
    unittest.main()
