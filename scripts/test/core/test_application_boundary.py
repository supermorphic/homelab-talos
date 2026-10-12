"""Rendered application authority and independent admission request cases."""

import copy
import subprocess
import unittest
from pathlib import Path

import celpy
import yaml

ROOT = Path(__file__).resolve().parents[3]
PLATFORM = ROOT / "kubernetes/apps/applications/career-ops/platform"


def render(path):
    return list(
        yaml.safe_load_all(subprocess.check_output(["kustomize", "build", str(path)], text=True))
    )


class ApplicationScaffoldTests(unittest.TestCase):
    def test_platform_precedes_connection(self):
        units = {d["metadata"]["name"]: d for d in render(ROOT / "kubernetes/apps")}
        self.assertIn("career-ops-platform", list(units))
        self.assertIn(
            {"name": "career-ops-platform"}, units["career-ops-connection"]["spec"]["dependsOn"]
        )
        self.assertTrue(
            {
                "cilium",
                "internal-gateway",
                "automation-data-postgresql",
                "longhorn-config",
                "kube-prometheus-stack",
            }
            <= {d["name"] for d in units["career-ops-platform"]["spec"]["dependsOn"]}
        )

    def test_connection_starts_suspended(self):
        units = {d["metadata"]["name"]: d for d in render(ROOT / "kubernetes/apps")}
        self.assertIn("career-ops-connection", list(units))
        self.assertIs(units["career-ops-connection"]["spec"]["suspend"], True)

    def test_namespace_restricts_pods_and_gateway_access(self):
        self.assertTrue(PLATFORM.is_dir(), "platform boundary is missing")
        namespace = next(d for d in render(PLATFORM) if d["kind"] == "Namespace")
        self.assertEqual(namespace["metadata"]["name"], "career-ops")
        self.assertEqual(
            namespace["metadata"]["labels"]["pod-security.kubernetes.io/enforce"], "restricted"
        )
        self.assertEqual(
            namespace["metadata"]["labels"]["gateway.supermorphic.com/access"], "internal"
        )
        self.assertEqual(
            {k: v for k, v in namespace["metadata"]["labels"].items() if k.startswith("gateway.")},
            {"gateway.supermorphic.com/access": "internal"},
        )

    def test_controller_denies_remote_bases(self):
        docs = render(ROOT / "kubernetes/flux/clusters/prod/flux-system")
        controller = next(
            d
            for d in docs
            if d["kind"] == "Deployment" and d["metadata"]["name"] == "kustomize-controller"
        )
        self.assertIn(
            "--no-remote-bases=true",
            controller["spec"]["template"]["spec"]["containers"][0]["args"],
        )


RECONCILER = "system:serviceaccount:career-ops:career-ops-reconciler"
COORDINATOR = "system:serviceaccount:career-ops:cv-coordinator"


def workload(account="cv-renderer", kind="Job"):
    pod = {
        "serviceAccountName": account,
        "automountServiceAccountToken": account == "cv-coordinator",
        "securityContext": {
            "runAsNonRoot": True,
            "runAsUser": 1000,
            "seccompProfile": {"type": "RuntimeDefault"},
        },
        "containers": [
            {
                "name": "main",
                "image": "example.invalid/fixture@sha256:" + "a" * 64,
                "securityContext": {
                    "runAsNonRoot": True,
                    "runAsUser": 1000,
                    "readOnlyRootFilesystem": True,
                    "allowPrivilegeEscalation": False,
                    "capabilities": {"drop": ["ALL"]},
                },
                "resources": {
                    "requests": {"cpu": "100m", "memory": "128Mi", "ephemeral-storage": "128Mi"},
                    "limits": {"cpu": "1", "memory": "1Gi", "ephemeral-storage": "2Gi"},
                },
            }
        ],
        "restartPolicy": "Never" if kind in ["Pod", "Job"] else "Always",
    }
    metadata = {
        "name": "fixture",
        "namespace": "career-ops",
        "labels": {"app.kubernetes.io/name": account},
    }
    if kind == "Pod":
        return {"kind": kind, "metadata": metadata, "spec": pod}
    template = {"metadata": {"labels": {"app.kubernetes.io/name": account}}, "spec": pod}
    spec = {"template": template}
    if kind == "Job":
        spec.update({"backoffLimit": 0, "parallelism": 1, "completions": 1})
    return {"kind": kind, "metadata": metadata, "spec": spec}


class ApplicationAuthorityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.documents = render(PLATFORM)
        cls.env = celpy.Environment()
        cls.programs = {}

    from scripts.test.core.test_test_access_manifests import TestAccessPolicyTests as _helpers

    policy = _helpers.policy
    evaluate = _helpers.evaluate
    admits = _helpers.admits

    def admission(
        self,
        obj,
        policy="career-ops-workloads",
        username=RECONCILER,
        operation="CREATE",
        old=None,
        sub="",
    ):
        return self.admits(
            policy,
            {
                "namespace": "career-ops",
                "operation": operation,
                "subResource": sub,
                "userInfo": {"username": username},
            },
            obj,
            old,
        )

    def test_effective_reconciler_permissions(self):
        roles = {d["metadata"]["name"]: d for d in self.documents if d["kind"] == "Role"}
        self.assertIn("career-ops-reconciler", list(roles))
        allowed = {
            (g, r, v)
            for rule in roles["career-ops-reconciler"]["rules"]
            for g in rule["apiGroups"]
            for r in rule["resources"]
            for v in rule["verbs"]
        }
        for forbidden in [
            "secrets",
            "namespaces",
            "pods/exec",
            "pods/log",
            "serviceaccounts/token",
            "*",
        ]:
            self.assertFalse(any(r == forbidden for g, r, v in allowed), forbidden)
        self.assertFalse(any(v in ["impersonate", "escalate", "*"] for g, r, v in allowed))
        bind = [r for r in roles["career-ops-reconciler"]["rules"] if "bind" in r["verbs"]]
        self.assertEqual(
            bind,
            [
                {
                    "apiGroups": ["rbac.authorization.k8s.io"],
                    "resources": ["roles"],
                    "resourceNames": ["cv-render-jobs"],
                    "verbs": ["bind"],
                }
            ],
        )
        runtime = {
            (r, v)
            for rule in roles["cv-render-jobs"]["rules"]
            for r in rule["resources"]
            for v in rule["verbs"]
        }
        self.assertEqual(
            runtime,
            {
                (r, v)
                for r, verbs in [
                    ("jobs", ["create", "get", "list", "watch", "delete"]),
                    ("pods", ["get", "list", "watch"]),
                ]
                for v in verbs
            },
        )
        bindings = [d for d in self.documents if d["kind"] == "RoleBinding"]
        self.assertEqual(len(bindings), 1)
        self.assertEqual(
            bindings[0]["subjects"],
            [
                {
                    "kind": "ServiceAccount",
                    "name": "career-ops-reconciler",
                    "namespace": "career-ops",
                }
            ],
        )

    def test_valid_profiles_and_controller_pods(self):
        for account, kind in [
            ("cv-prepare", "Job"),
            ("cv-renderer", "Job"),
            ("cv-coordinator", "Deployment"),
            ("career-ops-service", "Deployment"),
            ("cv-renderer", "Pod"),
            ("cv-coordinator", "ReplicaSet"),
        ]:
            with self.subTest(account=account, kind=kind):
                obj = workload(account, kind)
                self.assertTrue(self.admission(obj))
                self.assertTrue(self.admission(obj, operation="UPDATE", old=obj))

    def test_workload_escalations_are_denied(self):
        cases = [
            ({"hostNetwork": True}, None),
            ({"hostPID": True}, None),
            ({"hostIPC": True}, None),
            ({"serviceAccountName": "career-ops-reconciler"}, None),
            ({"automountServiceAccountToken": True}, None),
            ({"automountServiceAccountToken": None}, None),
            ({"volumes": [{"name": "bad", "hostPath": {"path": "/"}}]}, None),
            ({"volumes": [{"name": "bad", "csi": {"driver": "unknown"}}]}, None),
            ({"volumes": [{"name": "bad", "secret": {"secretName": "career-ops-source"}}]}, None),
            ({"volumes": [{"name": "bad", "secret": {"secretName": "cv-render-database"}}]}, None),
            (
                {
                    "volumes": [
                        {
                            "name": "bad",
                            "projected": {"sources": [{"serviceAccountToken": {"path": "token"}}]},
                        }
                    ]
                },
                None,
            ),
            ({"initContainers": [{"name": "init", "image": "example.invalid/init"}]}, None),
            ({"ephemeralContainers": [{"name": "debug", "image": "example.invalid/debug"}]}, None),
            ({"securityContext": {"runAsNonRoot": False, "runAsUser": 0}}, None),
            ({}, {"securityContext": {"privileged": True}}),
            ({}, {"securityContext": {"runAsUser": 0}}),
            ({}, {"securityContext": {"readOnlyRootFilesystem": False}}),
            ({}, {"securityContext": {"capabilities": {"drop": ["ALL"], "add": ["NET_ADMIN"]}}}),
            ({}, {"envFrom": [{"secretRef": {"name": "cv-api-auth"}}]}),
        ]
        for fields, container in cases:
            with self.subTest(fields=fields, container=container):
                obj = workload()
                pod = obj["spec"]["template"]["spec"]
                pod.update(fields)
                if container:
                    pod["containers"][0].update(container)
                self.assertFalse(self.admission(obj))
        obj = workload()
        obj["spec"]["template"]["spec"]["containers"].append(
            copy.deepcopy(obj["spec"]["template"]["spec"]["containers"][0])
        )
        self.assertFalse(self.admission(obj))
        obj = workload()
        obj["spec"]["template"]["metadata"]["labels"]["app.kubernetes.io/name"] = "cv-coordinator"
        self.assertFalse(self.admission(obj))
        obj = workload()
        obj["kind"] = "StatefulSet"
        self.assertFalse(self.admission(obj))
        obj = workload(kind="Pod")
        obj["spec"]["ephemeralContainers"] = [{"name": "debug"}]
        self.assertFalse(
            self.admission(
                obj, operation="UPDATE", old=workload(kind="Pod"), sub="ephemeralcontainers"
            )
        )

    def test_coordinator_job_authority_includes_old_object_on_delete(self):
        for operation in ["CREATE", "UPDATE", "DELETE"]:
            for account, expected in [
                ("cv-renderer", True),
                ("cv-prepare", False),
                ("cv-coordinator", False),
            ]:
                obj = workload(account)
                with self.subTest(operation=operation, account=account):
                    self.assertEqual(
                        self.admission(
                            None if operation == "DELETE" else obj,
                            username=COORDINATOR,
                            operation=operation,
                            old=obj,
                        ),
                        expected,
                    )

    def test_platform_names_are_protected_on_create_update_delete(self):
        for kind in ["ServiceAccount", "ConfigMap", "Service", "RoleBinding"]:
            for operation in ["CREATE", "UPDATE", "DELETE"]:
                obj = {
                    "kind": kind,
                    "metadata": {"name": "career-ops-reconciler", "namespace": "career-ops"},
                }
                with self.subTest(kind=kind, operation=operation):
                    self.assertFalse(
                        self.admission(
                            None if operation == "DELETE" else obj,
                            policy="career-ops-resources",
                            operation=operation,
                            old=obj,
                        )
                    )
        old = {
            "kind": "ConfigMap",
            "metadata": {"name": "career-ops-settings", "namespace": "career-ops"},
        }
        obj = copy.deepcopy(old)
        obj["metadata"]["name"] = "application-settings"
        self.assertFalse(
            self.admission(obj, policy="career-ops-resources", operation="UPDATE", old=old)
        )

    def test_only_fixed_runtime_binding_is_admitted(self):
        obj = {
            "kind": "RoleBinding",
            "metadata": {"name": "cv-coordinator-jobs", "namespace": "career-ops"},
            "roleRef": {
                "apiGroup": "rbac.authorization.k8s.io",
                "kind": "Role",
                "name": "cv-render-jobs",
            },
            "subjects": [
                {"kind": "ServiceAccount", "name": "cv-coordinator", "namespace": "career-ops"}
            ],
        }
        self.assertTrue(self.admission(obj, policy="career-ops-resources"))
        for field, value in [
            (
                "subjects",
                [{"kind": "ServiceAccount", "name": "cv-prepare", "namespace": "career-ops"}],
            ),
            (
                "roleRef",
                {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "admin"},
            ),
        ]:
            bad = copy.deepcopy(obj)
            bad[field] = value
            self.assertFalse(self.admission(bad, policy="career-ops-resources"))


class ApplicationNetworkTests(ApplicationAuthorityTests):
    def test_network_capabilities_follow_service_account_identity(self):
        policies = {
            d["metadata"]["name"]: d["spec"]
            for d in self.documents
            if d["kind"] == "CiliumNetworkPolicy"
        }
        self.assertIn("career-ops-deny", list(policies))
        self.assertEqual(policies["career-ops-deny"]["endpointSelector"], {})
        self.assertEqual(policies["career-ops-deny"]["ingress"], [])
        self.assertEqual(policies["career-ops-deny"]["egress"], [])
        self.assertEqual(set(policies), {"career-ops-deny", "career-ops-coordinator"})
        coordinator = policies["career-ops-coordinator"]
        self.assertEqual(
            coordinator["endpointSelector"]["matchLabels"],
            {"k8s:io.cilium.k8s.policy.serviceaccount": "cv-coordinator"},
        )
        self.assertEqual(
            [p["port"] for r in coordinator["ingress"] for p in r["toPorts"][0]["ports"]],
            ["8080", "9090"],
        )
        self.assertEqual(len(coordinator["egress"]), 3)
        self.assertEqual(coordinator["egress"][2]["toEntities"], ["kube-apiserver"])
        self.assertEqual(
            coordinator["egress"][1]["toPorts"][0]["ports"], [{"port": "5432", "protocol": "TCP"}]
        )
        db = next(
            iter(
                yaml.safe_load_all(
                    (
                        ROOT
                        / "kubernetes/apps/automation-data/postgresql/app/ciliumnetworkpolicy.yaml"
                    ).read_text()
                )
            )
        )
        peers = db["spec"]["ingress"][0]["fromEndpoints"]
        self.assertIn(
            {
                "matchLabels": {
                    "k8s:io.kubernetes.pod.namespace": "career-ops",
                    "k8s:io.cilium.k8s.policy.serviceaccount": "cv-coordinator",
                }
            },
            peers,
        )

    def test_route_allocation_and_escape_rejection(self):
        route = {
            "kind": "HTTPRoute",
            "metadata": {"name": "cv-coordinator", "namespace": "career-ops"},
            "spec": {
                "hostnames": ["cv.lab.supermorphic.com"],
                "parentRefs": [
                    {
                        "name": "internal",
                        "namespace": "networking",
                        "sectionName": "https",
                        "kind": "Gateway",
                        "group": "gateway.networking.k8s.io",
                    }
                ],
                "rules": [
                    {
                        "backendRefs": [
                            {
                                "name": "cv-coordinator",
                                "port": 8080,
                                "kind": "Service",
                                "group": "",
                                "weight": 1,
                            }
                        ]
                    }
                ],
            },
        }
        self.assertTrue(self.admission(route, policy="career-ops-routes"))
        mutations = [
            ("hostnames", ["elsewhere.example"]),
            ("parentRefs", [{"name": "external", "namespace": "networking"}]),
            (
                "rules",
                [
                    {
                        "backendRefs": [
                            {"name": "cv-coordinator", "namespace": "other", "port": 8080}
                        ]
                    }
                ],
            ),
            ("rules", [{"backendRefs": [{"name": "other", "port": 8080}]}]),
            ("rules", [{"backendRefs": [{"name": "cv-coordinator", "port": 9090}]}]),
            (
                "rules",
                [
                    {
                        "filters": [{"type": "RequestRedirect"}],
                        "backendRefs": [{"name": "cv-coordinator", "port": 8080}],
                    }
                ],
            ),
        ]
        for field, value in mutations:
            bad = copy.deepcopy(route)
            bad["spec"][field] = value
            self.assertFalse(self.admission(bad, policy="career-ops-routes"))

    def test_service_cannot_redirect_route_metrics_or_external_endpoints(self):
        service = {
            "kind": "Service",
            "metadata": {
                "name": "cv-coordinator",
                "namespace": "career-ops",
                "labels": {"app.kubernetes.io/name": "cv-coordinator"},
            },
            "spec": {
                "type": "ClusterIP",
                "selector": {"app.kubernetes.io/name": "cv-coordinator"},
                "ports": [
                    {"name": "http", "port": 8080, "targetPort": 8080, "protocol": "TCP"},
                    {"name": "metrics", "port": 9090, "targetPort": 9090, "protocol": "TCP"},
                ],
            },
        }
        self.assertTrue(self.admission(service, policy="career-ops-services"))
        for field, value in [
            ("type", "ExternalName"),
            ("type", "LoadBalancer"),
            ("type", "NodePort"),
            ("selector", {"app.kubernetes.io/name": "cv-prepare"}),
            ("externalIPs", ["192.0.2.1"]),
            ("ports", [{"name": "http", "port": 8080, "targetPort": 9090}]),
        ]:
            bad = copy.deepcopy(service)
            bad["spec"][field] = value
            self.assertFalse(self.admission(bad, policy="career-ops-services"))
        endpoints = {
            "kind": "EndpointSlice",
            "metadata": {"name": "redirect", "namespace": "career-ops"},
        }
        self.assertFalse(self.admission(endpoints, policy="career-ops-resources"))


if __name__ == "__main__":
    unittest.main()
