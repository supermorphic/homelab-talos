import copy
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.openbao import bootstrap, guards
from scripts.openbao.client import AmbiguousWrite
from scripts.openbao.configuration import SafeError


class BootstrapClient:
    def __init__(self):
        self.calls = []
        self.states = [False, False, False]
        self.fail_after_initialization_commits = False
        self.deleted_pvcs = []
        self.initialized_peers = []
        self.joined = True
        self.login_ok = True
        self.revoke_ok = True
        self.revoked = False

    def states_now(self):
        return [{"initialized": value} for value in self.states]

    def post(self, path, payload, token=None):
        self.calls.append(("POST", path))
        if path == "sys/init":
            self.states[0] = True
            self.initialized_peers.append("openbao-0")
            if self.fail_after_initialization_commits:
                raise AmbiguousWrite("ambiguous-write")
            return {"root_token": "synthetic-root", "recovery_keys_base64": ["synthetic-share"]}
        if path.endswith("/login/openbao-operator"):
            if not self.login_ok:
                raise SafeError("authentication-failed")
            return {
                "auth": {"client_token": "synthetic-operator", "policies": ["openbao-operator"]}
            }
        if path == "auth/token/revoke-self":
            if not self.revoke_ok:
                raise AmbiguousWrite("ambiguous-write")
            self.revoked = True
        return {}

    def read(self, path, token=None):
        self.calls.append(("GET", path))
        if path == "auth/token/lookup-self":
            if token == "synthetic-root" and self.revoked:
                raise SafeError("read-denied")
            return {"data": {"policies": ["openbao-operator"]}}
        return {"data": {}}

    def wait_quorum(self, token):
        if not self.joined:
            raise SafeError("timeout")

    def prepare(self):
        self.calls.append(("prepare", "owned-units"))

    def configure_audit(self, token):
        self.calls.append(("audit", "verified"))


class BootstrapTest(unittest.TestCase):
    def setUp(self):
        self.client = BootstrapClient()
        self.target = {
            "source_revision": "a" * 40,
            "package_digest": "b" * 64,
            "cluster_uid": "synthetic-cluster",
            "namespace_uid": "synthetic-ns",
            "statefulset_uid": "synthetic-sts",
            "pvc_uids": ["p0", "p1", "p2"],
            "recipient": "synthetic-recipient",
            "seal_key_id": "1",
        }
        self.journal = []
        self.inputs = {
            "client": self.client,
            "kubeconfig": Path("/synthetic"),
            "recovery_directory": Path("/synthetic-recovery"),
            "recipient": "synthetic-recipient",
            "journal": self.journal,
            "confirm": guards.confirmation("initialize", "a" * 40, guards.digest(self.target)),
        }
        for name, value in [("freeze_target", self.target), ("assert_mutation_allowed", None)]:
            self.mock(name, value, "guards")
        self.mock("preflight_recovery", None, "secrets")
        self.mock("write_recovery", Path("/synthetic-retained"), "secrets")
        self.mock("install_initial", None, "apply")

    def mock(self, name, value, module):
        p = patch(f"scripts.openbao.{module}.{name}", return_value=value)
        mock = p.start()
        self.addCleanup(p.stop)
        return mock

    def test_initialization_response_loss_never_retries_or_deletes(self):
        self.client.fail_after_initialization_commits = True
        with self.assertRaises(AmbiguousWrite):
            bootstrap.run("initialize", **self.inputs)
        self.assertEqual(self.client.calls.count(("POST", "sys/init")), 1)
        self.assertEqual(self.client.deleted_pvcs, [])
        self.assertEqual(self.client.initialized_peers, ["openbao-0"])

    def test_initialized_mixed_malformed_and_inaccessible_refuse_all_writes(self):
        for states in (
            [True] * 3,
            [False, True, False],
            [False, None, False],
            [False, "false", False],
        ):
            self.client.states = states
            with self.subTest(states=states), self.assertRaises(SafeError):
                bootstrap.run("initialize", **self.inputs)
            self.assertEqual(self.client.calls, [])
        with (
            patch.object(self.client, "states_now", side_effect=SafeError("timeout")),
            self.assertRaises(SafeError),
        ):
            bootstrap.run("initialize", **self.inputs)
        self.assertEqual(self.client.calls, [])

    def test_missing_confirmation_and_changed_identity_refuse(self):
        self.inputs["confirm"] = ""
        result = bootstrap.run("initialize", **self.inputs)
        self.assertEqual(result["status"], "confirmation-required")
        self.assertEqual(self.client.calls, [])
        self.inputs["confirm"] = result["confirmation"]
        for field in (
            "namespace_uid",
            "statefulset_uid",
            "pvc_uids",
            "source_revision",
            "recipient",
        ):
            changed = copy.deepcopy(self.target)
            changed[field] = "changed"
            with (
                patch("scripts.openbao.guards.freeze_target", side_effect=[self.target, changed]),
                self.subTest(field=field),
                self.assertRaises(SafeError),
            ):
                bootstrap.run("initialize", **self.inputs)
            self.assertEqual(self.client.calls, [])

    def test_encrypted_retention_precedes_configuration_and_root_revocation(self):
        result = bootstrap.run("initialize", **self.inputs)
        self.assertEqual(result["status"], "pass")
        self.assertLess(
            self.journal.index("recovery-retained"), self.journal.index("configuration-written")
        )
        self.assertLess(
            self.journal.index("operator-login-verified"), self.journal.index("root-revoked")
        )
        self.assertTrue(self.client.revoked)

    def test_partial_failures_cannot_report_success_or_retry_initialization(self):
        for failure in ("recovery", "joined", "login_ok", "revoke_ok"):
            self.setUp()
            if failure != "recovery":
                setattr(self.client, failure, False)
            recovery = (
                patch("scripts.openbao.secrets.write_recovery", side_effect=SafeError())
                if failure == "recovery"
                else patch(
                    "scripts.openbao.secrets.write_recovery",
                    return_value=Path("/synthetic-retained"),
                )
            )
            with recovery, self.subTest(failure=failure), self.assertRaises(SafeError):
                bootstrap.run("initialize", **self.inputs)
            self.assertEqual(self.client.calls.count(("POST", "sys/init")), 1)
            with self.assertRaises(SafeError):
                bootstrap.run("initialize", **self.inputs)
            self.assertEqual(self.client.calls.count(("POST", "sys/init")), 1)

    def test_prepare_only_resumes_owned_units_after_confirmation(self):
        self.inputs["confirm"] = guards.confirmation("prepare", "a" * 40, "b" * 64)
        result = bootstrap.run("prepare", **self.inputs)
        self.assertEqual(result["status"], "prepared")
        self.assertEqual(self.client.calls, [("prepare", "owned-units")])


class GuardTest(unittest.TestCase):
    def test_source_refuses_dirty_or_unpublished_candidate(self):
        with (
            patch("scripts.openbao.guards.command", return_value=b" M synthetic"),
            self.assertRaises(SafeError),
        ):
            guards.source_revision()
        with (
            patch(
                "scripts.openbao.guards.command",
                side_effect=[b"", b"a" * 40, b"b" * 40 + b" refs/heads/main"],
            ),
            self.assertRaises(SafeError),
        ):
            guards.source_revision()

    def test_operator_cli_never_falls_back_to_ambient_kubeconfig(self):
        import contextlib
        import io

        from scripts.openbao.operator import main

        output = io.StringIO()
        with (
            patch.dict(
                "os.environ", {"KUBECONFIG": "/synthetic-admin", "OPENBAO_OPERATOR_KUBECONFIG": ""}
            ),
            contextlib.redirect_stdout(output),
        ):
            self.assertEqual(main(["operator", "initialize"]), 1)
        self.assertNotIn("synthetic-admin", output.getvalue())

    def test_live_pod_comparison_accepts_generated_claim_but_rejects_changed_seal(self):
        expected = {
            "containers": [{"name": "openbao", "image": "pinned"}],
            "volumes": [{"name": "seal", "secret": {"secretName": "openbao-seal"}}],
        }
        actual = {
            "containers": [
                {"name": "openbao", "image": "pinned", "imagePullPolicy": "IfNotPresent"}
            ],
            "volumes": [
                {"name": "data", "persistentVolumeClaim": {"claimName": "data-openbao-0"}},
                {"name": "seal", "secret": {"secretName": "openbao-seal", "defaultMode": 288}},
            ],
        }
        self.assertTrue(guards.contains_source(expected, actual))
        actual["volumes"][1]["secret"]["secretName"] = "unrelated"
        self.assertFalse(guards.contains_source(expected, actual))

    def test_recovery_failure_never_reaches_configuration(self):
        fixture = BootstrapTest("test_initialization_response_loss_never_retries_or_deletes")
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        with (
            patch("scripts.openbao.secrets.write_recovery", side_effect=SafeError()),
            patch("scripts.openbao.apply.install_initial") as install,
            self.assertRaises(SafeError),
        ):
            bootstrap.run("initialize", **fixture.inputs)
        install.assert_not_called()


if __name__ == "__main__":
    unittest.main()
