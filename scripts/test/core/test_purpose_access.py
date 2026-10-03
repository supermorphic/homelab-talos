"""Orchestration reads, Lease writes and report installation stay separate."""

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
from scripts.test.core import test_openbao_invocations as invocation_fixtures


class PurposeAccessTests(unittest.TestCase):
    def setUp(self):
        invocation_fixtures.InvocationTests.setUp(self)

    def prepare(self, purpose):
        with patch("scripts.openbao.workstation.DIRECTORY", self.auth):
            return access.prepare_purpose_invocation(self.repo, purpose, "synthetic-session")

    def test_literal_purposes_have_only_their_own_single_profile(self):
        for purpose, profile in (
            ("campaign-observer", "observer"),
            ("campaign-coordinator", "campaign-coordinator"),
            ("report-publisher", "report-publisher"),
        ):
            with self.subTest(purpose=purpose):
                path = self.prepare(purpose)
                binding = access.validate_invocation(self.repo, path)
                self.assertEqual(binding["profile"], profile)
                self.assertEqual(binding["purpose"], purpose)
                self.assertNotIn("suite_id", binding)
                config = yaml.safe_load(path.read_text())
                self.assertEqual(len(config["contexts"]), 1)
                self.assertEqual(len(config["users"]), 1)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_unknown_purpose_and_fixture_catalog_rejected_before_installation(self):
        with patch.object(credentials, "install_invocation_kubeconfig") as install:
            for purpose in ("debugger", "test-flux-restart", "publisher", "suite"):
                with self.subTest(purpose=purpose), self.assertRaises(SafeError):
                    self.prepare(purpose)
            with (
                patch.dict(os.environ, {"TEST_CATALOG_PATH": str(self.repo / "fixture.yaml")}),
                self.assertRaises(SafeError),
            ):
                self.prepare("report-publisher")
        install.assert_not_called()

    def test_purpose_binding_cannot_be_changed_or_inherited_by_suite(self):
        for purpose in ("campaign-observer", "campaign-coordinator", "report-publisher"):
            with self.subTest(purpose=purpose):
                path = self.prepare(purpose)
                with self.assertRaises(SafeError):
                    access.validate_inherited_invocation(self.repo, "verification.flux", path)
                binding = access.validate_invocation(self.repo, path)
                for extra in ({"profile": "test-runner"}, {"suite_id": "verification.flux"}):
                    changed = {**copy.deepcopy(binding), **extra}
                    workstation.write_private(path.parent / "binding.json", changed)
                    with self.assertRaises(SafeError):
                        access.validate_invocation(self.repo, path)
                workstation.write_private(path.parent / "binding.json", binding)

    def test_source_drift_denies_refresh_but_preserves_owned_cleanup(self):
        path = self.prepare("campaign-coordinator")
        catalog = self.repo / "tests/catalog.yaml"
        catalog.write_text(catalog.read_text() + "\n# changed source\n")
        with self.assertRaises(SafeError):
            access.validate_invocation(self.repo, path)
        access.remove_invocation(self.repo, path)
        self.assertFalse(path.exists())

    def test_purpose_consumer_checks_its_exact_purpose_and_run(self):
        path = self.prepare("campaign-observer")
        access.validate_purpose_invocation(
            self.repo, "campaign-observer", "synthetic-session", path
        )
        for purpose, run in (
            ("campaign-coordinator", "synthetic-session"),
            ("report-publisher", "synthetic-session"),
            ("campaign-observer", "other-session"),
        ):
            with self.subTest(purpose=purpose, run=run), self.assertRaises(SafeError):
                access.validate_purpose_invocation(self.repo, purpose, run, path)

    def test_exec_refresh_uses_only_purpose_endpoint_and_revokes_each_login(self):
        for purpose, profile in (
            ("campaign-observer", "observer"),
            ("campaign-coordinator", "campaign-coordinator"),
            ("report-publisher", "report-publisher"),
        ):
            with self.subTest(purpose=purpose):
                path = self.prepare(purpose)
                broker = invocation_fixtures.CurrentBroker()
                output = io.StringIO()
                with (
                    patch.object(
                        credentials, "__file__", str(self.repo / "scripts/openbao/credentials.py")
                    ),
                    patch.object(workstation, "DIRECTORY", self.auth),
                    patch.object(credentials, "BaoClient", return_value=broker),
                    patch.object(credentials.time, "time", return_value=invocation_fixtures.NOW),
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
                    redirect_stdout(output),
                ):
                    for _ in range(2):
                        self.assertEqual(credentials.main(["exec", "invocation", str(path)]), 0)
                self.assertEqual(
                    [call[0] for call in broker.calls],
                    [
                        workstation.LOGIN_PATH,
                        f"kubernetes/creds/{profile}",
                        "auth/token/revoke-self",
                        workstation.LOGIN_PATH,
                        f"kubernetes/creds/{profile}",
                        "auth/token/revoke-self",
                    ],
                )


if __name__ == "__main__":
    unittest.main()
