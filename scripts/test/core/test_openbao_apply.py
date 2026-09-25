import copy
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.openbao import apply
from scripts.openbao.configuration import SafeError, load_document

DESIRED = Path("kubernetes/apps/security/openbao/config/desired.json")


class StateClient:
    """API boundary fake with separately retained live state and write history."""

    def __init__(self):
        self.document = load_document(DESIRED)
        self.state = {(s.kind, s.name): copy.deepcopy(s.fields) for s in self.document["objects"]}
        self.writes = []
        self.ignore_writes = False
        self.audit = {
            "homelab/": {
                "type": "file",
                "options": {"file_path": "stdout", "log_raw": "false", "hmac_accessor": "true"},
                "local": False,
            }
        }

    def request(self, method, path):
        if path == "sys/audit":
            return copy.deepcopy(self.audit)
        from scripts.openbao.verify import INVENTORY_ENDPOINTS

        for kind, endpoint in INVENTORY_ENDPOINTS.items():
            if endpoint != path:
                continue
            names = {name for k, name in self.state if k == kind}
            builtin = self.document["builtin_exceptions"].get(kind, [])
            if method == "GET":
                return {
                    **{name: self.state[(kind, name)] for name in names},
                    **{name: {} for name in builtin},
                }
            return {"keys": sorted(names | set(builtin))}
        for spec in self.document["objects"]:
            if path == spec.path:
                return copy.deepcopy(self.state.get((spec.kind, spec.name)))
        raise AssertionError(path)

    def post(self, path, payload, token=None):
        self.writes.append(path)
        if not self.ignore_writes:
            for spec in self.document["objects"]:
                if path == spec.path:
                    self.state[(spec.kind, spec.name)] = copy.deepcopy(payload)
                    self.password_received = self.state[(spec.kind, spec.name)].pop(
                        "password", None
                    )
        return {"data": {"claimed": "success"}}


class ApplyTest(unittest.TestCase):
    def setUp(self):
        self.client = StateClient()
        self.target = {"source_revision": "a" * 40, "namespace_uid": "synthetic-ns"}
        self.inputs = {
            "desired_path": DESIRED,
            "client": self.client,
            "token": "synthetic-token",
            "kubeconfig": Path("/synthetic"),
            "journal": [],
        }
        self.patches = [
            patch("scripts.openbao.guards.freeze_target", return_value=self.target),
            patch("scripts.openbao.guards.assert_mutation_allowed"),
        ]
        for p in self.patches:
            p.start()
            self.addCleanup(p.stop)

    def test_plan_confirmation_binds_revision_and_exact_changes(self):
        self.client.state[("issuance-role", "openbao-acceptance")]["token_max_ttl"] = 900
        plan = apply.run(confirm="", **self.inputs)
        self.assertEqual(plan["status"], "confirmation-required")
        self.assertEqual(self.client.writes, [])
        self.assertEqual(
            plan["changes"],
            [{"kind": "issuance-role", "name": "openbao-acceptance", "action": "write"}],
        )
        result = apply.run(confirm=plan["confirmation"], **self.inputs)
        self.assertEqual(result["status"], "pass")
        self.assertEqual(
            self.client.state[("issuance-role", "openbao-acceptance")]["token_max_ttl"], 600
        )

    def test_independent_readback_detects_acknowledged_but_ignored_write(self):
        self.client.state[("issuance-role", "openbao-acceptance")]["token_max_ttl"] = 900
        self.client.ignore_writes = True
        plan = apply.run(confirm="", **self.inputs)
        with self.assertRaises(SafeError):
            apply.run(confirm=plan["confirmation"], **self.inputs)

    def test_missing_operator_requires_explicit_password_and_preserves_it_on_later_apply(self):
        del self.client.state[("userpass-user", "openbao-operator")]
        plan = apply.run(confirm="", **self.inputs)
        with self.assertRaises(SafeError):
            apply.run(confirm=plan["confirmation"], **self.inputs)
        self.assertEqual(self.client.writes, [])
        result = apply.run(
            confirm=plan["confirmation"],
            operator_password="synthetic-retained-password",
            **self.inputs,
        )
        self.assertEqual(result["status"], "pass")
        self.assertNotIn("synthetic-retained-password", str(result))
        self.assertEqual(self.client.password_received, "synthetic-retained-password")
        self.assertEqual(
            self.client.state[("userpass-user", "openbao-operator")]["policies"],
            ["openbao-operator"],
        )
        self.client.password_received = None
        self.client.state[("userpass-user", "openbao-operator")]["token_max_ttl"] = 7200
        plan = apply.run(confirm="", **self.inputs)
        result = apply.run(confirm=plan["confirmation"], **self.inputs)
        self.assertEqual(result["status"], "pass")
        self.assertIsNone(self.client.password_received)

    def test_missing_or_raw_audit_cannot_pass_independent_readback(self):
        self.client.audit = {}
        with self.assertRaises(SafeError):
            apply.ensure_audit(self.client, "synthetic-token")
        self.client.audit = {
            "homelab/": {
                "type": "file",
                "options": {"file_path": "stdout", "log_raw": "true", "hmac_accessor": "true"},
            }
        }
        with self.assertRaises(SafeError):
            apply.ensure_audit(self.client, "synthetic-token")

    def test_unowned_objects_wrong_backend_and_sensitive_fields_refuse(self):
        for key, fields in [
            (("policy", "unowned"), {"policy": {}}),
            (("auth-method", "homelab-jwt/"), {"type": "userpass"}),
            (("kubernetes-config", "kubernetes"), {"service_account_jwt": "synthetic-private"}),
        ]:
            self.setUp()
            self.client.state[key] = fields
            with self.subTest(key=key), self.assertRaises(SafeError):
                apply.run(confirm="", **self.inputs)
            self.assertEqual(self.client.writes, [])


class ApplyBoundaryTest(unittest.TestCase):
    def test_source_endpoint_cannot_redirect_owned_write_to_arbitrary_api(self):
        import dataclasses

        document = load_document(DESIRED)
        document["objects"] = (dataclasses.replace(document["objects"][0], path="sys/init"),)
        with self.assertRaises(SafeError):
            apply._safe_source(document)

    def test_changed_plan_requires_fresh_confirmation(self):
        client = StateClient()
        client.state[("issuance-role", "openbao-acceptance")]["token_max_ttl"] = 900
        target = {"source_revision": "a" * 40, "namespace_uid": "synthetic-ns"}
        with patch("scripts.openbao.guards.freeze_target", return_value=target):
            plan = apply.run(
                client=client, token="synthetic", kubeconfig=Path("/synthetic"), journal=[]
            )
            client.state[("issuance-role", "openbao-acceptance")]["token_max_ttl"] = 1200
            result = apply.run(
                client=client,
                token="synthetic",
                kubeconfig=Path("/synthetic"),
                confirm=plan["confirmation"],
                journal=[],
            )
        self.assertEqual(result["status"], "confirmation-required")
        self.assertEqual(client.writes, [])

    def test_root_transport_404_is_distinct_from_denied_read(self):
        import urllib.error

        from scripts.openbao.client import BaoClient, NotFound, ReadFailure

        for code, error in ((404, NotFound), (403, ReadFailure)):
            with self.subTest(code=code):

                def opener(*args, code=code, **kwargs):
                    raise urllib.error.HTTPError(
                        "https://openbao.example", code, "synthetic", {}, None
                    )

                with self.assertRaises(error):
                    BaoClient("https://openbao.example", opener=opener).read("sys/auth")


if __name__ == "__main__":
    unittest.main()
