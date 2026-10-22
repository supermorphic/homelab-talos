"""Rendered application authority and independent admission request cases."""

import copy
import json
import subprocess
import tempfile
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
    def test_fixture_storage_waits_for_its_admission_policy(self):
        units = {d["metadata"]["name"]: d for d in render(ROOT / "kubernetes/apps/applications")}
        platform = units["career-ops-platform"]
        # Flux dry-runs a whole unit before applying any of its policy updates.
        self.assertFalse(any(d["kind"] == "PersistentVolumeClaim" for d in render(PLATFORM)))
        fixture = units["career-ops-fixture-storage"]
        self.assertIn({"name": platform["metadata"]["name"]}, fixture["spec"]["dependsOn"])
        self.assertTrue(platform["spec"]["wait"])
        self.assertFalse(fixture["spec"]["prune"])
        self.assertEqual(fixture["spec"]["deletionPolicy"], "Orphan")
        claims = render(ROOT / fixture["spec"]["path"])
        self.assertEqual(len(claims), 3)
        self.assertTrue(all(d["kind"] == "PersistentVolumeClaim" for d in claims))
        self.assertEqual(
            {d["metadata"]["name"] for d in claims},
            {"career-ops-boundary-" + name for name in ["releases", "requests", "artifacts"]},
        )

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

    def test_reviewed_bootstrap_connection_is_enabled(self):
        units = {d["metadata"]["name"]: d for d in render(ROOT / "kubernetes/apps")}
        self.assertIn("career-ops-connection", list(units))
        self.assertIs(units["career-ops-connection"]["spec"]["suspend"], False)

    def test_source_secret_decryption_stays_with_platform(self):
        units = {d["metadata"]["name"]: d for d in render(ROOT / "kubernetes/apps")}
        connection = units["career-ops-connection"]["spec"]
        self.assertEqual(
            connection.get("decryption"),
            {"provider": "sops", "secretRef": {"name": "sops-age"}},
        )
        application = next(
            d for d in render(PLATFORM.parent / "connection") if d["kind"] == "Kustomization"
        )
        self.assertNotIn("decryption", application["spec"])
        self.assertFalse(application["spec"]["suspend"])

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


def renderer_deployment():
    """The sandboxed renderer service shape from spec 035."""
    obj = workload("cv-renderer", "Deployment")
    obj["metadata"]["name"] = "cv-renderer"
    pod = obj["spec"]["template"]["spec"]
    pod["volumes"] = [
        {"name": "code", "configMap": {"name": "cv-renderer-code"}},
        {"name": "fonts", "configMap": {"name": "cv-font-liberation-serif-regular"}},
        {"name": "tmp", "emptyDir": {"sizeLimit": "1Gi"}},
    ]
    pod["containers"][0]["volumeMounts"] = [
        {"name": "code", "mountPath": "/app", "readOnly": True},
        {"name": "fonts", "mountPath": "/fonts/regular", "readOnly": True},
        {"name": "tmp", "mountPath": "/tmp"},
    ]
    pod["containers"][0]["ports"] = [{"name": "http", "containerPort": 8080}]
    return obj


def renderer_service():
    return {
        "kind": "Service",
        "metadata": {
            "name": "cv-renderer",
            "namespace": "career-ops",
            "labels": {"app.kubernetes.io/name": "cv-renderer"},
        },
        "spec": {
            "type": "ClusterIP",
            "selector": {"app.kubernetes.io/name": "cv-renderer"},
            "ports": [{"name": "http", "port": 8080, "targetPort": 8080, "protocol": "TCP"}],
        },
    }


class ApplicationFixture:
    @classmethod
    def setUpClass(cls):
        cls.documents = render(PLATFORM)
        cls.env = celpy.Environment()
        cls.programs = {}
        cls.temporary = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.native = str(Path(cls.temporary.name) / "admission")
        subprocess.run(
            ["go", "build", "-mod=readonly", "-o", cls.native, "."],
            cwd=ROOT / "scripts/test/cel",
            check=True,
        )

    from scripts.test.core.test_test_access_manifests import TestAccessPolicyTests as _helpers

    policy = _helpers.policy

    def evaluate(self, expression, activation):
        if not any(
            extension in expression for extension in ("quantity(", "isQuantity(", "substring(")
        ):
            return self._helpers.evaluate(self, expression, activation)
        result = subprocess.run(
            [self.native, "--evaluate"],
            input=json.dumps(
                {"expression": expression, "activation": json.loads(json.dumps(activation))}
            ),
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

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


class ApplicationAuthorityTests(ApplicationFixture, unittest.TestCase):
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
        # Flux health checks read Deployment ReplicaSets; the reconciler cannot change them.
        self.assertEqual(
            {v for g, r, v in allowed if (g, r) == ("apps", "replicasets")}, {"get", "list", "watch"}
        )
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
        bindings = [
            d
            for d in self.documents
            if d["kind"] == "RoleBinding" and d["metadata"]["name"] == "career-ops-reconciler"
        ]
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

    def test_coordinator_may_explicitly_disable_or_enable_its_token(self):
        for kind in ["Job", "Pod", "Deployment", "ReplicaSet"]:
            for token in [False, True]:
                with self.subTest(kind=kind, token=token):
                    obj = workload("cv-coordinator", kind)
                    pod = obj["spec"] if kind == "Pod" else obj["spec"]["template"]["spec"]
                    pod["automountServiceAccountToken"] = token
                    pod["volumes"] = [
                        {"name": "database", "secret": {"secretName": "cv-render-database"}}
                    ]
                    pod["containers"][0]["volumeMounts"] = [
                        {
                            "name": "database",
                            "mountPath": "/run/secrets/cv-render-database",
                            "readOnly": True,
                        }
                    ]
                    self.assertTrue(self.admission(obj))
                    self.assertTrue(self.admission(obj, operation="UPDATE", old=obj))

    def test_other_runtime_accounts_cannot_enable_tokens(self):
        for account in [
            "cv-prepare",
            "cv-renderer",
            "career-ops-service",
            "career-ops-boundary-coordinator",
            "career-ops-boundary-renderer",
        ]:
            for kind in ["Job", "Pod"]:
                with self.subTest(account=account, kind=kind):
                    obj = workload(account, kind)
                    pod = obj["spec"] if kind == "Pod" else obj["spec"]["template"]["spec"]
                    pod["automountServiceAccountToken"] = True
                    self.assertFalse(self.admission(obj))

    def test_workloads_must_explicitly_select_token_mounting(self):
        for account in ["cv-coordinator", "cv-renderer", "cv-prepare", "career-ops-service"]:
            for kind in ["Job", "Pod"]:
                for omitted in [False, True]:
                    with self.subTest(account=account, kind=kind, omitted=omitted):
                        obj = workload(account, kind)
                        pod = obj["spec"] if kind == "Pod" else obj["spec"]["template"]["spec"]
                        if omitted:
                            del pod["automountServiceAccountToken"]
                        else:
                            pod["automountServiceAccountToken"] = None
                        self.assertFalse(self.admission(obj))

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

    def test_scheduled_pod_update_preserves_node_assignment(self):
        old = workload(kind="Pod")
        old["spec"]["nodeName"] = "synthetic-node"
        obj = copy.deepcopy(old)
        obj["spec"]["containers"][0]["resources"]["limits"]["cpu"] = "500m"
        self.assertTrue(self.admission(obj, operation="UPDATE", old=old, sub="resize"))
        obj["spec"]["nodeName"] = "another-node"
        self.assertFalse(self.admission(obj, operation="UPDATE", old=old))
        self.assertFalse(self.admission(old))

    def test_termination_metadata_cannot_read_secret_files(self):
        for field, value in [
            ("terminationMessagePath", "/run/secrets/cv-render-database/password"),
            ("terminationMessagePolicy", "FallbackToLogsOnError"),
        ]:
            obj = workload("cv-coordinator", "Deployment")
            obj["spec"]["template"]["spec"]["containers"][0][field] = value
            self.assertFalse(self.admission(obj))

    def test_runtime_identity_cannot_change_during_update(self):
        old = workload("career-ops-service", "Deployment")
        new = workload("cv-coordinator", "Deployment")
        self.assertFalse(self.admission(new, operation="UPDATE", old=old))

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


class ApplicationNetworkTests(ApplicationFixture, unittest.TestCase):
    def test_namespace_policy_enables_both_directions_without_allowing_peers(self):
        policy = next(
            d["spec"]
            for d in self.documents
            if d["kind"] == "CiliumNetworkPolicy" and d["metadata"]["name"] == "career-ops-deny"
        )
        # Cilium's none entity never exists, but makes both rule sections valid.
        self.assertEqual(policy.get("enableDefaultDeny"), {"ingress": True, "egress": True})
        self.assertEqual(policy.get("ingress"), [{"fromEntities": ["none"]}])
        self.assertEqual(policy.get("egress"), [{"toEntities": ["none"]}])

    def test_preparation_network_has_only_reviewed_dns_and_https_destinations(self):
        policy = next(
            d["spec"]
            for d in self.documents
            if d["kind"] == "CiliumNetworkPolicy"
            and d["metadata"]["name"] == "career-ops-preparation"
        )
        self.assertEqual(set(policy), {"endpointSelector", "egress"})
        self.assertEqual(
            policy["endpointSelector"],
            {"matchLabels": {"k8s:io.cilium.k8s.policy.serviceaccount": "cv-prepare"}},
        )
        dns, https = policy["egress"]
        hosts = {
            "corefonts.sourceforge.net",
            "deb.debian.org",
            "downloads.sourceforge.net",
            "files.pythonhosted.org",
            "forgejo.infra.supermorphic.com",
            "packages.typst.org",
            "psychz.dl.sourceforge.net",
        }
        self.assertEqual(set(dns), {"toEndpoints", "toPorts"})
        self.assertEqual(
            dns["toEndpoints"],
            [
                {
                    "matchLabels": {
                        "k8s:io.kubernetes.pod.namespace": "kube-system",
                        "k8s:k8s-app": "kube-dns",
                    }
                }
            ],
        )
        self.assertEqual(
            dns["toPorts"],
            [
                {
                    "ports": [
                        {"port": "53", "protocol": "TCP"},
                        {"port": "53", "protocol": "UDP"},
                    ],
                    "rules": {"dns": [{"matchName": h} for h in sorted(hosts)]},
                }
            ],
        )
        self.assertEqual(
            https,
            {
                "toFQDNs": [{"matchName": h} for h in sorted(hosts)],
                "toPorts": [{"ports": [{"port": "443", "protocol": "TCP"}]}],
            },
        )

    def test_network_capabilities_follow_service_account_identity(self):
        policies = {
            d["metadata"]["name"]: d["spec"]
            for d in self.documents
            if d["kind"] == "CiliumNetworkPolicy"
        }
        self.assertIn("career-ops-deny", list(policies))
        self.assertEqual(policies["career-ops-deny"]["endpointSelector"], {})
        self.assertEqual(
            set(policies),
            {
                "career-ops-deny",
                "career-ops-coordinator",
                "career-ops-boundary-coordinator",
                "career-ops-preparation",
            },
        )
        coordinator = policies["career-ops-coordinator"]
        native = policies["career-ops-boundary-coordinator"]
        self.assertEqual(native["egress"], coordinator["egress"])
        self.assertEqual(native["ingress"], [])
        self.assertEqual(
            native["endpointSelector"]["matchLabels"],
            {"k8s:io.cilium.k8s.policy.serviceaccount": "career-ops-boundary-coordinator"},
        )
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


class ApplicationStorageTests(ApplicationFixture, unittest.TestCase):
    def test_retention_storage_and_capacity(self):
        storage = next((d for d in self.documents if d["kind"] == "StorageClass"), None)
        self.assertIsNotNone(storage, "retaining storage class is missing")
        self.assertEqual(storage["metadata"]["name"], "career-ops-retain")
        self.assertEqual(storage["reclaimPolicy"], "Retain")
        self.assertEqual(storage["provisioner"], "driver.longhorn.io")
        self.assertEqual(storage["parameters"]["numberOfReplicas"], "2")
        self.assertEqual(
            json.loads(storage["parameters"]["recurringJobSelector"]),
            [{"name": "default", "isGroup": True}],
        )
        self.assertIs(storage["allowVolumeExpansion"], True)
        self.assertNotEqual(
            storage["metadata"]
            .get("annotations", {})
            .get("storageclass.kubernetes.io/is-default-class"),
            "true",
        )
        quota = next(d["spec"]["hard"] for d in self.documents if d["kind"] == "ResourceQuota")
        self.assertEqual(
            quota,
            {
                "requests.cpu": "6",
                "limits.cpu": "16",
                "requests.memory": "12Gi",
                "limits.memory": "24Gi",
                "requests.ephemeral-storage": "16Gi",
                "limits.ephemeral-storage": "32Gi",
                "pods": "16",
                "count/jobs.batch": "64",
                "count/deployments.apps": "4",
                "services": "8",
                "count/httproutes.gateway.networking.k8s.io": "4",
                "configmaps": "64",
                "count/serviceaccounts": "16",
                "count/rolebindings.rbac.authorization.k8s.io": "16",
                "persistentvolumeclaims": "10",
                "requests.storage": "64Gi",
            },
        )

    def test_enrolled_pvc_declarations_and_retention_denials(self):
        for name, size in [
            ("cv-releases", "8Gi"),
            ("cv-requests", "16Gi"),
            ("cv-artifacts", "32Gi"),
        ]:
            obj = {
                "kind": "PersistentVolumeClaim",
                "metadata": {
                    "name": name,
                    "namespace": "career-ops",
                    "annotations": {"kustomize.toolkit.fluxcd.io/prune": "disabled"},
                },
                "spec": {
                    "accessModes": ["ReadWriteMany"],
                    "storageClassName": "career-ops-retain",
                    "resources": {"requests": {"storage": size}},
                    "volumeMode": "Filesystem",
                },
            }
            self.assertTrue(self.admission(obj, policy="career-ops-storage"))
            self.assertFalse(
                self.admission(None, policy="career-ops-resources", operation="DELETE", old=obj)
            )
            cases = [
                ("storageClassName", "longhorn"),
                ("accessModes", ["ReadWriteOnce"]),
                ("volumeName", "arbitrary-pv"),
                ("dataSource", {"kind": "PersistentVolumeClaim", "name": "private"}),
                ("resources", {"requests": {"storage": "64Gi"}}),
                ("volumeMode", "Block"),
                ("selector", {"matchLabels": {"private": "true"}}),
            ]
            for field, value in cases:
                bad = copy.deepcopy(obj)
                bad["spec"][field] = value
                self.assertFalse(self.admission(bad, policy="career-ops-storage"))
            bad = copy.deepcopy(obj)
            bad["metadata"]["annotations"] = {}
            self.assertFalse(
                self.admission(bad, policy="career-ops-storage", operation="UPDATE", old=obj)
            )
            bad = copy.deepcopy(obj)
            bad["metadata"]["ownerReferences"] = [
                {"kind": "Job", "name": "fixture", "uid": "synthetic"}
            ]
            self.assertFalse(self.admission(bad, policy="career-ops-storage"))

    def test_profile_mounts_and_alternate_mount_rejections(self):
        for account, claim, readonly, path, sub in [
            ("cv-prepare", "cv-releases", False, "/releases", "candidates/release-fixture"),
            ("cv-renderer", "cv-releases", True, "/releases", "published/release-fixture"),
            ("cv-renderer", "cv-requests", True, "/input", "requests/request-fixture/input"),
            (
                "cv-renderer",
                "cv-requests",
                False,
                "/staging",
                "requests/request-fixture/attempts/attempt-fixture/pods/pod-fixture",
            ),
            ("cv-coordinator", "cv-artifacts", False, "/artifacts", ""),
            ("cv-coordinator", "cv-requests", False, "/requests", ""),
        ]:
            obj = workload(account)
            pod = obj["spec"]["template"]["spec"]
            pod["volumes"] = [
                {
                    "name": "data",
                    "persistentVolumeClaim": {"claimName": claim, "readOnly": readonly},
                }
            ]
            mount = {"name": "data", "mountPath": path, "readOnly": readonly}
            if sub:
                mount["subPath"] = sub
            pod["containers"][0]["volumeMounts"] = [mount]
            self.assertTrue(self.admission(obj), (account, claim, path))
            if readonly:
                bad = copy.deepcopy(obj)
                bad["spec"]["template"]["spec"]["containers"][0]["volumeMounts"][0]["readOnly"] = (
                    False
                )
                self.assertFalse(self.admission(bad))
            bad = copy.deepcopy(obj)
            bad["spec"]["template"]["spec"]["containers"][0]["volumeMounts"][0]["subPathExpr"] = (
                "$(PRIVATE_PATH)"
            )
            self.assertFalse(self.admission(bad))
            if account != "cv-coordinator":
                bad = copy.deepcopy(obj)
                bad["spec"]["template"]["spec"]["volumes"][0]["persistentVolumeClaim"][
                    "claimName"
                ] = "cv-artifacts"
                self.assertFalse(self.admission(bad))
        obj = workload("cv-prepare")
        obj["spec"]["template"]["spec"]["volumes"] = [
            {"name": "data", "persistentVolumeClaim": {"claimName": "cv-requests"}}
        ]
        self.assertFalse(self.admission(obj))

    def test_pvc_attribute_classes_and_protection_removal_are_denied(self):
        obj = {
            "kind": "PersistentVolumeClaim",
            "metadata": {
                "name": "cv-releases",
                "namespace": "career-ops",
                "annotations": {"kustomize.toolkit.fluxcd.io/prune": "disabled"},
                "finalizers": ["kubernetes.io/pvc-protection"],
            },
            "spec": {
                "storageClassName": "career-ops-retain",
                "accessModes": ["ReadWriteMany"],
                "resources": {"requests": {"storage": "8Gi"}},
            },
        }
        bad = copy.deepcopy(obj)
        bad["spec"]["volumeAttributesClassName"] = "alternate-driver-options"
        self.assertFalse(self.admission(bad, policy="career-ops-storage"))
        bad = copy.deepcopy(obj)
        bad["metadata"]["finalizers"] = []
        self.assertFalse(
            self.admission(bad, policy="career-ops-storage", operation="UPDATE", old=obj)
        )

    def test_bound_pvc_updates_and_pod_resize_are_guarded(self):
        obj = {
            "kind": "PersistentVolumeClaim",
            "metadata": {
                "name": "cv-releases",
                "namespace": "career-ops",
                "annotations": {"kustomize.toolkit.fluxcd.io/prune": "disabled"},
            },
            "spec": {
                "accessModes": ["ReadWriteMany"],
                "storageClassName": "career-ops-retain",
                "resources": {"requests": {"storage": "8Gi"}},
                "volumeName": "fixture-bound-pv",
            },
        }
        self.assertTrue(
            self.admission(obj, policy="career-ops-storage", operation="UPDATE", old=obj)
        )
        bad = copy.deepcopy(obj)
        bad["spec"]["volumeName"] = "another-pv"
        self.assertFalse(
            self.admission(bad, policy="career-ops-storage", operation="UPDATE", old=obj)
        )
        rules = self.policy("career-ops-workloads")["matchConstraints"]["resourceRules"]
        self.assertIn("pods/resize", [r for rule in rules for r in rule["resources"]])
        obj = workload(kind="Pod")
        obj["spec"]["containers"][0]["resources"]["limits"]["cpu"] = "2"
        self.assertFalse(
            self.admission(obj, operation="UPDATE", old=workload(kind="Pod"), sub="resize")
        )

    def test_coordinator_promotion_and_read_only_candidate_qualification(self):
        for account, sub in [
            ("cv-coordinator", None),
            ("cv-renderer", "candidates/release-fixture"),
        ]:
            obj = workload(account)
            pod = obj["spec"]["template"]["spec"]
            pod["volumes"] = [
                {
                    "name": "release",
                    "persistentVolumeClaim": {
                        "claimName": "cv-releases",
                        "readOnly": account != "cv-coordinator",
                    },
                }
            ]
            mount = {
                "name": "release",
                "mountPath": "/releases",
                "readOnly": account != "cv-coordinator",
            }
            if sub:
                mount["subPath"] = sub
            pod["containers"][0]["volumeMounts"] = [mount]
            self.assertTrue(self.admission(obj), account)
        obj = workload("cv-prepare")
        pod = obj["spec"]["template"]["spec"]
        pod["volumes"] = [
            {"name": "release", "persistentVolumeClaim": {"claimName": "cv-releases"}}
        ]
        pod["containers"][0]["volumeMounts"] = [
            {"name": "release", "mountPath": "/releases", "subPath": "published/release-fixture"}
        ]
        self.assertFalse(self.admission(obj))

    def test_secret_files_are_read_only_at_the_enrolled_path(self):
        for account, secret in [
            ("cv-coordinator", "cv-render-database"),
            ("cv-coordinator", "application-packages-database"),
            ("cv-coordinator", "cv-api-auth"),
            ("cv-prepare", "cv-prepare-source"),
        ]:
            obj = workload(account)
            pod = obj["spec"]["template"]["spec"]
            pod["volumes"] = [{"name": "credential", "secret": {"secretName": secret}}]
            mount = {"name": "credential", "mountPath": "/run/secrets/" + secret, "readOnly": True}
            pod["containers"][0]["volumeMounts"] = [mount]
            self.assertTrue(self.admission(obj), secret)
            for field, value in [
                ("readOnly", False),
                ("mountPath", "/tmp/credential"),
                ("subPath", "password"),
            ]:
                bad = copy.deepcopy(obj)
                bad["spec"]["template"]["spec"]["containers"][0]["volumeMounts"][0][field] = value
                self.assertFalse(self.admission(bad))

    def test_secret_environment_and_partial_directory_delivery_are_denied(self):
        for account, secret in [
            ("cv-coordinator", "cv-render-database"),
            ("cv-coordinator", "application-packages-database"),
            ("cv-coordinator", "cv-api-auth"),
            ("cv-prepare", "cv-prepare-source"),
        ]:
            obj = workload(account)
            pod = obj["spec"]["template"]["spec"]
            pod["containers"][0]["env"] = [
                {
                    "name": "CREDENTIAL",
                    "valueFrom": {"secretKeyRef": {"name": secret, "key": "password"}},
                }
            ]
            with self.subTest(account=account, delivery="environment"):
                self.assertFalse(self.admission(obj))
            pod["containers"][0].pop("env")
            pod["volumes"] = [
                {
                    "name": "credential",
                    "secret": {
                        "secretName": secret,
                        "items": [{"key": "password", "path": "renamed"}],
                    },
                }
            ]
            pod["containers"][0]["volumeMounts"] = [
                {"name": "credential", "mountPath": "/run/secrets/" + secret, "readOnly": True}
            ]
            with self.subTest(account=account, delivery="partial-directory"):
                self.assertFalse(self.admission(obj))

    def test_per_profile_resources_and_temporary_workspace(self):
        for account, cpu, memory, ephemeral in [
            ("cv-renderer", "1001m", "1025Mi", "2049Mi"),
            ("cv-coordinator", "1001m", "2049Mi", "2049Mi"),
            ("cv-prepare", "2001m", "4097Mi", "4097Mi"),
        ]:
            for resource, over in [
                ("cpu", cpu),
                ("memory", memory),
                ("ephemeral-storage", ephemeral),
            ]:
                obj = workload(account)
                obj["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"][
                    resource
                ] = over
                self.assertFalse(self.admission(obj), (account, resource))
        for resources in [
            {},
            {"limits": {"cpu": "1", "memory": "1Gi"}},
            {
                "requests": {"cpu": "2", "memory": "128Mi", "ephemeral-storage": "128Mi"},
                "limits": {"cpu": "1", "memory": "1Gi", "ephemeral-storage": "2Gi"},
            },
        ]:
            obj = workload()
            obj["spec"]["template"]["spec"]["containers"][0]["resources"] = resources
            self.assertFalse(self.admission(obj))
        obj = workload()
        pod = obj["spec"]["template"]["spec"]
        pod["volumes"] = [{"name": "tmp", "emptyDir": {"sizeLimit": "1Gi"}}]
        pod["containers"][0]["volumeMounts"] = [{"name": "tmp", "mountPath": "/tmp"}]
        self.assertTrue(self.admission(obj))
        pod["volumes"][0]["emptyDir"]["sizeLimit"] = "1025Mi"
        self.assertFalse(self.admission(obj))

    def test_workload_templates_reject_requests_below_namespace_minimums(self):
        for kind in ("Job", "Deployment", "ReplicaSet", "Pod"):
            for resource, value in (
                ("cpu", "9m"),
                ("memory", "31Mi"),
                ("ephemeral-storage", "63Mi"),
            ):
                obj = workload(kind=kind)
                pod = obj["spec"] if kind == "Pod" else obj["spec"]["template"]["spec"]
                pod["containers"][0]["resources"]["requests"][resource] = value
                with self.subTest(kind=kind, resource=resource):
                    self.assertFalse(self.admission(obj))

    def test_workload_templates_accept_exact_namespace_minimums(self):
        limits = next(d for d in self.documents if d["kind"] == "LimitRange")
        minimum = next(
            item["min"] for item in limits["spec"]["limits"] if item["type"] == "Container"
        )
        for kind in ("Job", "Deployment", "ReplicaSet", "Pod"):
            obj = workload(kind=kind)
            pod = obj["spec"] if kind == "Pod" else obj["spec"]["template"]["spec"]
            pod["containers"][0]["resources"]["requests"] = copy.deepcopy(minimum)
            self.assertTrue(self.admission(obj), kind)


class ApplicationAssuranceTests(ApplicationFixture, unittest.TestCase):
    def test_test_runner_can_only_submit_fixed_server_dry_runs(self):
        policies = render(ROOT / "kubernetes/apps/kube-system/agent-access/app")
        generic = next(
            d
            for d in policies
            if d["kind"] == "ValidatingAdmissionPolicy"
            and d["metadata"]["name"] == "homelab-test-jobs"
        )
        self.assertIn(
            "request.namespace != 'career-ops'",
            [c["expression"] for c in generic["spec"]["matchConditions"]],
        )
        roles = [
            d
            for d in self.documents
            if d["kind"] == "Role" and d["metadata"]["name"] == "career-ops-boundary-test"
        ]
        self.assertEqual(len(roles), 1)
        self.assertEqual(
            roles[0]["rules"],
            [
                {"apiGroups": ["batch"], "resources": ["jobs"], "verbs": ["create"]},
                {
                    "apiGroups": ["batch"],
                    "resources": ["jobs"],
                    "resourceNames": [
                        "career-ops-boundary-" + phase
                        for phase in [
                            "seed",
                            "write",
                            "read",
                            "cleanup",
                            *[
                                "network-" + stage + "-" + target
                                for stage in ["write", "read"]
                                for target in ["api", "database", "dns-tcp", "dns-udp"]
                            ],
                        ]
                    ],
                    "verbs": ["get", "delete"],
                },
            ],
        )
        readers = [
            d
            for d in self.documents
            if d["kind"] == "ClusterRole"
            and d["metadata"]["name"] == "career-ops-boundary-observer"
        ]
        self.assertEqual(len(readers), 1)
        self.assertEqual(readers[0]["rules"][0]["verbs"], ["get"])
        self.assertEqual(
            set(readers[0]["rules"][0]["resourceNames"]),
            {
                "career-ops-workloads",
                "career-ops-resources",
                "career-ops-services",
                "career-ops-routes",
                "career-ops-storage",
                "career-ops-boundary-test",
                "career-ops-boundary-fixtures",
            },
        )
        obj = workload()
        obj["metadata"]["name"] = "career-ops-boundary-admission"
        req = {
            "namespace": "career-ops",
            "operation": "CREATE",
            "dryRun": True,
            "userInfo": {"username": "system:serviceaccount:kube-system:homelab-test-runner"},
        }
        self.assertTrue(self.admits("career-ops-boundary-test", req, obj))
        for field, value in [("dryRun", False), ("operation", "UPDATE"), ("operation", "DELETE")]:
            bad = dict(req)
            bad[field] = value
            self.assertFalse(self.admits("career-ops-boundary-test", bad, obj, old=obj))
        bad = copy.deepcopy(obj)
        bad["metadata"]["name"] = "another-job"
        self.assertFalse(self.admits("career-ops-boundary-test", req, bad))


class ApplicationConnectionTests(unittest.TestCase):
    def test_reviewed_private_source_and_application_reconciliation_are_enabled(self):
        docs = render(ROOT / "kubernetes/apps/applications/career-ops/connection")
        self.assertEqual(len(docs), 7)
        self.assertEqual(
            {(d["kind"], d["metadata"]["namespace"], d["metadata"]["name"]) for d in docs},
            {
                ("GitRepository", "career-ops", "career-ops"),
                ("Kustomization", "career-ops", "career-ops-apps"),
                ("Secret", "career-ops", "career-ops-source"),
                ("Secret", "career-ops", "cv-render-database"),
                ("Secret", "career-ops", "application-packages-database"),
                ("Secret", "career-ops", "cv-prepare-source"),
                ("Secret", "career-ops", "cv-api-auth"),
            },
        )
        credential = next(d for d in docs if d["metadata"]["name"] == "career-ops-source")
        self.assertEqual(credential["type"], "Opaque")
        self.assertEqual(set(credential["stringData"]), {"username", "password"})
        self.assertTrue(
            all(value.startswith("ENC[AES256_GCM,") for value in credential["stringData"].values())
        )
        self.assertEqual(credential["sops"]["encrypted_regex"], "^(data|stringData)$")
        source = next(d for d in docs if d["kind"] == "GitRepository")
        self.assertEqual(source["metadata"], {"name": "career-ops", "namespace": "career-ops"})
        self.assertEqual(
            source["spec"]["url"],
            "https://forgejo.infra.supermorphic.com/supermorphic/career-ops.git",
        )
        self.assertEqual(source["spec"]["ref"], {"branch": "main"})
        self.assertEqual(source["spec"]["secretRef"], {"name": "career-ops-source"})
        self.assertIs(source["spec"]["suspend"], False)
        application = next(d for d in docs if d["kind"] == "Kustomization")
        self.assertEqual(application["metadata"]["name"], "career-ops-apps")
        self.assertEqual(application["spec"]["serviceAccountName"], "career-ops-reconciler")
        self.assertEqual(
            application["spec"]["sourceRef"], {"kind": "GitRepository", "name": "career-ops"}
        )
        self.assertEqual(application["spec"]["path"], "./deploy/")
        self.assertEqual(application["spec"]["targetNamespace"], "career-ops")
        self.assertIs(application["spec"]["suspend"], False)
        for field in ["decryption", "postBuild", "patches", "components", "kubeConfig"]:
            self.assertNotIn(field, application["spec"])

    def test_runtime_database_secrets_are_selected_by_the_platform_connection(self):
        docs = render(ROOT / "kubernetes/apps/applications/career-ops/connection")
        for name in ("cv-render-database", "application-packages-database"):
            with self.subTest(secret=name):
                self.assert_database_secret(next((d for d in docs if d["metadata"]["name"] == name), None))

    def assert_database_secret(self, credential):
        self.assertIsNotNone(credential)
        self.assertEqual(credential["kind"], "Secret")
        self.assertEqual(credential["metadata"]["namespace"], "career-ops")
        self.assertEqual(credential["type"], "Opaque")
        self.assertEqual(set(credential["stringData"]), {"username", "password", "binding.json"})
        self.assertTrue(
            all(value.startswith("ENC[AES256_GCM,") for value in credential["stringData"].values())
        )
        self.assertEqual(credential["sops"]["encrypted_regex"], "^(data|stringData)$")


class RendererServiceTests(ApplicationFixture, unittest.TestCase):
    def test_renderer_service_admitted(self):
        self.assertTrue(self.admission(renderer_service(), policy="career-ops-services"))

    def test_renderer_service_shape_denied(self):
        cases = {
            "second port": lambda s: s["spec"]["ports"].append(
                {"name": "metrics", "port": 9090, "targetPort": 9090, "protocol": "TCP"}
            ),
            "metrics port": lambda s: s["spec"].update(
                ports=[{"name": "http", "port": 9090, "targetPort": 9090, "protocol": "TCP"}]
            ),
            "node port": lambda s: s["spec"].update(type="NodePort"),
            "coordinator selector": lambda s: s["spec"].update(
                selector={"app.kubernetes.io/name": "cv-coordinator"}
            ),
            "coordinator label": lambda s: s["metadata"]["labels"].update(
                {"app.kubernetes.io/name": "cv-coordinator"}
            ),
            "renamed port": lambda s: s["spec"]["ports"][0].update(name="web"),
        }
        for name, mutate in cases.items():
            with self.subTest(name):
                bad = renderer_service()
                mutate(bad)
                self.assertFalse(self.admission(bad, policy="career-ops-services"))

    def test_renderer_selector_not_reachable_from_other_service_names(self):
        bad = renderer_service()
        bad["metadata"]["name"] = "career-ops-service"
        bad["metadata"]["labels"] = {"app.kubernetes.io/name": "career-ops-service"}
        self.assertFalse(self.admission(bad, policy="career-ops-services"))

    def test_renderer_deployment_admitted(self):
        deployment = renderer_deployment()
        for kind in ("Deployment", "ReplicaSet", "Pod"):
            with self.subTest(kind=kind):
                obj = copy.deepcopy(deployment)
                if kind == "Pod":
                    template = obj["spec"]["template"]
                    obj = {"kind": "Pod", "metadata": obj["metadata"], "spec": template["spec"]}
                    obj["spec"]["restartPolicy"] = "Always"
                obj["kind"] = kind
                self.assertTrue(self.admission(obj))

    def test_renderer_claims_only_in_jobs(self):
        def with_claim(obj):
            spec = obj["spec"] if obj["kind"] == "Pod" else obj["spec"]["template"]["spec"]
            spec.setdefault("volumes", []).append(
                {"name": "requests", "persistentVolumeClaim": {"claimName": "cv-requests", "readOnly": True}}
            )
            spec["containers"][0].setdefault("volumeMounts", []).append(
                {"name": "requests", "mountPath": "/input", "subPath": "requests/r1/input", "readOnly": True}
            )
            return obj

        self.assertTrue(self.admission(with_claim(workload("cv-renderer", "Job"))))
        job_pod = with_claim(workload("cv-renderer", "Pod"))
        job_pod["metadata"]["ownerReferences"] = [{"kind": "Job", "name": "fixture", "apiVersion": "batch/v1", "uid": "u"}]
        self.assertTrue(self.admission(job_pod))
        for kind in ("Deployment", "ReplicaSet", "Pod"):
            with self.subTest(kind=kind):
                self.assertFalse(self.admission(with_claim(workload("cv-renderer", kind))))

    def test_renderer_deployment_escalations_denied(self):
        def pod(obj):
            return obj["spec"]["template"]["spec"]

        def add_volume(volume, mount):
            def mutate(obj):
                pod(obj)["volumes"].append(volume)
                pod(obj)["containers"][0]["volumeMounts"].append(mount)

            return mutate

        cases = {
            "artifact claim": add_volume(
                {"name": "a", "persistentVolumeClaim": {"claimName": "cv-artifacts"}},
                {"name": "a", "mountPath": "/artifacts"},
            ),
            "api secret": add_volume(
                {"name": "s", "secret": {"secretName": "cv-api-auth"}},
                {"name": "s", "mountPath": "/run/secrets/cv-api-auth", "readOnly": True},
            ),
            "token": lambda o: pod(o).update(automountServiceAccountToken=True),
            "projected token": add_volume(
                {
                    "name": "kube-api-access-x",
                    "projected": {"sources": [{"serviceAccountToken": {"path": "token"}}]},
                },
                {"name": "kube-api-access-x", "mountPath": "/var/run/secrets/token"},
            ),
            "pull secret": lambda o: pod(o).update(imagePullSecrets=[{"name": "registry"}]),
            "init container": lambda o: pod(o).update(
                initContainers=[copy.deepcopy(pod(o)["containers"][0])]
            ),
            "large workspace": lambda o: pod(o)["volumes"][2]["emptyDir"].update(sizeLimit="2Gi"),
            "cpu limit": lambda o: pod(o)["containers"][0]["resources"]["limits"].update(cpu="2"),
            "platform configmap": lambda o: pod(o)["volumes"][0]["configMap"].update(
                name="career-ops-boundary-program"
            ),
        }
        for name, mutate in cases.items():
            with self.subTest(name):
                bad = renderer_deployment()
                mutate(bad)
                self.assertFalse(self.admission(bad))


class ApplicationMonitoringTests(unittest.TestCase):
    def test_platform_monitoring_is_quiet_until_activation(self):
        docs = render(PLATFORM)
        monitor = next((d for d in docs if d["kind"] == "ServiceMonitor"), None)
        self.assertIsNotNone(monitor, "platform monitoring is missing")
        self.assertEqual(
            monitor["spec"]["selector"],
            {"matchLabels": {"app.kubernetes.io/name": "cv-coordinator"}},
        )
        self.assertEqual(monitor["spec"]["namespaceSelector"], {"matchNames": ["career-ops"]})
        self.assertEqual(
            [
                {k: v for k, v in e.items() if k != "metricRelabelings"}
                for e in monitor["spec"]["endpoints"]
            ],
            [{"port": "metrics", "path": "/metrics", "interval": "1m", "scrapeTimeout": "10s"}],
        )
        rule = next(d for d in docs if d["kind"] == "PrometheusRule")
        expected = next(r for g in rule["spec"]["groups"] for r in g["rules"] if "record" in r)
        self.assertEqual(
            expected, {"record": "career_ops_coordinator_expected", "expr": "vector(0)"}
        )


if __name__ == "__main__":
    unittest.main()
