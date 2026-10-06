"""Private suite configs bind actual exec issuance to unchanged canonical access."""

import copy
import io
import json
import os
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

import yaml

from scripts.openbao import credentials, guards, workstation
from scripts.openbao.configuration import SafeError
from scripts.test import access
from scripts.test.core import test_openbao_credentials as credential_fixtures
from scripts.test.core.test_openbao_credentials import NOW, Broker, jwt, state
from scripts.test.core.test_test_access import ROOT

CURRENT = {
    "observer": "homelab-observer",
    "debugger": "homelab-diagnostic",
    "test-runner": "homelab-test-runner",
    "report-publisher": "homelab-report-publisher",
    "campaign-coordinator": "homelab-campaign-coordinator",
    "test-flux-restart": "homelab-test-flux-restart",
    "test-cilium-connectivity": "homelab-test-cilium-connectivity",
    "test-node-reschedule": "homelab-test-node-reschedule",
    "test-conformance": "homelab-test-conformance",
    "test-openbao-issuance": "homelab-test-openbao-issuance",
    "test-openbao-ha": "homelab-test-openbao-ha",
    "test-openbao-restore": "homelab-test-openbao-restore",
    "test-openbao-lifecycle": "homelab-test-openbao-lifecycle",
}


class CurrentBroker(Broker):
    def post(self, path, payload, *, token=None):
        if path.startswith("kubernetes/creds/"):
            self.calls.append((path, copy.deepcopy(payload), token))
            if self.fail_path == path:
                raise SafeError("invalid-response")
            account = CURRENT[path.split("/")[-1]]
            return {
                "data": {
                    "service_account_name": account,
                    "service_account_namespace": "kube-system",
                    "service_account_token": jwt(account, **self.bad_claims),
                    **self.extra_data,
                }
            }
        return super().post(path, payload, token=token)


class InvocationTests(unittest.TestCase):
    def setUp(self):
        credential_fixtures.InstallationTests.setUp(self)
        (self.repo / "tests").mkdir()
        (self.repo / "tests/catalog.yaml").write_bytes((ROOT / "tests/catalog.yaml").read_bytes())
        self.local = state()
        self.local["cluster"].update(schema_version=2, profiles=list(CURRENT))
        workstation.write_private(self.auth / "cluster.json", self.local["cluster"])
        record = {k: v for k, v in self.local.items() if k != "cluster"}
        record.update(schema_version=1, cluster_digest=guards.digest(self.local["cluster"]))
        workstation.write_private(self.auth / "workstation.json", record)

    def prepare(self, suite="test.storage-provisioning", run="synthetic-run"):
        prepare = getattr(access, "prepare_invocation", None)
        self.assertTrue(callable(prepare), "invocation lifecycle is required")
        return prepare(self.repo, suite, run)

    def test_single_profile_config_private_and_no_tokens(self):
        path = self.prepare()
        config = yaml.safe_load(path.read_text())
        self.assertEqual(len(config["contexts"]), 1)
        self.assertEqual(len(config["users"]), 1)
        self.assertEqual(config["current-context"], "homelab-test-runner")
        self.assertEqual(config["users"][0]["user"]["exec"]["args"], ["invocation", str(path)])
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(
            access.validate_invocation(self.repo, path)["suite_id"], "test.storage-provisioning"
        )
        for item in path.parent.iterdir():
            self.assertNotIn("SECRET_MARKER", item.read_text())
            self.assertNotIn("synthetic-role", item.read_text())

    def test_parallel_configs_do_not_overwrite(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            paths = list(pool.map(lambda i: self.prepare(run=f"synthetic-{i}"), range(4)))
        self.assertEqual(len(set(paths)), 4)
        for i, path in enumerate(paths):
            self.assertEqual(
                access.validate_invocation(self.repo, path)["run_id"], f"synthetic-{i}"
            )

    def test_concurrent_kube_directory_creation_accepted(self):
        original = Path.mkdir

        def concurrent_create(path, *args, **kwargs):
            result = original(path, *args, **kwargs)
            if path == self.repo / ".kube":
                raise FileExistsError("another invocation created the same directory")
            return result

        with patch.object(Path, "mkdir", concurrent_create):
            path = self.prepare()
        self.assertEqual(access.validate_invocation(self.repo, path)["profile"], "test-runner")

    def test_null_profile_has_no_enrollment_dependency(self):
        with patch(
            "scripts.openbao.credentials.load_workstation",
            side_effect=AssertionError("must not read secrets"),
        ):
            for suite in (
                "test.nocodb-local-integration",
                "test.news-postgresql-local-integration",
            ):
                self.assertIsNone(self.prepare(suite=suite))

    def test_changed_binding_and_source_rejected(self):
        path = self.prepare()
        binding_path = path.parent / "binding.json"
        binding = json.loads(binding_path.read_text())
        binding["profile"] = "test-conformance"
        workstation.write_private(binding_path, binding)
        with self.assertRaises(SafeError):
            access.validate_invocation(self.repo, path)

    def test_run_id_change_rejected(self):
        path = self.prepare()
        binding = json.loads((path.parent / "binding.json").read_text())
        binding["run_id"] = "different-run"
        workstation.write_private(path.parent / "binding.json", binding)
        with self.assertRaises(SafeError):
            access.validate_invocation(self.repo, path)

    def test_attended_metadata_enables_current_profiles(self):
        view = {
            "clusters": [
                {
                    "cluster": {
                        "server": self.local["cluster"]["server"],
                        "certificate-authority-data": self.local["cluster"][
                            "certificate_authority_data"
                        ],
                    }
                }
            ]
        }
        with patch("scripts.openbao.workstation.guards.kube", return_value=view):
            metadata = workstation.cluster_metadata(self.repo / "selected")
        self.assertEqual(metadata["schema_version"], 2)
        self.assertEqual(metadata["profiles"], list(CURRENT))

    def test_legacy_base_config_replaced_after_attended_enrollment(self):
        current = workstation.read_private(self.auth / "cluster.json")
        old = state()["cluster"]
        workstation.write_private(self.auth / "cluster.json", old)
        record = workstation.read_private(self.auth / "workstation.json")
        record["cluster_digest"] = guards.digest(old)
        workstation.write_private(self.auth / "workstation.json", record)
        path = credentials.install_kubeconfig(self.repo, self.auth)
        workstation.write_private(self.auth / "cluster.json", current)
        record["cluster_digest"] = guards.digest(current)
        workstation.write_private(self.auth / "workstation.json", record)
        credentials.install_kubeconfig(self.repo, self.auth)
        self.assertEqual(len(yaml.safe_load(path.read_text())["contexts"]), 1)

    def test_catalog_digest_change_rejected(self):
        path = self.prepare(run="new-run")
        catalog = self.repo / "tests/catalog.yaml"
        catalog.write_text(catalog.read_text() + "\n# source changed\n")
        with self.assertRaises(SafeError):
            access.validate_invocation(self.repo, path)

    def test_symlink_foreign_owner_and_unsafe_modes_rejected(self):
        path = self.prepare()
        with (
            patch("scripts.openbao.credentials.os.getuid", return_value=os.getuid() + 1),
            self.assertRaises(SafeError),
        ):
            access.validate_invocation(self.repo, path)
        path.chmod(0o644)
        with self.assertRaises(SafeError):
            access.validate_invocation(self.repo, path)
        path.chmod(0o600)
        other = path.parent / "other"
        path.rename(other)
        path.symlink_to(other)
        with self.assertRaises(SafeError):
            access.validate_invocation(self.repo, path)

    def test_cleanup_owned_only_and_idempotent(self):
        one = self.prepare(run="one")
        two = self.prepare(run="two")
        access.remove_invocation(self.repo, one)
        access.remove_invocation(self.repo, one)
        self.assertFalse(one.parent.exists())
        self.assertTrue(two.exists())
        with self.assertRaises(SafeError):
            access.remove_invocation(self.repo, self.repo / "tests/catalog.yaml")

    def test_old_enrollment_cannot_issue_new_authority(self):
        broker = CurrentBroker()
        old = state()
        old["cluster"].update(
            schema_version=1,
            profiles=["observer", "diagnostic", "publisher", "campaign-coordinator"],
        )
        with self.assertRaises(SafeError):
            credentials.issue_exec_credential("test-conformance", old, client=broker, now=NOW)
        self.assertEqual(broker.calls, [])

    def test_refresh_uses_same_endpoint_and_revokes_login(self):
        broker = CurrentBroker()
        for _ in range(2):
            credentials.issue_exec_credential("test-runner", self.local, client=broker, now=NOW)
        self.assertEqual(
            [c[0] for c in broker.calls],
            [
                workstation.LOGIN_PATH,
                "kubernetes/creds/test-runner",
                "auth/token/revoke-self",
                workstation.LOGIN_PATH,
                "kubernetes/creds/test-runner",
                "auth/token/revoke-self",
            ],
        )
        self.assertEqual(broker.calls[1][1], {"kubernetes_namespace": "kube-system", "ttl": 600})

    def test_outage_has_no_fallback(self):
        broker = CurrentBroker()
        broker.fail_path = "kubernetes/creds/test-runner"
        with self.assertRaises(SafeError):
            credentials.issue_exec_credential("test-runner", self.local, client=broker, now=NOW)
        self.assertEqual(
            [c[0] for c in broker.calls],
            [
                workstation.LOGIN_PATH,
                "kubernetes/creds/test-runner",
                "auth/token/revoke-self",
            ],
        )

    def test_wrong_token_identity_and_lifetime_rejected(self):
        for claims in (
            {"sub": "system:serviceaccount:kube-system:homelab-test-conformance"},
            {"aud": ["wrong"]},
            {"exp": NOW + 601},
            {"exp": NOW - 1},
        ):
            broker = CurrentBroker()
            broker.bad_claims = claims
            with self.subTest(claims=claims), self.assertRaises(SafeError):
                credentials.issue_exec_credential(
                    "test-runner", self.local, client=broker, now=NOW
                )

    def test_refresh_rejects_changed_binding_before_login_and_redacts(self):
        path = self.prepare()
        changed = json.loads((path.parent / "binding.json").read_text())
        changed["catalog_digest"] = "SECRET_MARKER"
        workstation.write_private(path.parent / "binding.json", changed)
        output, errors = io.StringIO(), io.StringIO()
        with (
            patch(
                "scripts.openbao.credentials.__file__",
                str(self.repo / "scripts/openbao/credentials.py"),
            ),
            patch("scripts.openbao.credentials.BaoClient") as client,
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
            redirect_stderr(errors),
        ):
            self.assertEqual(credentials.main(["exec", "invocation", str(path)]), 1)
        client.assert_not_called()
        self.assertEqual(output.getvalue(), "")
        self.assertNotIn("SECRET_MARKER", errors.getvalue())

    def test_new_base_configs_do_not_rewrite_other_profiles(self):
        observer = credentials.install_kubeconfig(self.repo, self.auth, "observer")
        before = observer.read_bytes()
        debugger = credentials.install_kubeconfig(self.repo, self.auth, "debugger")
        self.assertNotEqual(observer, debugger)
        self.assertEqual(observer.read_bytes(), before)
        self.assertEqual(len(yaml.safe_load(debugger.read_text())["contexts"]), 1)
        with self.assertRaises(SafeError):
            credentials.install_kubeconfig(self.repo, self.auth, "test-conformance")
