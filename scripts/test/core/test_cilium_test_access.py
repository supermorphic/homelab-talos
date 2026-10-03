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

    def test_stopped_container_recovery_appends_only_the_source_sleeping_container(self):
        old = {
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {
                "name": "cilium-abcde",
                "namespace": "kube-system",
                "uid": "pod-fixture",
                "labels": {"k8s-app": "cilium"},
            },
            "spec": {
                "serviceAccountName": "cilium",
                "nodeName": "fixture-node",
                "hostNetwork": True,
                "containers": [
                    {
                        "name": "cilium-agent",
                        "image": "quay.io/cilium/cilium:synthetic",
                        "env": [{"name": "SOURCE", "value": "synthetic"}],
                        "volumeMounts": [{"name": "runtime", "mountPath": "/runtime"}],
                        "securityContext": {"capabilities": {"add": ["NET_ADMIN"]}},
                    }
                ],
                "volumes": [{"name": "runtime", "hostPath": {"path": "/synthetic-runtime"}}],
            },
        }
        req = {
            "operation": "UPDATE",
            "namespace": "kube-system",
            "name": "cilium-abcde",
            "subResource": "ephemeralcontainers",
            "resource": {"group": "", "version": "v1", "resource": "pods"},
            "userInfo": {"username": IDENTITY},
        }
        source = old["spec"]["containers"][0]
        added = {
            k: copy.deepcopy(source[k])
            for k in ("image", "env", "volumeMounts", "securityContext")
        }
        added.update(
            name="sysdump-1770000000",
            targetContainerName="cilium-agent",
            command=["/bin/sleep", "1d"],
        )
        obj = copy.deepcopy(old)
        obj["spec"]["ephemeralContainers"] = [added]
        policy = "homelab-test-cilium-ephemeral-diagnostics"
        self.assertTrue(self.admits(policy, req, obj, old))
        defaulted = copy.deepcopy(obj)
        defaulted["spec"]["ephemeralContainers"][0].update(
            imagePullPolicy="IfNotPresent",
            resources={},
            terminationMessagePath="/dev/termination-log",
            terminationMessagePolicy="File",
            stdin=False,
            stdinOnce=False,
            tty=False,
        )
        self.assertTrue(self.admits(policy, req, defaulted, old))
        for labels, container in (
            ({"app.kubernetes.io/name": "tetragon"}, "tetragon"),
            ({"app": "spire-server"}, "spire-server"),
        ):
            source_pod = copy.deepcopy(old)
            source_pod["metadata"]["labels"] = labels
            source_pod["spec"]["containers"][0]["name"] = container
            patched = copy.deepcopy(source_pod)
            patched["spec"]["ephemeralContainers"] = [{**added, "targetContainerName": container}]
            self.assertTrue(self.admits(policy, req, patched, source_pod))
        for key, value in (
            ("image", "other:1"),
            ("command", ["sh"]),
            ("resources", {"limits": {"cpu": "1"}}),
            ("envFrom", [{"secretRef": {"name": "unrelated"}}]),
            ("args", ["unrelated"]),
            ("env", [{"name": "OTHER", "value": "synthetic"}]),
            ("volumeMounts", [{"name": "runtime", "mountPath": "/other"}]),
            ("securityContext", {"privileged": True}),
            ("targetContainerName", "unrelated"),
            ("name", "unrelated"),
        ):
            bad = copy.deepcopy(obj)
            bad["spec"]["ephemeralContainers"][0][key] = value
            self.assertFalse(self.admits(policy, req, bad, old))
        for key, value in (
            ("serviceAccountName", "other"),
            ("nodeName", "other-node"),
            ("hostNetwork", False),
        ):
            bad = copy.deepcopy(obj)
            bad["spec"][key] = value
            self.assertFalse(self.admits(policy, req, bad, old))
        for key, value in (("uid", "other"), ("labels", {"k8s-app": "other"})):
            bad = copy.deepcopy(obj)
            bad["metadata"][key] = value
            self.assertFalse(self.admits(policy, req, bad, old))
        self.assertFalse(self.admits(policy, {**req, "namespace": "openbao"}, obj, old))
        previous = copy.deepcopy(obj)
        obj["spec"]["ephemeralContainers"].append({**added, "name": "sysdump-1770000001"})
        self.assertTrue(self.admits(policy, req, obj, previous))
        self.assertFalse(self.admits(policy, req, obj, old))
        obj["spec"]["ephemeralContainers"][0]["image"] = "other:1"
        self.assertFalse(self.admits(policy, req, obj, previous))

    def test_stopped_container_recovery_grant_is_dedicated_and_subresource_only(self):
        roles = [
            d
            for d in self.documents
            if d["kind"] == "Role"
            and d["metadata"]["name"] == "homelab-test-cilium-ephemeral-diagnostics"
        ]
        self.assertEqual(len(roles), 1)
        self.assertEqual(roles[0]["metadata"]["namespace"], "kube-system")
        self.assertEqual(
            roles[0]["rules"],
            [{"apiGroups": [""], "resources": ["pods/ephemeralcontainers"], "verbs": ["patch"]}],
        )
        binding = next(
            d
            for d in self.documents
            if d["kind"] == "RoleBinding" and d["metadata"] == roles[0]["metadata"]
        )
        self.assertEqual(
            binding["subjects"],
            [
                {
                    "kind": "ServiceAccount",
                    "name": "homelab-test-cilium-connectivity",
                    "namespace": "kube-system",
                }
            ],
        )

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
