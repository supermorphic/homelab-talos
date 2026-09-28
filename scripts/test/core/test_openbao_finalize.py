import copy
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.openbao import bootstrap
from scripts.openbao.client import AmbiguousWrite
from scripts.openbao.configuration import SafeError


class FinalizeClient:
    def __init__(self):
        self.posts = []
        self.revoked = set()
        self.token = None
        self.login_ok = True
        self.root_policy = ["root"]
        self.lose_revoke_response = False
        self.revoke_applies = True

    def set_token(self, token):
        self.token = token

    def wait_quorum(self, token):
        self.set_token(token)

    def read(self, path, token=None):
        if token in self.revoked:
            raise SafeError("read-denied")
        return {"data": {"policies": self.root_policy if token == "root" else ["openbao-operator"]}}

    def post(self, path, payload, token=None):
        self.posts.append((path, token))
        if path == "auth/homelab-userpass/login/openbao-operator":
            if not self.login_ok:
                raise SafeError("authentication-failed")
            return {"auth": {"client_token": "operator", "policies": ["openbao-operator"]}}
        if path == "auth/token/revoke-self":
            if self.revoke_applies or token == "operator":
                self.revoked.add(token)
            if self.lose_revoke_response:
                raise AmbiguousWrite()
            return {}
        raise AssertionError("unexpected write")


class FinalizeTest(unittest.TestCase):
    def setUp(self):
        self.client = FinalizeClient()
        self.target = {"source_revision": "a" * 40, "statefulset_uid": "synthetic-sts"}
        self.inputs = dict(client=self.client, token="root", password="synthetic-password",
                           kubeconfig=Path("/synthetic"), journal=[])
        self.guard = patch("scripts.openbao.guards.freeze_target", return_value=self.target).start()
        self.check = patch("scripts.openbao.guards.assert_mutation_allowed").start()
        self.verify = patch("scripts.openbao.apply.verify_configuration", return_value={"differences": []}).start()
        self.audit = patch("scripts.openbao.apply.audit_state", return_value=True).start()
        self.addCleanup(patch.stopall)

    def plan(self):
        return bootstrap.finalize(**self.inputs)

    def test_preview_is_read_only_then_finalization_retires_only_supplied_root_and_session(self):
        plan = self.plan()
        self.assertEqual(self.client.posts, [])
        result = bootstrap.finalize(confirm=plan["confirmation"], **self.inputs)
        self.assertEqual(result, {"status": "pass"})
        self.assertEqual(self.client.revoked, {"root", "operator"})
        self.assertEqual(self.client.posts, [
            ("auth/homelab-userpass/login/openbao-operator", None),
            ("auth/token/revoke-self", "root"), ("auth/token/revoke-self", "operator")])

    def test_drift_or_wrong_root_policy_prevents_any_write(self):
        for failure in ("drift", "root", "audit"):
            with self.subTest(failure=failure):
                self.verify.side_effect = SafeError("source-mismatch") if failure == "drift" else None
                self.client.root_policy = ["default"] if failure == "root" else ["root"]
                self.audit.return_value = failure != "audit"
                with self.assertRaises(SafeError):
                    self.plan()
                self.assertEqual(self.client.posts, [])

    def test_failed_operator_login_preserves_root(self):
        plan = self.plan()
        self.client.login_ok = False
        with self.assertRaises(SafeError):
            bootstrap.finalize(confirm=plan["confirmation"], **self.inputs)
        self.assertNotIn("root", self.client.revoked)

    def test_operator_readback_failure_preserves_root_and_cleans_session(self):
        plan = self.plan()
        def verify(*_):
            if self.client.token == "operator":
                raise SafeError("read-denied")
        self.verify.side_effect = verify
        with self.assertRaises(SafeError):
            bootstrap.finalize(confirm=plan["confirmation"], **self.inputs)
        self.assertEqual(self.client.revoked, {"operator"})

    def test_changed_target_blocks_root_revocation(self):
        plan = self.plan()
        changed = copy.deepcopy(self.target)
        changed["statefulset_uid"] = "changed"
        self.guard.side_effect = [self.target, self.target, changed]
        with self.assertRaises(SafeError):
            bootstrap.finalize(confirm=plan["confirmation"], **self.inputs)
        self.assertNotIn("root", self.client.revoked)

    def test_lost_revoke_response_is_resolved_by_actual_denial_without_retry(self):
        plan = self.plan()
        self.client.lose_revoke_response = True
        result = bootstrap.finalize(confirm=plan["confirmation"], **self.inputs)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(self.client.posts.count(("auth/token/revoke-self", "root")), 1)
        self.assertEqual(self.client.posts.count(("auth/token/revoke-self", "operator")), 1)

    def test_unapplied_ambiguous_revocation_fails_without_retry(self):
        plan = self.plan()
        self.client.lose_revoke_response = True
        self.client.revoke_applies = False
        with self.assertRaisesRegex(SafeError, "authentication-failed"):
            bootstrap.finalize(confirm=plan["confirmation"], **self.inputs)
        self.assertEqual(self.client.revoked, {"operator"})
        self.assertEqual(self.client.posts.count(("auth/token/revoke-self", "root")), 1)


if __name__ == "__main__":
    unittest.main()
