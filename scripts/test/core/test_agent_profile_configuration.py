"""Credential/RBAC boundaries use literal independent expectations."""

import copy
import unittest
from pathlib import Path

import yaml

from scripts.openbao.configuration import ObjectSpec, load_document
from scripts.openbao.drift import compare

ROOT = Path(__file__).resolve().parents[3]
DESIRED = ROOT / "kubernetes/apps/security/openbao/config/desired.json"
ACCOUNTS = {
    "observer": "homelab-observer",
    "diagnostic": "homelab-diagnostic",
    "publisher": "homelab-report-publisher",
    "campaign-coordinator": "homelab-campaign-coordinator",
    "debugger": "homelab-diagnostic",
    "test-runner": "homelab-test-runner",
    "report-publisher": "homelab-report-publisher",
    "test-flux-restart": "homelab-test-flux-restart",
    "test-cilium-connectivity": "homelab-test-cilium-connectivity",
    "test-node-reschedule": "homelab-test-node-reschedule",
    "test-conformance": "homelab-test-conformance",
    "test-openbao-issuance": "homelab-test-openbao-issuance",
    "test-openbao-ha": "homelab-test-openbao-ha",
    "test-openbao-restore": "homelab-test-openbao-restore",
    "test-openbao-lifecycle": "homelab-test-openbao-lifecycle"
}


class AgentProfileConfigurationTests(unittest.TestCase):
    def test_roles_cannot_select_broader_identity_or_lifetime(self):
        objects = {(o.kind, o.name): o for o in load_document(DESIRED)["objects"]}
        for profile, account in ACCOUNTS.items():
            with self.subTest(profile=profile):
                self.assertIn(("issuance-role", profile), objects.keys())
                fields = objects[("issuance-role", profile)].fields
                self.assertEqual(fields["service_account_name"], account)
                self.assertEqual(fields["allowed_kubernetes_namespaces"], ["kube-system"])
                self.assertEqual(fields["token_default_ttl"], 600)
                self.assertEqual(fields["token_max_ttl"], 600)
                self.assertEqual(fields["token_default_audiences"], ["https://192.168.90.20:6443"])
                for key in ("generated_role_rules", "kubernetes_role_name",
                            "allowed_kubernetes_namespace_selector"):
                    self.assertEqual(fields[key], "")

    def test_workstation_session_has_only_issuance_and_self_revoke(self):
        objects = {(o.kind, o.name): o for o in load_document(DESIRED)["objects"]}
        self.assertIn(("approle-role", "agent-workstation"), objects.keys())
        fields = objects[("approle-role", "agent-workstation")].fields
        for key in ("token_ttl", "token_max_ttl", "token_explicit_max_ttl"):
            self.assertEqual(fields[key], 60)
        self.assertEqual(fields["secret_id_ttl"], 7776000)
        self.assertEqual(fields["secret_id_num_uses"], 0)
        self.assertIs(fields["bind_secret_id"], True)
        self.assertIs(fields["token_no_default_policy"], True)
        self.assertEqual(fields["token_period"], 0)
        self.assertEqual(fields["token_type"], "service")
        self.assertEqual(fields["token_policies"], ["agent-profiles"])
        policy = objects[("policy", "agent-profiles")].fields["policy"]
        self.assertEqual(policy, {"path": {
            **{f"kubernetes/creds/{profile}": {"capabilities": ["update"]} for profile in ACCOUNTS},
            "auth/token/revoke-self": {"capabilities": ["update"]},
        }})

    def test_mount_allows_secret_id_lifetime_without_extending_session(self):
        mount = next(o for o in load_document(DESIRED)["objects"]
                     if o.kind == "auth-method" and o.name == "homelab-approle/")
        self.assertEqual(mount.fields["config"]["default_lease_ttl"], 60)
        self.assertEqual(mount.fields["config"]["max_lease_ttl"], 7776000)

    def test_approle_drift_rejects_unknown_authority_and_ttl_changes(self):
        fields = {"bind_secret_id": True, "secret_id_ttl": 7776000,
                  "secret_id_num_uses": 0, "token_ttl": 60, "token_max_ttl": 60,
                  "token_explicit_max_ttl": 60, "token_period": 0,
                  "token_type": "service", "token_policies": ["agent-profiles"],
                  "token_no_default_policy": True}
        spec = ObjectSpec("approle-role", "agent-workstation",
                          "auth/homelab-approle/role/agent-workstation", fields)
        self.assertEqual(compare(spec, fields), [])
        for key, value in (("token_max_ttl", 600), ("token_policies", ["root"]),
                           ("unreviewed_control", True)):
            changed = copy.deepcopy(fields)
            changed[key] = value
            self.assertTrue(compare(spec, changed))

    def test_coordinator_and_issuer_have_only_named_authority(self):
        documents = list(yaml.safe_load_all(
            (ROOT / "kubernetes/apps/kube-system/agent-access/app/rbac.yaml").read_text()))
        by_key = {(d["kind"], d["metadata"]["name"]): d for d in documents}
        self.assertIn(("ServiceAccount", "homelab-campaign-coordinator"), by_key)
        self.assertIn(("Role", "homelab-campaign-coordinator"), by_key)
        role = by_key[("Role", "homelab-campaign-coordinator")]
        self.assertEqual(role["metadata"]["namespace"], "flux-system")
        self.assertEqual(role["rules"], [{"apiGroups": ["coordination.k8s.io"],
            "resources": ["leases"], "resourceNames": ["homelab-test-run-lock"],
            "verbs": ["get", "update"]}])
        issuer = by_key[("Role", "openbao-agent-tokenrequest")]
        self.assertEqual(issuer["metadata"]["namespace"], "kube-system")
        self.assertEqual(issuer["rules"], [{"apiGroups": [""],
            "resources": ["serviceaccounts/token"], "resourceNames": list(dict.fromkeys(ACCOUNTS.values())),
            "verbs": ["create"]}])
        self.assertEqual(by_key[("RoleBinding", "openbao-agent-tokenrequest")]["subjects"],
                         [{"kind": "ServiceAccount", "name": "openbao", "namespace": "openbao"}])
        lease = yaml.safe_load((ROOT /
            "kubernetes/apps/kube-system/agent-access/app/campaign-lease.yaml").read_text())
        self.assertNotIn("spec", lease)


    def test_configuration_reader_observes_each_named_role_without_issuance_authority(self):
        objects = {(o.kind, o.name): o for o in load_document(DESIRED)["objects"]}
        policy = objects[("policy", "openbao-config-reader")].fields["policy"]["path"]
        role_reads = {k: v for k, v in policy.items() if k.startswith("kubernetes/roles/")}
        self.assertEqual(
            role_reads,
            {
                f"kubernetes/roles/{p}": {"capabilities": ["read"]}
                for p in ["openbao-acceptance", *ACCOUNTS]
            },
        )
        self.assertFalse(any(k.startswith("kubernetes/creds/") or "*" in k for k in policy))
        self.assertEqual(
            {k for k, v in policy.items() if "update" in v["capabilities"]},
            {"auth/token/revoke-self"},
        )
        roles = {o.name for o in objects.values() if o.kind == "issuance-role"}
        self.assertEqual(roles, {"openbao-acceptance", *ACCOUNTS})


if __name__ == "__main__":
    unittest.main()
