"""Literal expectations for the dedicated test identity boundaries."""

import subprocess
import unittest
from pathlib import Path

import yaml

from scripts.openbao import credentials

ROOT = Path(__file__).resolve().parents[3]
BINDINGS = {
    "test-flux-restart": ("test.flux-restart",),
    "test-cilium-connectivity": ("test.cilium-connectivity",),
    "test-node-reschedule": ("chainsaw.resilience.plex-cross-node-reschedule",),
    "test-conformance": ("conformance.quick", "conformance.certified"),
    "test-openbao-issuance": ("test.openbao-issuance",),
    "test-openbao-ha": ("test.openbao-ha",),
    "test-openbao-restore": ("test.openbao-restore-drill",),
    "test-openbao-lifecycle": ("test.agent-credentials",),
}


class DedicatedIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run(
            ["kustomize", "build", str(ROOT / "kubernetes/apps/kube-system/agent-access/app")],
            capture_output=True,
            text=True,
            check=True,
        )
        cls.documents = list(yaml.safe_load_all(result.stdout))

    def test_dedicated_suite_profile_and_account_correspondence(self):
        self.assertEqual(credentials.SUITE_PROFILE_BINDINGS, BINDINGS)
        for profile in BINDINGS:
            self.assertEqual(credentials.PROFILES[profile], "homelab-" + profile)
        self.assertEqual(
            BINDINGS["test-conformance"], ("conformance.quick", "conformance.certified")
        )

    def test_dedicated_accounts_are_precreated_and_tokenless(self):
        for profile in BINDINGS:
            with self.subTest(profile=profile):
                accounts = [
                    d
                    for d in self.documents
                    if d["kind"] == "ServiceAccount"
                    and d["metadata"]["name"] == "homelab-" + profile
                ]
                self.assertEqual(len(accounts), 1)
                self.assertEqual(accounts[0]["metadata"]["namespace"], "kube-system")
                self.assertIs(accounts[0]["automountServiceAccountToken"], False)
                self.assertNotIn("secrets", accounts[0])

    def test_conformance_has_one_explicit_administrator_binding(self):
        admins = [
            d
            for d in self.documents
            if d["kind"] in {"RoleBinding", "ClusterRoleBinding"}
            and d["roleRef"]["name"] == "cluster-admin"
        ]
        self.assertEqual(len(admins), 1)
        self.assertEqual(admins[0]["kind"], "ClusterRoleBinding")
        self.assertEqual(admins[0]["metadata"]["name"], "homelab-test-conformance")
        self.assertEqual(
            admins[0]["subjects"],
            [
                {
                    "kind": "ServiceAccount",
                    "name": "homelab-test-conformance",
                    "namespace": "kube-system",
                }
            ],
        )


class DedicatedFluxMutationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from scripts.test.core.test_test_access_manifests import TestAccessPolicyTests

        TestAccessPolicyTests.setUpClass()
        cls.documents = TestAccessPolicyTests.documents
        cls.env = TestAccessPolicyTests.env
        cls.programs = {}

    def policy(self, name):
        from scripts.test.core.test_test_access_manifests import TestAccessPolicyTests

        return TestAccessPolicyTests.policy(self, name)

    def evaluate(self, expression, activation):
        from scripts.test.core.test_test_access_manifests import TestAccessPolicyTests

        return TestAccessPolicyTests.evaluate(self, expression, activation)

    def admits(self, name, request, obj, old=None):
        from scripts.test.core.test_test_access_manifests import TestAccessPolicyTests

        return TestAccessPolicyTests.admits(self, name, request, obj, old)

    def request(self, group, resource, name):
        return {
            "resource": {"group": group, "version": "v1", "resource": resource},
            "subResource": "",
            "namespace": "flux-system",
            "operation": "UPDATE",
            "name": name,
            "userInfo": {
                "username": "system:serviceaccount:kube-system:homelab-test-flux-restart"
            },
        }

    def test_only_four_controller_template_restart_annotations_may_change(self):
        import copy

        for name in (
            "source-controller",
            "kustomize-controller",
            "helm-controller",
            "notification-controller",
        ):
            req = self.request("apps", "deployments", name)
            old = {
                "apiVersion": "apps/v1",
                "kind": "Deployment",
                "metadata": {
                    "name": name,
                    "namespace": "flux-system",
                    "uid": "fixture-uid",
                    "resourceVersion": "12",
                    "generation": 1,
                    "labels": {"app": name},
                    "annotations": {"fixed": "value"},
                },
                "spec": {
                    "replicas": 1,
                    "selector": {"matchLabels": {"app": name}},
                    "template": {
                        "metadata": {"labels": {"app": name}, "annotations": {"fixed": "value"}},
                        "spec": {"containers": [{"name": "manager", "image": "fixture:1"}]},
                    },
                },
                "status": {"readyReplicas": 1},
            }
            obj = copy.deepcopy(old)
            obj["spec"]["template"]["metadata"]["annotations"][
                "kubectl.kubernetes.io/restartedAt"
            ] = "2026-10-02T12:00:00Z"
            obj["metadata"]["resourceVersion"] = "13"
            obj["metadata"]["generation"] = 2
            self.assertTrue(self.admits("homelab-test-flux-restart", req, obj, old))
            changes = {
                "image": lambda d: d["spec"]["template"]["spec"]["containers"][0].update(
                    image="other:1"
                ),
                "replicas": lambda d: d["spec"].update(replicas=3),
                "selector": lambda d: d["spec"]["selector"]["matchLabels"].update(app="other"),
                "template-label": lambda d: d["spec"]["template"]["metadata"]["labels"].update(
                    app="other"
                ),
                "template-annotation": lambda d: d["spec"]["template"]["metadata"][
                    "annotations"
                ].update(fixed="other"),
                "template-field": lambda d: d["spec"]["template"]["metadata"].update(
                    ownerReferences=[{"uid": "other"}]
                ),
                "metadata-annotation": lambda d: d["metadata"]["annotations"].update(
                    fixed="other"
                ),
                "uid": lambda d: d["metadata"].update(uid="other"),
                "status": lambda d: d["status"].update(readyReplicas=3),
                "timestamp": lambda d: d["spec"]["template"]["metadata"]["annotations"].update(
                    {"kubectl.kubernetes.io/restartedAt": "payload"}
                ),
            }
            for change, apply in changes.items():
                with self.subTest(controller=name, change=change):
                    bad = copy.deepcopy(obj)
                    apply(bad)
                    self.assertFalse(self.admits("homelab-test-flux-restart", req, bad, old))
            for field, value in (
                ("name", "unrelated-controller"),
                ("namespace", "media"),
                ("subResource", "status"),
            ):
                with self.subTest(controller=name, request=field):
                    self.assertFalse(
                        self.admits("homelab-test-flux-restart", {**req, field: value}, obj, old)
                    )

    def test_dedicated_reconcile_is_limited_to_source_and_two_kustomizations(self):
        import copy

        for group, resource, name in (
            ("source.toolkit.fluxcd.io", "gitrepositories", "flux-system"),
            ("kustomize.toolkit.fluxcd.io", "kustomizations", "flux-canary"),
            ("kustomize.toolkit.fluxcd.io", "kustomizations", "cluster-apps"),
        ):
            req = self.request(group, resource, name)
            old = {
                "metadata": {
                    "name": name,
                    "namespace": "flux-system",
                    "labels": {"app": "fixture"},
                    "annotations": {"fixed": "value"},
                },
                "spec": {"interval": "1m"},
            }
            obj = copy.deepcopy(old)
            obj["metadata"]["annotations"]["reconcile.fluxcd.io/requestedAt"] = (
                "2026-10-02T12:00:00Z"
            )
            self.assertTrue(self.admits("homelab-test-flux-restart-reconcile", req, obj, old))
            bad = copy.deepcopy(obj)
            bad["spec"]["interval"] = "1s"
            self.assertFalse(self.admits("homelab-test-flux-restart-reconcile", req, bad, old))
            bad = copy.deepcopy(obj)
            bad["metadata"]["annotations"]["fixed"] = "other"
            self.assertFalse(self.admits("homelab-test-flux-restart-reconcile", req, bad, old))
            self.assertFalse(
                self.admits(
                    "homelab-test-flux-restart-reconcile", {**req, "name": "unrelated"}, obj, old
                )
            )


class DedicatedNodeMutationTests(unittest.TestCase):
    policy = DedicatedFluxMutationTests.policy
    evaluate = DedicatedFluxMutationTests.evaluate
    admits = DedicatedFluxMutationTests.admits

    @classmethod
    def setUpClass(cls):
        DedicatedFluxMutationTests.setUpClass()
        cls.documents = DedicatedFluxMutationTests.documents
        cls.env = DedicatedFluxMutationTests.env
        cls.programs = {}

    @staticmethod
    def request(resource, name, namespace="", operation="UPDATE"):
        return {
            "resource": {"group": "", "version": "v1", "resource": resource},
            "subResource": "",
            "namespace": namespace,
            "operation": operation,
            "name": name,
            "userInfo": {
                "username": "system:serviceaccount:kube-system:homelab-test-node-reschedule"
            },
        }

    def test_only_named_nodes_schedulability_may_change(self):
        import copy

        for name in ("nuc1", "nuc2", "nuc3"):
            req = self.request("nodes", name)
            old = {
                "apiVersion": "v1",
                "kind": "Node",
                "metadata": {
                    "name": name,
                    "uid": "node-fixture",
                    "resourceVersion": "12",
                    "labels": {"kubernetes.io/hostname": name},
                    "annotations": {"fixed": "value"},
                },
                "spec": {
                    "podCIDR": "192.0.2.0/24",
                    "taints": [{"key": "fixture", "effect": "NoSchedule"}],
                },
                "status": {"conditions": [{"type": "Ready", "status": "True"}]},
            }
            obj = copy.deepcopy(old)
            obj["spec"]["unschedulable"] = True
            obj["metadata"]["resourceVersion"] = "13"
            self.assertTrue(self.admits("homelab-test-node-scheduling", req, obj, old))
            uncordon = copy.deepcopy(obj)
            uncordon["spec"]["unschedulable"] = False
            self.assertTrue(self.admits("homelab-test-node-scheduling", req, uncordon, obj))
            del uncordon["spec"]["unschedulable"]
            self.assertTrue(self.admits("homelab-test-node-scheduling", req, uncordon, obj))
            for field, value in (
                ("podCIDR", "198.51.100.0/24"),
                ("taints", []),
                ("providerID", "other"),
                ("unschedulable", "true"),
            ):
                with self.subTest(node=name, spec=field):
                    bad = copy.deepcopy(obj)
                    bad["spec"][field] = value
                    self.assertFalse(self.admits("homelab-test-node-scheduling", req, bad, old))
            for field, value in (
                ("labels", {}),
                ("annotations", {}),
                ("ownerReferences", [{"uid": "other"}]),
                ("uid", "other"),
            ):
                with self.subTest(node=name, metadata=field):
                    bad = copy.deepcopy(obj)
                    bad["metadata"][field] = value
                    self.assertFalse(self.admits("homelab-test-node-scheduling", req, bad, old))
            bad = copy.deepcopy(obj)
            bad["status"]["conditions"][0]["status"] = "False"
            self.assertFalse(self.admits("homelab-test-node-scheduling", req, bad, old))
            for field, value in (
                ("name", "unrelated-node"),
                ("namespace", "media"),
                ("subResource", "status"),
            ):
                self.assertFalse(
                    self.admits("homelab-test-node-scheduling", {**req, field: value}, obj, old)
                )

    def test_runtime_is_confined_to_the_plex_application_container(self):
        req = self.request("pods", "plex-abcde12345-abcde", "media", "CONNECT")
        req["subResource"] = "exec"
        obj = {
            "container": "app",
            "command": ["test", "-d", "/Volumes/Prometheus/media"],
            "stdout": True,
            "stderr": True,
            "stdin": False,
            "tty": False,
        }
        self.assertTrue(self.admits("homelab-test-node-plex-runtime", req, obj))
        for name in (
            "qbittorrent-abcde12345-abcde",
            "plex-policy-control-1234567890-1",
            "unrelated",
        ):
            self.assertFalse(
                self.admits("homelab-test-node-plex-runtime", {**req, "name": name}, obj)
            )
        self.assertFalse(
            self.admits("homelab-test-node-plex-runtime", {**req, "namespace": "openbao"}, obj)
        )
        for key, value in (("container", "sidecar"), ("stdin", True), ("tty", True)):
            self.assertFalse(
                self.admits("homelab-test-node-plex-runtime", req, {**obj, key: value})
            )

    def test_disruption_is_confined_to_owned_plex_pods(self):
        import copy

        req = self.request("pods", "plex-abcde12345-abcde", "media", "DELETE")
        old = {
            "metadata": {
                "name": req["name"],
                "namespace": "media",
                "uid": "pod-fixture",
                "labels": {"app.kubernetes.io/name": "plex"},
                "ownerReferences": [
                    {
                        "apiVersion": "apps/v1",
                        "kind": "ReplicaSet",
                        "name": "plex-abcde12345",
                        "uid": "replicaset-fixture",
                        "controller": True,
                    }
                ],
            }
        }
        self.assertTrue(self.admits("homelab-test-node-plex-disruption", req, None, old))
        for field in ("owner", "label", "name", "namespace", "uid"):
            bad = copy.deepcopy(old)
            if field == "owner":
                bad["metadata"]["ownerReferences"][0]["name"] = "other-abcde12345"
            elif field == "label":
                bad["metadata"]["labels"]["app.kubernetes.io/name"] = "other"
            elif field == "uid":
                del bad["metadata"]["uid"]
            else:
                bad["metadata"][field] = "other"
            self.assertFalse(self.admits("homelab-test-node-plex-disruption", req, None, bad))
