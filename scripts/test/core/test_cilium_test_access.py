"""Request and grant invariants for the dedicated pinned connectivity client."""

import copy
import json
import unittest

import yaml

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
                # The Kubernetes Namespace handlers put the target name in
                # admission attributes, including for cluster-scoped CREATE.
                "namespace": name,
                "name": name,
                "subResource": "",
                "resource": {"group": "", "version": "v1", "resource": "namespaces"},
                "userInfo": {"username": IDENTITY},
            }
            self.assertTrue(self.admits(policy, req, obj))
            self.assertFalse(self.admits(policy, {**req, "namespace": ""}, obj))
            omitted_namespace = {k: v for k, v in req.items() if k != "namespace"}
            self.assertFalse(self.admits(policy, omitted_namespace, obj))
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
            for operation, new, previous in (
                ("UPDATE", updated, stored),
                ("DELETE", None, stored),
            ):
                for namespace in ("", "kube-system", NAMESPACES[(NAMESPACES.index(name) + 1) % 3]):
                    with self.subTest(name=name, operation=operation, namespace=namespace):
                        self.assertFalse(
                            self.admits(
                                policy,
                                {**req, "operation": operation, "namespace": namespace},
                                new,
                                previous,
                            )
                        )
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

    def test_system_runtime_grants_are_dedicated_to_cilium_and_kube_system(self):
        roles = [
            d
            for d in self.documents
            if d["kind"] == "Role"
            and d["metadata"]["name"] == "homelab-test-cilium-system-runtime"
        ]
        self.assertEqual(len(roles), 1)
        self.assertEqual(roles[0]["metadata"]["namespace"], "kube-system")
        self.assertEqual(
            roles[0]["rules"],
            [
                {
                    "apiGroups": [""],
                    "resources": ["pods/exec", "pods/portforward"],
                    "verbs": ["get", "create"],
                },
                {"apiGroups": [""], "resources": ["pods/proxy"], "verbs": ["get"]},
            ],
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

    def test_system_connect_targets_cover_canonical_components_and_recovery(self):
        policy = "homelab-test-cilium-system-connect"
        for name, container in (
            ("cilium-abcde", "cilium-agent"),
            ("cilium-abcde", "sysdump-1770000000"),
            ("cilium-envoy-abcde", "cilium-envoy"),
            ("cilium-operator-abcde12345-abcde", "cilium-operator"),
            ("hubble-abcde", "hubble"),
            ("hubble-relay-abcde12345-abcde", "hubble-relay"),
            ("clustermesh-apiserver-abcde12345-abcde", "apiserver"),
            ("clustermesh-apiserver-abcde12345-abcde", "kvstoremesh"),
            ("clustermesh-apiserver-abcde12345-abcde", "etcd"),
            ("tetragon-abcde", "tetragon"),
            ("tetragon-abcde", "sysdump-1770000000"),
            ("spire-server-0", "spire-server"),
            ("spire-server-0", "sysdump-1770000000"),
            ("sysdump-abcde", "cilium-agent"),
            ("sysdump-abcde", "tetragon"),
            ("sysdump-abcde", "spire-server"),
        ):
            req = {
                "operation": "CONNECT",
                "namespace": "kube-system",
                "name": name,
                "subResource": "exec",
                "resource": {"group": "", "version": "v1", "resource": "pods"},
                "userInfo": {"username": IDENTITY},
            }
            obj = {
                "container": container,
                "command": ["gops", "stats", "1"],
                "stdin": False,
                "tty": False,
            }
            with self.subTest(pod=name, container=container):
                self.assertTrue(self.admits(policy, req, obj))
                self.assertTrue(self.admits(policy, {**req, "subResource": "portforward"}, {}))
                self.assertFalse(self.admits(policy, req, {**obj, "container": "unrelated"}))
                self.assertFalse(self.admits(policy, req, {**obj, "stdin": True}))
                self.assertFalse(self.admits(policy, req, {**obj, "tty": True}))
                for key, value in (
                    ("namespace", "openbao"),
                    ("name", "openbao-0"),
                    ("name", "unrelated-pod"),
                    ("subResource", "attach"),
                ):
                    self.assertFalse(self.admits(policy, {**req, key: value}, obj))

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

    def test_clusterwide_policy_grants_match_the_four_fixed_fixtures(self):
        names = [
            "allow-ingress-specific-namespace-ccnp",
            "allow-egress-specific-namespace-ccnp",
            "host-firewall-ingress",
            "host-firewall-egress",
        ]
        role = [
            d
            for d in self.documents
            if d["kind"] == "ClusterRole"
            and d["metadata"]["name"] == "homelab-test-cilium-cluster-policies"
        ]
        self.assertEqual(len(role), 1)
        self.assertEqual(
            role[0]["rules"],
            [
                {
                    "apiGroups": ["cilium.io"],
                    "resources": ["ciliumclusterwidenetworkpolicies"],
                    "resourceNames": names,
                    "verbs": ["get", "patch", "delete"],
                }
            ],
        )
        binding = [
            d
            for d in self.documents
            if d["kind"] == "ClusterRoleBinding"
            and d["metadata"]["name"] == "homelab-test-cilium-cluster-policies"
        ]
        self.assertEqual(len(binding), 1)
        self.assertEqual(
            binding[0]["subjects"],
            [
                {
                    "kind": "ServiceAccount",
                    "namespace": "kube-system",
                    "name": "homelab-test-cilium-connectivity",
                }
            ],
        )

    def test_clusterwide_policies_preserve_complete_canonical_specs(self):
        policy = "homelab-test-cilium-cluster-policies"
        for path in sorted((helpers.ROOT / "tests/fixtures/cilium/policies").glob("*.yaml")):
            obj = yaml.safe_load(path.read_text())
            req = {
                "operation": "CREATE",
                "namespace": "",
                "name": obj["metadata"]["name"],
                "subResource": "",
                "resource": {
                    "group": "cilium.io",
                    "version": "v2",
                    "resource": "ciliumclusterwidenetworkpolicies",
                },
                "userInfo": {"username": IDENTITY},
            }
            with self.subTest(name=req["name"]):
                self.assertTrue(self.admits(policy, req, obj))
                stored = copy.deepcopy(obj)
                stored["metadata"].update(uid="policy-fixture", resourceVersion="1", generation=1)
                stored["status"] = {"nodes": {"fixture-node": {"ok": True}}}
                self.assertTrue(self.admits(policy, {**req, "operation": "DELETE"}, None, stored))
                applied = copy.deepcopy(stored)
                applied["metadata"]["resourceVersion"] = "2"
                self.assertTrue(
                    self.admits(policy, {**req, "operation": "UPDATE"}, applied, stored)
                )
                for key, value in (
                    ("spec", {"endpointSelector": {}}),
                    ("specs", [obj["spec"]]),
                    ("arbitrary", True),
                ):
                    bad = copy.deepcopy(obj)
                    bad[key] = value
                    self.assertFalse(self.admits(policy, req, bad))
                for field, value in (
                    ("name", "production-policy"),
                    ("namespace", "openbao"),
                    ("annotations", {"arbitrary": "value"}),
                    ("labels", {"arbitrary": "value"}),
                    ("ownerReferences", [{"uid": "other"}]),
                    ("finalizers", ["keep-me"]),
                ):
                    bad = copy.deepcopy(obj)
                    bad["metadata"][field] = value
                    self.assertFalse(self.admits(policy, req, bad))
                self.assertFalse(self.admits(policy, {**req, "namespace": "cilium-test-1"}, obj))
                self.assertFalse(self.admits(policy, {**req, "subResource": "status"}, obj))
                replacement = copy.deepcopy(applied)
                replacement["metadata"]["uid"] = "replacement"
                self.assertFalse(
                    self.admits(policy, {**req, "operation": "UPDATE"}, replacement, stored)
                )

    def test_failure_diagnostics_custom_resource_inventory_is_read_only(self):
        roles = [
            d
            for d in self.documents
            if d["kind"] == "ClusterRole"
            and d["metadata"]["name"] == "homelab-test-cilium-diagnostic-observation"
        ]
        self.assertEqual(len(roles), 1)
        expected = {
            "cilium.io": {
                "ciliumcidrgroups",
                "ciliumegressgatewaypolicies",
                "ciliumlocalredirectpolicies",
                "ciliumendpointslices",
                "ciliumnodeconfigs",
                "ciliumpodippools",
                "ciliuml2announcementpolicies",
                "ciliumenvoyconfigs",
                "ciliumclusterwideenvoyconfigs",
                "ciliumgatewayclassconfigs",
                "ciliumbgppeeringpolicies",
                "ciliumbgpclusterconfigs",
                "ciliumbgppeerconfigs",
                "ciliumbgpadvertisements",
                "ciliumbgpnodeconfigs",
                "ciliumbgpnodeconfigoverrides",
                "podinfo",
                "tracingpolicies",
                "tracingpoliciesnamespaced",
            },
            "gateway.networking.k8s.io": {
                "listenersets",
                "backendtlspolicies",
                "tlsroutes",
                "tcproutes",
                "udproutes",
                "grpcroutes",
            },
            "networking.k8s.io": {"ingressclasses"},
            "policy.networking.k8s.io": {"clusternetworkpolicies"},
        }
        self.assertEqual(len(roles[0]["rules"]), len(expected))
        for rule in roles[0]["rules"]:
            self.assertEqual(len(rule["apiGroups"]), 1)
            self.assertEqual(set(rule["resources"]), expected.pop(rule["apiGroups"][0]))
            self.assertEqual(rule["verbs"], ["get", "list"])
        self.assertEqual(expected, {})
        binding = [
            d
            for d in self.documents
            if d["kind"] == "ClusterRoleBinding"
            and d["metadata"]["name"] == "homelab-test-cilium-diagnostic-observation"
        ]
        self.assertEqual(len(binding), 1)
        self.assertEqual(
            binding[0]["subjects"],
            [
                {
                    "kind": "ServiceAccount",
                    "name": "homelab-test-cilium-connectivity",
                    "namespace": "kube-system",
                }
            ],
        )

    def test_sysdump_copy_recovery_keeps_the_registered_privileged_runtime_family(self):
        policy = "homelab-test-cilium-copy-diagnostics"
        roles = [
            d
            for d in self.documents
            if d["kind"] == "Role"
            and d["metadata"]["name"] == "homelab-test-cilium-copy-diagnostics"
        ]
        self.assertEqual(len(roles), 1)
        self.assertEqual(roles[0]["metadata"]["namespace"], "kube-system")
        self.assertEqual(
            roles[0]["rules"],
            [{"apiGroups": [""], "resources": ["pods"], "verbs": ["create", "delete"]}],
        )
        req = {
            "operation": "CREATE",
            "namespace": "kube-system",
            "name": "sysdump-abcde",
            "subResource": "",
            "resource": {"group": "", "version": "v1", "resource": "pods"},
            "userInfo": {"username": IDENTITY},
        }
        for account, container, image in (
            ("cilium", "cilium-agent", "quay.io/cilium/cilium:v1.19.0"),
            ("tetragon", "tetragon", "quay.io/cilium/tetragon:v1.6.0"),
            ("spire-server", "spire-server", "ghcr.io/spiffe/spire-server:1.14.1"),
        ):
            obj = {
                "apiVersion": "v1",
                "kind": "Pod",
                "metadata": {
                    "name": req["name"],
                    "generateName": "sysdump-",
                    "namespace": "kube-system",
                },
                "spec": {
                    "serviceAccountName": account,
                    "nodeName": "fixture-node",
                    "hostNetwork": True,
                    "hostPID": False,
                    "hostIPC": False,
                    "dnsPolicy": "ClusterFirstWithHostNet",
                    "securityContext": {},
                    "restartPolicy": "Never",
                    "tolerations": [{"operator": "Exists"}],
                    "volumes": [
                        {"name": "source-runtime", "hostPath": {"path": "/synthetic-runtime"}}
                    ],
                    "containers": [
                        {
                            "name": container,
                            "image": image,
                            "command": ["/bin/sleep", "1d"],
                            "env": [{"name": "SOURCE", "value": "synthetic"}],
                            "volumeMounts": [{"name": "source-runtime", "mountPath": "/runtime"}],
                            "securityContext": {"capabilities": {"add": ["NET_ADMIN"]}},
                        }
                    ],
                },
            }
            self.assertTrue(self.admits(policy, req, obj))
            stored = copy.deepcopy(obj)
            stored["metadata"]["uid"] = "sysdump-fixture"
            self.assertTrue(self.admits(policy, {**req, "operation": "DELETE"}, None, stored))
            self.assertFalse(self.admits(policy, {**req, "operation": "UPDATE"}, stored, stored))
            for field, value in (
                ("serviceAccountName", "openbao"),
                ("serviceAccountName", "default"),
                ("restartPolicy", "Always"),
                ("initContainers", [obj["spec"]["containers"][0]]),
                ("ephemeralContainers", [obj["spec"]["containers"][0]]),
            ):
                bad = copy.deepcopy(obj)
                bad["spec"][field] = value
                self.assertFalse(self.admits(policy, req, bad))
            for field, value in (
                ("command", ["/bin/sh"]),
                ("args", ["extra"]),
                ("envFrom", [{"secretRef": {"name": "other"}}]),
                ("image", "example.invalid/unregistered:latest"),
                ("stdin", True),
                ("tty", True),
            ):
                bad = copy.deepcopy(obj)
                bad["spec"]["containers"][0][field] = value
                self.assertFalse(self.admits(policy, req, bad))
            bad = copy.deepcopy(obj)
            bad["spec"]["containers"].append(copy.deepcopy(obj["spec"]["containers"][0]))
            self.assertFalse(self.admits(policy, req, bad))
            for field, value in (("namespace", "openbao"), ("name", "openbao-0")):
                self.assertFalse(self.admits(policy, {**req, field: value}, obj))

    def test_namespaced_fixture_roles_are_separate_from_system_runtime(self):
        # Ephemeral namespaces do not exist at GitOps installation time.
        self.assertFalse(any(d["metadata"].get("namespace") in NAMESPACES for d in self.documents))
        for name in ("homelab-test-cilium-fixtures-1", "homelab-test-cilium-fixtures-ccnp"):
            roles = [
                d
                for d in self.documents
                if d["kind"] == "ClusterRole" and d["metadata"]["name"] == name
            ]
            self.assertEqual(len(roles), 1)
            self.assertNotIn("namespace", roles[0]["metadata"])
            for rule in roles[0]["rules"]:
                self.assertFalse(
                    set(rule["resources"])
                    & {
                        "roles",
                        "rolebindings",
                        "namespaces",
                        "nodes",
                        "serviceaccounts/token",
                        "persistentvolumeclaims",
                    }
                )
                self.assertNotIn("*", rule["resources"] + rule["apiGroups"] + rule["verbs"])
                self.assertNotIn("deletecollection", rule["verbs"])
                if "secrets" in rule["resources"] and "get" in rule["verbs"]:
                    self.assertEqual(
                        rule["resourceNames"], ["cabundle", "externaltarget-tls", "header-match"]
                    )
            bindings = [
                d
                for d in self.documents
                if d["kind"] in {"RoleBinding", "ClusterRoleBinding"}
                and d["roleRef"]["name"] == name
            ]
            self.assertEqual(bindings, [])

    def test_fixture_bootstrap_can_bind_only_two_fixed_roles(self):
        role = next(
            d
            for d in self.documents
            if d["kind"] == "ClusterRole"
            and d["metadata"]["name"] == "homelab-test-cilium-bootstrap"
        )
        self.assertEqual(
            role["rules"],
            [
                {
                    "apiGroups": ["rbac.authorization.k8s.io"],
                    "resources": ["rolebindings"],
                    "verbs": ["create"],
                },
                {
                    "apiGroups": ["rbac.authorization.k8s.io"],
                    "resources": ["rolebindings"],
                    "resourceNames": ["homelab-test-cilium-fixtures"],
                    "verbs": ["get", "delete"],
                },
                {
                    "apiGroups": ["rbac.authorization.k8s.io"],
                    "resources": ["clusterroles"],
                    "resourceNames": [
                        "homelab-test-cilium-fixtures-1",
                        "homelab-test-cilium-fixtures-ccnp",
                    ],
                    "verbs": ["bind"],
                },
            ],
        )

    def test_fixture_binding_rejects_other_namespace_role_subject_or_lifecycle(self):
        for namespace in NAMESPACES:
            role = (
                "homelab-test-cilium-fixtures-1"
                if namespace == "cilium-test-1"
                else "homelab-test-cilium-fixtures-ccnp"
            )
            obj = {
                "apiVersion": "rbac.authorization.k8s.io/v1",
                "kind": "RoleBinding",
                "metadata": {
                    "name": "homelab-test-cilium-fixtures",
                    "namespace": namespace,
                    "annotations": {OWNER: "synthetic-run"},
                    "ownerReferences": [
                        {
                            "apiVersion": "v1",
                            "kind": "Namespace",
                            "name": namespace,
                            "uid": "namespace-fixture",
                        }
                    ],
                },
                "roleRef": {
                    "apiGroup": "rbac.authorization.k8s.io",
                    "kind": "ClusterRole",
                    "name": role,
                },
                "subjects": [
                    {
                        "kind": "ServiceAccount",
                        "name": "homelab-test-cilium-connectivity",
                        "namespace": "kube-system",
                    }
                ],
            }
            req = {
                "operation": "CREATE",
                "namespace": namespace,
                "name": obj["metadata"]["name"],
                "subResource": "",
                "resource": {
                    "group": "rbac.authorization.k8s.io",
                    "version": "v1",
                    "resource": "rolebindings",
                },
                "userInfo": {"username": IDENTITY},
            }
            policy = "homelab-test-cilium-bootstrap"
            self.assertTrue(self.admits(policy, req, obj))
            stored = copy.deepcopy(obj)
            stored["metadata"].update(uid="binding-fixture", resourceVersion="1")
            self.assertTrue(self.admits(policy, {**req, "operation": "DELETE"}, None, stored))
            self.assertFalse(self.admits(policy, {**req, "operation": "UPDATE"}, stored, stored))
            for path, value in (
                (("roleRef", "name"), "cluster-admin"),
                (
                    ("roleRef", "name"),
                    "homelab-test-cilium-fixtures-ccnp"
                    if namespace == "cilium-test-1"
                    else "homelab-test-cilium-fixtures-1",
                ),
                (("roleRef", "kind"), "Role"),
                (
                    ("subjects",),
                    [
                        {
                            "kind": "ServiceAccount",
                            "name": "homelab-test-runner",
                            "namespace": "kube-system",
                        }
                    ],
                ),
                (("subjects",), obj["subjects"] * 2),
                (("metadata", "annotations", OWNER), ""),
                (("metadata", "annotations", "other"), "value"),
                (("metadata", "ownerReferences"), []),
                (("metadata", "namespace"), "kube-system"),
                (("metadata", "name"), "other"),
                (("metadata", "finalizers"), ["hold"]),
            ):
                bad = copy.deepcopy(obj)
                parent = bad
                for key in path[:-1]:
                    parent = parent[key]
                parent[path[-1]] = value
                self.assertFalse(self.admits(policy, req, bad))
            self.assertFalse(self.admits(policy, {**req, "namespace": "kube-system"}, obj))

    def test_namespaced_policy_inventory_excludes_unregistered_and_production_targets(self):
        families = json.loads(
            (helpers.ROOT / "tests/fixtures/cilium/policy-names.json").read_text()
        )["families"]
        resources = {
            "CiliumNetworkPolicy": ("cilium.io", "v2", "ciliumnetworkpolicies"),
            "CiliumLocalRedirectPolicy": ("cilium.io", "v2", "ciliumlocalredirectpolicies"),
            "NetworkPolicy": ("networking.k8s.io", "v1", "networkpolicies"),
        }
        policy = "homelab-test-cilium-fixtures"
        for kind, names in families.items():
            group, version, resource = resources[kind]
            for name in names:
                obj = {
                    "apiVersion": f"{group}/{version}",
                    "kind": kind,
                    "metadata": {"name": name, "namespace": "cilium-test-1"},
                    "spec": {"endpointSelector": {"matchLabels": {"kind": "client"}}},
                }
                req = {
                    "operation": "CREATE",
                    "namespace": "cilium-test-1",
                    "name": name,
                    "subResource": "",
                    "resource": {"group": group, "version": version, "resource": resource},
                    "userInfo": {"username": IDENTITY},
                }
                self.assertTrue(self.admits(policy, req, obj), name)
                bad = copy.deepcopy(obj)
                bad["metadata"]["name"] = "unregistered-policy"
                self.assertFalse(self.admits(policy, {**req, "name": "unregistered-policy"}, bad))
                self.assertFalse(self.admits(policy, {**req, "namespace": "openbao"}, obj))
                self.assertFalse(self.admits(policy, {**req, "subResource": "status"}, obj))
                self.assertFalse(
                    self.admits(policy, {**req, "namespace": "cilium-test-ccnp1"}, obj)
                )

    def test_named_connectivity_workloads_keep_their_account_image_and_mount_family(self):
        policy = "homelab-test-cilium-fixtures"
        for namespace, name in (
            ("cilium-test-1", "client"),
            ("cilium-test-ccnp1", "client-ccnp"),
            ("cilium-test-ccnp2", "client-ccnp"),
        ):
            obj = {
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "metadata": {
                    "name": name,
                    "namespace": namespace,
                    "labels": {"name": name, "kind": "client"},
                },
                "spec": {
                    "replicas": 1,
                    "selector": {"matchLabels": {"name": name, "kind": "client"}},
                    "template": {
                        "metadata": {"name": name, "labels": {"name": name, "kind": "client"}},
                        "spec": {
                            "serviceAccountName": name,
                            "containers": [
                                {
                                    "name": name,
                                    "image": "quay.io/cilium/alpine-curl:v1.10.0@sha256:913e8c9f3d960dde03882defa0edd3a919d529c2eb167caa7f54194528bde364",
                                    "command": ["/usr/bin/pause"],
                                    "securityContext": {"capabilities": {"add": ["NET_RAW"]}},
                                }
                            ],
                        },
                    },
                },
            }
            req = {
                "operation": "CREATE",
                "namespace": namespace,
                "name": name,
                "subResource": "",
                "resource": {"group": "apps", "version": "v1", "resource": "deployments"},
                "userInfo": {"username": IDENTITY},
            }
            self.assertTrue(self.admits(policy, req, obj))
            stored = copy.deepcopy(obj)
            stored["metadata"]["uid"] = "deployment-fixture"
            self.assertTrue(self.admits(policy, {**req, "operation": "DELETE"}, None, stored))
            self.assertFalse(self.admits(policy, {**req, "operation": "UPDATE"}, stored, stored))
            for field, value in (
                ("serviceAccountName", "openbao"),
                ("initContainers", [{}]),
                ("volumes", [{"name": "host", "hostPath": {"path": "/synthetic-runtime"}}]),
                ("volumes", [{"name": "other", "secret": {"secretName": "unregistered"}}]),
            ):
                bad = copy.deepcopy(obj)
                bad["spec"]["template"]["spec"][field] = value
                self.assertFalse(self.admits(policy, req, bad))
            for field, value in (
                ("image", "example.invalid/unregistered:latest"),
                ("envFrom", [{"secretRef": {"name": "unregistered"}}]),
            ):
                bad = copy.deepcopy(obj)
                bad["spec"]["template"]["spec"]["containers"][0][field] = value
                self.assertFalse(self.admits(policy, req, bad))
            bad = copy.deepcopy(obj)
            bad["metadata"]["name"] = "unregistered"
            self.assertFalse(self.admits(policy, {**req, "name": "unregistered"}, bad))

    def test_fixture_connections_keep_the_same_profile_and_forbid_interactive_or_other_namespace_access(
        self,
    ):
        policy = "homelab-test-cilium-system-connect"
        for namespace, pod, container in (
            ("cilium-test-1", "client-7654321-abcde", "client"),
            ("cilium-test-1", "host-netns-abcde", "host-netns"),
            ("cilium-test-ccnp1", "client-ccnp-7654321-abcde", "client-ccnp"),
            ("cilium-test-ccnp2", "client-ccnp-7654321-abcde", "client-ccnp"),
        ):
            req = {
                "operation": "CONNECT",
                "namespace": namespace,
                "name": pod,
                "subResource": "exec",
                "resource": {"group": "", "version": "v1", "resource": "pods"},
                "userInfo": {"username": IDENTITY},
            }
            obj = {
                "container": container,
                "command": ["/usr/bin/curl", "http://synthetic.example"],
                "stdin": False,
                "tty": False,
                "stdout": True,
                "stderr": True,
            }
            self.assertTrue(self.admits(policy, req, obj))
            for field, value in (("stdin", True), ("tty", True), ("container", "openbao")):
                self.assertFalse(self.admits(policy, req, {**obj, field: value}))
            self.assertFalse(self.admits(policy, {**req, "namespace": "openbao"}, obj))
            self.assertFalse(self.admits(policy, {**req, "subResource": "portforward"}, {}))
            self.assertFalse(self.admits(policy, {**req, "name": "production-7654321-abcde"}, obj))

    def test_fixture_accounts_services_configmaps_and_test_secrets_have_finite_targets(self):
        policy = "homelab-test-cilium-fixtures"
        inputs = [
            ("ServiceAccount", "client", {}),
            ("ConfigMap", "coredns-configmap", {"data": {"Corefile": ". { local ready log }"}}),
            ("ConfigMap", "frr-config", {"data": {"frr.conf": "synthetic"}}),
            (
                "Service",
                "echo-same-node",
                {
                    "spec": {
                        "type": "NodePort",
                        "selector": {"name": "echo-same-node"},
                        "ports": [{"name": "http", "port": 8080}],
                    }
                },
            ),
            ("Secret", "cabundle", {"type": "Opaque", "data": {"ca.crt": "dGVzdA=="}}),
            (
                "Secret",
                "externaltarget-tls",
                {
                    "type": "kubernetes.io/tls",
                    "data": {"tls.crt": "dGVzdA==", "tls.key": "dGVzdA=="},
                },
            ),
            ("Secret", "header-match", {"type": "Opaque", "data": {"value": "dGVzdA=="}}),
        ]
        for kind, name, fields in inputs:
            obj = {
                "apiVersion": "v1",
                "kind": kind,
                "metadata": {"name": name, "namespace": "cilium-test-1"},
                **fields,
            }
            req = {
                "operation": "CREATE",
                "namespace": "cilium-test-1",
                "name": name,
                "subResource": "",
                "resource": {
                    "group": "",
                    "version": "v1",
                    "resource": {
                        "ServiceAccount": "serviceaccounts",
                        "ConfigMap": "configmaps",
                        "Service": "services",
                        "Secret": "secrets",
                    }[kind],
                },
                "userInfo": {"username": IDENTITY},
            }
            self.assertTrue(self.admits(policy, req, obj))
            bad = copy.deepcopy(obj)
            bad["metadata"]["name"] = "unregistered"
            self.assertFalse(self.admits(policy, {**req, "name": "unregistered"}, bad))
            bad = copy.deepcopy(obj)
            bad["metadata"]["namespace"] = "kube-system"
            self.assertFalse(self.admits(policy, {**req, "namespace": "kube-system"}, bad))
            if kind == "Secret":
                bad = copy.deepcopy(obj)
                bad["data"]["unregistered"] = "dGVzdA=="
                self.assertFalse(self.admits(policy, req, bad))
                self.assertFalse(
                    self.admits(
                        policy, req, {**obj, "type": "kubernetes.io/service-account-token"}
                    )
                )
            if kind == "ServiceAccount":
                self.assertFalse(
                    self.admits(policy, req, {**obj, "secrets": [{"name": "unregistered"}]})
                )
            if kind == "Service":
                bad = copy.deepcopy(obj)
                bad["spec"]["selector"] = {"name": "production"}
                self.assertFalse(self.admits(policy, req, bad))

    def test_global_fixtures_have_only_named_apply_grants(self):
        roles = [
            d
            for d in self.documents
            if d["kind"] == "ClusterRole"
            and d["metadata"]["name"] == "homelab-test-cilium-global-fixtures"
        ]
        self.assertEqual(len(roles), 1)
        self.assertEqual(
            roles[0]["rules"],
            [
                {
                    "apiGroups": ["cilium.io"],
                    "resources": ["ciliumcidrgroups"],
                    "resourceNames": [
                        "cilium-test-external-cidr",
                        "cilium-test-external-cidr-label",
                    ],
                    "verbs": ["get", "patch", "delete"],
                },
                {
                    "apiGroups": ["cilium.io"],
                    "resources": ["ciliumclusterwideenvoyconfigs"],
                    "resourceNames": ["client-egress-to-fqdns-proxy-one.one.one.one"],
                    "verbs": ["get", "patch", "delete"],
                },
                {
                    "apiGroups": ["policy.networking.k8s.io"],
                    "resources": ["clusternetworkpolicies"],
                    "resourceNames": ["echo-ingress-from-client-tiered-wildcard-pass-l7"],
                    "verbs": ["get", "patch", "delete"],
                },
            ],
        )

    def test_global_specs_and_cidr_shapes_preserve_the_pinned_fixture_boundary(self):
        policy = "homelab-test-cilium-global-fixtures"
        inputs = [
            (
                yaml.safe_load((helpers.ROOT / "tests/fixtures/cilium" / name).read_text()),
                group,
                version,
                resource,
            )
            for name, group, version, resource in (
                ("cluster-envoy.yaml", "cilium.io", "v2", "ciliumclusterwideenvoyconfigs"),
                (
                    "cluster-network-policy.yaml",
                    "policy.networking.k8s.io",
                    "v1alpha2",
                    "clusternetworkpolicies",
                ),
            )
        ]
        for version in ("v2", "v2alpha1"):
            for name in ("cilium-test-external-cidr", "cilium-test-external-cidr-label"):
                obj = {
                    "apiVersion": f"cilium.io/{version}",
                    "kind": "CiliumCIDRGroup",
                    "metadata": {"name": name},
                    "spec": {"externalCIDRs": ["192.0.2.0/24", "2001:db8::/120"]},
                }
                if name.endswith("-label"):
                    obj["metadata"]["labels"] = {"destination": "external"}
                inputs.append((obj, "cilium.io", version, "ciliumcidrgroups"))
        for obj, group, version, resource in inputs:
            name = obj["metadata"]["name"]
            req = {
                "operation": "CREATE",
                "namespace": "",
                "name": name,
                "subResource": "",
                "resource": {"group": group, "version": version, "resource": resource},
                "userInfo": {"username": IDENTITY},
            }
            self.assertTrue(self.admits(policy, req, obj), name)
            old = copy.deepcopy(obj)
            old["metadata"].update(uid="global-fixture", resourceVersion="1")
            self.assertTrue(self.admits(policy, {**req, "operation": "DELETE"}, None, old))
            self.assertTrue(self.admits(policy, {**req, "operation": "UPDATE"}, old, old))
            bad = copy.deepcopy(obj)
            bad["metadata"]["name"] = "production-fixture"
            self.assertFalse(self.admits(policy, {**req, "name": "production-fixture"}, bad))
            bad = copy.deepcopy(obj)
            bad["spec"]["unregistered"] = True
            self.assertFalse(self.admits(policy, req, bad))
            for key in ("namespace", "subResource"):
                self.assertFalse(self.admits(policy, {**req, key: "other"}, obj))
            replacement = copy.deepcopy(old)
            replacement["metadata"]["uid"] = "replacement"
            self.assertFalse(self.admits(policy, {**req, "operation": "UPDATE"}, replacement, old))
            if obj["kind"] == "ClusterNetworkPolicy":
                bad = copy.deepcopy(obj)
                bad["spec"]["subject"]["pods"]["namespaceSelector"] = {}
                self.assertFalse(self.admits(policy, req, bad))
            if obj["kind"] == "CiliumCIDRGroup":
                bad = copy.deepcopy(obj)
                bad["spec"]["externalCIDRs"] = ["invalid-address"]
                self.assertFalse(self.admits(policy, req, bad))
                bad = copy.deepcopy(obj)
                bad["metadata"]["labels"] = {"destination": "production"}
                self.assertFalse(self.admits(policy, req, bad))


if __name__ == "__main__":
    unittest.main()
