"""Request and grant invariants for the dedicated pinned connectivity client."""

import copy
import unittest

from scripts.test.core import test_dedicated_profiles as helpers

IDENTITY = "system:serviceaccount:kube-system:homelab-test-cilium-connectivity"
OWNER = "homelab.supermorphic.com/test-run"
NAMESPACES = ["cilium-test-1", "cilium-test-ccnp1", "cilium-test-ccnp2"]


class CiliumAccessTests(unittest.TestCase):
    setUpClass = classmethod(helpers.DedicatedFluxMutationTests.setUpClass.__func__)
    policy = helpers.DedicatedFluxMutationTests.policy
    evaluate = helpers.DedicatedFluxMutationTests.evaluate
    admits = helpers.DedicatedFluxMutationTests.admits

    def test_namespace_lifecycle_grants_are_finite_and_have_no_node_or_rbac_write(self):
        roles = [
            d
            for d in self.documents
            if d["kind"] == "ClusterRole"
            and d["metadata"]["name"] == "homelab-test-cilium-namespaces"
        ]
        self.assertEqual(len(roles), 1)
        self.assertEqual(
            roles[0]["rules"],
            [
                {"apiGroups": [""], "resources": ["namespaces"], "verbs": ["create"]},
                {
                    "apiGroups": [""],
                    "resources": ["namespaces"],
                    "resourceNames": NAMESPACES,
                    "verbs": ["update", "delete"],
                },
            ],
        )
        bindings = [
            d
            for d in self.documents
            if d["kind"] == "ClusterRoleBinding"
            and d["metadata"]["name"] == "homelab-test-cilium-namespaces"
        ]
        self.assertEqual(len(bindings), 1)
        self.assertEqual(
            bindings[0]["subjects"],
            [
                {
                    "kind": "ServiceAccount",
                    "name": "homelab-test-cilium-connectivity",
                    "namespace": "kube-system",
                }
            ],
        )

    def test_namespace_parent_requires_fixture_identity_and_run_ownership(self):
        policy = "homelab-test-cilium-namespaces"
        for name in NAMESPACES:
            obj = {
                "apiVersion": "v1",
                "kind": "Namespace",
                "metadata": {
                    "name": name,
                    "labels": {
                        "app.kubernetes.io/name": "cilium-cli",
                        "pod-security.kubernetes.io/enforce": "privileged",
                    },
                    "annotations": {OWNER: "synthetic-run"},
                },
                "spec": {"finalizers": ["kubernetes"]},
            }
            req = {
                "operation": "CREATE",
                "namespace": "",
                "name": name,
                "subResource": "",
                "resource": {"group": "", "version": "v1", "resource": "namespaces"},
                "userInfo": {"username": IDENTITY},
            }
            self.assertTrue(self.admits(policy, req, obj))
            for metadata in (
                {"annotations": {}},
                {"ownerReferences": [{"uid": "other"}]},
                {"annotations": {OWNER: ""}},
                {"finalizers": ["other"]},
                {"labels": {"app.kubernetes.io/name": "production"}},
                {"annotations": {OWNER: "synthetic-run", "arbitrary": "value"}},
            ):
                bad = copy.deepcopy(obj)
                bad["metadata"].update(metadata)
                self.assertFalse(self.admits(policy, req, bad))
            for key, value in (
                ("name", "kube-system"),
                ("namespace", "kube-system"),
                ("subResource", "finalize"),
            ):
                self.assertFalse(self.admits(policy, {**req, key: value}, obj))
            stored = copy.deepcopy(obj)
            stored["metadata"].update(uid="namespace-fixture", resourceVersion="1")
            stored["metadata"]["labels"]["kubernetes.io/metadata.name"] = name
            self.assertTrue(self.admits(policy, {**req, "operation": "DELETE"}, None, stored))
            updated = copy.deepcopy(stored)
            updated["metadata"]["annotations"]["clustermesh.cilium.io/global"] = "true"
            updated["metadata"]["resourceVersion"] = "2"
            self.assertTrue(self.admits(policy, {**req, "operation": "UPDATE"}, updated, stored))
            self.assertFalse(self.admits(policy, {**req, "operation": "UPDATE"}, stored, updated))
            for path, value in (
                (("metadata", "annotations", OWNER), "replacement-run"),
                (("metadata", "uid"), "replacement"),
                (("spec", "finalizers"), []),
                (("metadata", "labels", "pod-security.kubernetes.io/enforce"), "restricted"),
            ):
                bad = copy.deepcopy(updated)
                parent = bad
                for k in path[:-1]:
                    parent = parent[k]
                parent[path[-1]] = value
                self.assertFalse(self.admits(policy, {**req, "operation": "UPDATE"}, bad, stored))

    def test_helm_failure_diagnostics_has_only_system_secret_inventory_and_named_etcd_get(self):
        roles = [
            d
            for d in self.documents
            if d["kind"] == "Role"
            and d["metadata"]["name"] == "homelab-test-cilium-helm-observation"
        ]
        self.assertEqual(len(roles), 1)
        self.assertEqual(roles[0]["metadata"]["namespace"], "kube-system")
        self.assertEqual(
            roles[0]["rules"],
            [
                {"apiGroups": [""], "resources": ["secrets"], "verbs": ["list"]},
                {
                    "apiGroups": [""],
                    "resources": ["secrets"],
                    "resourceNames": ["cilium-etcd-secrets"],
                    "verbs": ["get"],
                },
            ],
        )
        bindings = [
            d
            for d in self.documents
            if d["kind"] == "RoleBinding" and d["metadata"] == roles[0]["metadata"]
        ]
        self.assertEqual(len(bindings), 1)
        self.assertEqual(
            bindings[0]["subjects"],
            [
                {
                    "kind": "ServiceAccount",
                    "name": "homelab-test-cilium-connectivity",
                    "namespace": "kube-system",
                }
            ],
        )


if __name__ == "__main__":
    unittest.main()
