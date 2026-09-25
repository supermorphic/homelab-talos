"""Independent examples of the source-owned OpenBao drift contract."""

import json
import tempfile
import unittest
from pathlib import Path

from scripts.openbao.configuration import Difference, ObjectSpec, SafeError, load_desired
from scripts.openbao.drift import compare, compare_inventory, sanitize

ROOT = Path(__file__).resolve().parents[3]
DESIRED = ROOT / "kubernetes/apps/security/openbao/config/desired.json"
MARKER = "CREDENTIAL_MARKER_9f8d"


class DriftTest(unittest.TestCase):
    def test_changed_namespace_and_missing_role(self):
        role = ObjectSpec(
            "issuance-role",
            "openbao-acceptance",
            "kubernetes/roles/openbao-acceptance",
            {
                "allowed_kubernetes_namespaces": ["openbao-acceptance"],
                "service_account_name": "openbao-issued-reader",
                "token_default_ttl": 600,
                "token_max_ttl": 600,
            },
        )
        live = dict(role.fields, allowed_kubernetes_namespaces=["*"])
        self.assertEqual(
            [(x.field, x.state) for x in compare(role, live)],
            [("allowed_kubernetes_namespaces", "changed")],
        )
        self.assertEqual(
            [(x.name, x.state) for x in compare(role, None)], [("openbao-acceptance", "missing")]
        )

    def test_wildcard_audience_subject_and_operator_assignment(self):
        role = ObjectSpec(
            "jwt-role",
            "openbao-config-reader",
            "auth/homelab-jwt/role/openbao-config-reader",
            {
                "bound_audiences": ["openbao-internal"],
                "bound_subject": "system:serviceaccount:openbao:openbao",
                "token_policies": ["openbao-config-reader"],
                "token_no_default_policy": True,
            },
        )
        actual = dict(role.fields, bound_audiences=["*"], bound_subject="*")
        self.assertEqual(
            {x.field for x in compare(role, actual)}, {"bound_audiences", "bound_subject"}
        )
        operator = ObjectSpec(
            "userpass-user",
            "openbao-operator",
            "auth/homelab-userpass/users/openbao-operator",
            {"policies": ["openbao-operator"], "token_no_default_policy": True},
        )
        self.assertEqual(
            [
                (x.field, x.state)
                for x in compare(
                    operator, {"policies": ["default"], "token_no_default_policy": True}
                )
            ],
            [("policies", "changed")],
        )

    def test_policy_capability_and_malformed_policy(self):
        expected = {"path": {"kubernetes/creds/openbao-acceptance": {"capabilities": ["read"]}}}
        spec = ObjectSpec(
            "policy",
            "openbao-acceptance",
            "sys/policies/acl/openbao-acceptance",
            {"policy": expected},
        )
        widened = {
            "path": {"kubernetes/creds/openbao-acceptance": {"capabilities": ["update", "read"]}}
        }
        self.assertEqual(
            [(x.field, x.state) for x in compare(spec, {"policy": json.dumps(widened)})],
            [("policy", "changed")],
        )
        self.assertEqual(
            [(x.field, x.state) for x in compare(spec, {"policy": "path bad {"})],
            [("policy", "inaccessible")],
        )

    def test_unknown_fields_and_incomplete_read_are_not_clean(self):
        spec = ObjectSpec(
            "jwt-role",
            "openbao-backup",
            "auth/homelab-jwt/role/openbao-backup",
            {"bound_audiences": ["openbao-internal"], "token_ttl": 600},
        )
        self.assertEqual(
            [
                (x.field, x.state)
                for x in compare(
                    spec,
                    {
                        "bound_audiences": ["openbao-internal"],
                        "token_ttl": 600,
                        "bound_claims": {"evil": MARKER},
                    },
                )
            ],
            [("bound_claims", "unexpected")],
        )
        self.assertEqual(
            [(x.field, x.state) for x in compare(spec, {"token_ttl": 600})],
            [("bound_audiences", "inaccessible")],
        )
        self.assertEqual(
            [(x.field, x.state) for x in compare(spec, SafeError("read-denied"))],
            [(None, "inaccessible")],
        )

    def test_duration_set_order_and_documented_default(self):
        spec = ObjectSpec(
            "jwt-role",
            "openbao-backup",
            "auth/homelab-jwt/role/openbao-backup",
            {
                "bound_audiences": ["one", "two"],
                "token_ttl": 600,
                "token_max_ttl": 600,
                "token_no_default_policy": True,
            },
        )
        live = {
            "bound_audiences": ["two", "one"],
            "token_ttl": "10m0s",
            "token_max_ttl": "600s",
            "token_no_default_policy": True,
            "role_type": "jwt",
        }
        self.assertEqual(compare(spec, live), [])

    def test_builtin_auth_mount_default_metadata_does_not_drift(self):
        spec = ObjectSpec("auth-method", "homelab-jwt/", "sys/auth/homelab-jwt/", {"type": "jwt"})
        live = {
            "type": "jwt",
            "plugin_version": "",
            "external_entropy_access": False,
            "options": None,
            "accessor": MARKER,
        }
        self.assertEqual(compare(spec, live), [])

    def test_inventory_and_sanitization_never_echo_unknown_names(self):
        differences = compare_inventory(
            {"homelab-jwt/", "homelab-userpass/", "token/"},
            {"homelab-jwt/", "token/", MARKER},
            "auth-method",
        )
        self.assertEqual(
            sanitize(differences),
            {
                "differences": [
                    {"kind": "auth-method", "name": "homelab-userpass/", "state": "missing"},
                    {"kind": "auth-method", "state": "unexpected", "count": 1},
                ]
            },
        )
        self.assertNotIn(MARKER, json.dumps(sanitize(differences)))
        with self.assertRaises(SafeError) as caught:
            compare_inventory({"safe"}, [MARKER], "policy")
        self.assertNotIn(MARKER, str(caught.exception))

    def test_missing_reader_policy_and_secret_marker_name(self):
        differences = compare_inventory(
            {"openbao-config-reader", "root"}, {"root", "openbao-" + MARKER}, "policy"
        )
        self.assertEqual(
            sanitize(differences),
            {
                "differences": [
                    {"kind": "policy", "name": "openbao-config-reader", "state": "missing"},
                    {"kind": "policy", "state": "unexpected", "count": 1},
                ]
            },
        )

    def test_nested_security_field_has_strict_type(self):
        spec = ObjectSpec(
            "jwt-config", "homelab-jwt", "auth/homelab-jwt/config", {"provider_config": {}}
        )
        self.assertEqual(
            [(x.field, x.state) for x in compare(spec, {"provider_config": MARKER})],
            [("provider_config", "inaccessible")],
        )

    def test_source_loads_all_required_objects_and_rejects_bad_json(self):
        objects = load_desired(DESIRED)
        self.assertIn("openbao-config-reader", {x.name for x in objects})
        self.assertIn("kubernetes/roles/openbao-acceptance", {x.path for x in objects})
        provider = next(x for x in objects if x.kind == "jwt-config")
        self.assertEqual(provider.fields["provider_config"], {"provider": "kubernetes"})
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "desired.json"
            source.write_text('{"schema_version":1,"schema_version":2,' + MARKER + "}")
            with self.assertRaises(SafeError) as caught:
                load_desired(source)
            self.assertNotIn(MARKER, str(caught.exception))

    def test_reader_acl_has_only_self_revocation_update(self):
        reader = next(
            x
            for x in load_desired(DESIRED)
            if x.name == "openbao-config-reader" and x.kind == "policy"
        )
        paths = reader.fields["policy"]["path"]
        updates = {path for path, rule in paths.items() if "update" in rule["capabilities"]}
        self.assertEqual(updates, {"auth/token/revoke-self"})
        for path in (
            "auth/token/create",
            "auth/token/revoke",
            "auth/token/revoke-accessor",
            "auth/token/lookup",
            "kubernetes/creds/openbao-acceptance",
        ):
            self.assertNotIn(path, paths)
        self.assertFalse(any("*" in path for path in paths))
        self.assertFalse(any(path.startswith("kubernetes/creds/") for path in paths))
        self.assertTrue(all("sudo" not in rule["capabilities"] for rule in paths.values()))

    def test_invalid_source_policy_and_unreviewed_field_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "policies").mkdir()
            for policy in (DESIRED.parent / "policies").glob("*.json"):
                (root / "policies" / policy.name).write_bytes(policy.read_bytes())
            (root / "policies/operator.json").write_text(
                '{"path":{"safe":{"capabilities":["read","read"]}}}'
            )
            source = json.loads(DESIRED.read_text())
            (root / "desired.json").write_text(json.dumps(source))
            # Duplicate capabilities do not broaden access, but malformed policy structure does.
            self.assertEqual(len(load_desired(root / "desired.json")), len(source["objects"]))
            (root / "policies/operator.json").write_text(
                '{"path":{"safe":{"capabilities":"read"}}}'
            )
            with self.assertRaises(SafeError):
                load_desired(root / "desired.json")
            next(o for o in source["objects"] if o["kind"] == "jwt-role")["fields"][
                "unreviewed_security_field"
            ] = MARKER
            (root / "desired.json").write_text(json.dumps(source))
            with self.assertRaises(SafeError) as caught:
                load_desired(root / "desired.json")
            self.assertNotIn(MARKER, str(caught.exception))

    def test_marker_in_policy_error_and_exception_is_redacted(self):
        spec = ObjectSpec(
            "policy",
            "openbao-config-reader",
            "sys/policies/acl/openbao-config-reader",
            {"policy": {"path": {"safe": {"capabilities": ["read"]}}}},
        )
        result = compare(spec, {"policy": MARKER})
        self.assertNotIn(MARKER, json.dumps(sanitize(result)))
        self.assertNotIn(MARKER, str(SafeError(MARKER)))

    def test_anonymous_inaccessible_result_is_rejected(self):
        with self.assertRaises(SafeError) as caught:
            sanitize([Difference("policy", None, None, "inaccessible")])
        self.assertEqual(str(caught.exception), "invalid-response")

    def test_complete_acl_policy_read_uses_identity_and_default_cas(self):
        spec = ObjectSpec(
            "policy",
            "openbao-backup",
            "sys/policies/acl/openbao-backup",
            {"policy": {"path": {"sys/storage/raft/snapshot": {"capabilities": ["read"]}}}},
        )
        live = {
            "name": "openbao-backup",
            "policy": json.dumps(spec.fields["policy"]),
            "modified": "2026-01-01T00:00:00Z",
            "version": 3,
            "cas_required": False,
        }
        self.assertEqual(compare(spec, live), [])
        self.assertEqual(
            [(x.field, x.state) for x in compare(spec, dict(live, cas_required=True))],
            [("cas_required", "unexpected")],
        )

    def test_complete_jwt_config_read_keeps_empty_key_sources_benign(self):
        spec = ObjectSpec(
            "jwt-config",
            "homelab-jwt",
            "auth/homelab-jwt/config",
            {
                "bound_issuer": "https://kubernetes.default.svc.cluster.local",
                "provider_config": {"provider": "kubernetes"},
            },
        )
        live = dict(spec.fields, oidc_discovery_ca_pem=[], jwt_validation_pubkeys=[])
        self.assertEqual(compare(spec, live), [])
        changed = dict(live, jwt_validation_pubkeys=[MARKER])
        self.assertEqual(
            [(x.field, x.state) for x in compare(spec, changed)],
            [("jwt_validation_pubkeys", "unexpected")],
        )
        self.assertNotIn(MARKER, json.dumps(sanitize(compare(spec, changed))))

    def test_complete_jwt_role_read_checks_legacy_aliases(self):
        spec = ObjectSpec(
            "jwt-role",
            "openbao-backup",
            "auth/homelab-jwt/role/openbao-backup",
            {
                "bound_audiences": ["openbao-kubernetes-broker"],
                "bound_subject": "system:serviceaccount:openbao:openbao-backup",
                "user_claim": "sub",
                "token_policies": ["openbao-backup"],
                "token_ttl": 600,
                "token_max_ttl": 600,
                "token_no_default_policy": True,
            },
        )
        live = dict(
            spec.fields,
            policies=["openbao-backup"],
            ttl="10m0s",
            max_ttl=600,
            period=0,
            num_uses=0,
            bound_cidrs=[],
            groups_claim="",
        )
        self.assertEqual(compare(spec, live), [])
        changed = dict(live, policies=["default"], ttl=900)
        self.assertEqual(
            {(x.field, x.state) for x in compare(spec, changed)},
            {("policies", "changed"), ("ttl", "changed")},
        )

    def test_userpass_policy_alias_does_not_mask_assignment_change(self):
        spec = ObjectSpec(
            "userpass-user",
            "openbao-operator",
            "auth/homelab-userpass/users/openbao-operator",
            {"policies": ["openbao-operator"], "token_ttl": 3600},
        )
        live = {
            "policies": ["openbao-operator"],
            "token_policies": ["openbao-operator"],
            "token_ttl": 3600,
        }
        self.assertEqual(compare(spec, live), [])
        self.assertEqual(
            [(x.field, x.state) for x in compare(spec, dict(live, token_policies=["default"]))],
            [("token_policies", "changed")],
        )

    def test_sanitizer_counts_any_name_outside_source_allowlist(self):
        findings = [
            Difference("policy", MARKER, None, "missing"),
            Difference("policy", "openbao-" + MARKER, "policy", "changed"),
        ]
        self.assertEqual(
            sanitize(findings),
            {"differences": [{"kind": "policy", "state": "unexpected", "count": 2}]},
        )
        self.assertNotIn(MARKER, json.dumps(sanitize(findings)))

    def test_source_requires_all_inventory_kinds_even_when_objects_removed(self):
        original = json.loads(DESIRED.read_text())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "policies").mkdir()
            for policy in (DESIRED.parent / "policies").glob("*.json"):
                (root / "policies" / policy.name).write_bytes(policy.read_bytes())
            source = root / "desired.json"
            missing_inventory = json.loads(json.dumps(original))
            del missing_inventory["inventories"]["policy"]
            source.write_text(json.dumps(missing_inventory))
            with self.assertRaises(SafeError):
                load_desired(source)
            missing_both = json.loads(json.dumps(original))
            missing_both["objects"] = [o for o in missing_both["objects"] if o["kind"] != "policy"]
            del missing_both["inventories"]["policy"]
            del missing_both["builtin_exceptions"]["policy"]
            source.write_text(json.dumps(missing_both))
            with self.assertRaises(SafeError):
                load_desired(source)


if __name__ == "__main__":
    unittest.main()
