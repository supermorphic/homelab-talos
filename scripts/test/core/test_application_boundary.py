"""Rendered application authority and independent admission request cases."""

import copy
import json
import re
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


SERVICE_ACCOUNTS = ["cv-coordinator", "cv-renderer", "career-ops-service"]
RETIRED_ACCOUNTS = [
    "cv-prepare",
    "career-ops-boundary-coordinator",
    "career-ops-boundary-renderer",
]


def workload(account="career-ops-service", kind="Job"):
    pod = {
        "serviceAccountName": account,
        "automountServiceAccountToken": False,
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


def pod_spec(obj):
    return obj["spec"] if obj["kind"] == "Pod" else obj["spec"]["template"]["spec"]


def job_pod(account):
    """A Pod created by a Job controller for the given account."""
    obj = workload(account, "Pod")
    obj["metadata"]["ownerReferences"] = [
        {"apiVersion": "batch/v1", "kind": "Job", "name": "fixture", "uid": "u", "controller": True}
    ]
    return obj


def with_artifacts(obj, claim_read_only=True, mount_read_only=True, **mount):
    """Mount the artifact claim the way the coordinator is enrolled to, with overrides."""
    pod = pod_spec(obj)
    claim = {"claimName": "cv-artifacts"}
    if claim_read_only is not None:
        claim["readOnly"] = claim_read_only
    pod.setdefault("volumes", []).append({"name": "artifacts", "persistentVolumeClaim": claim})
    entry = {"name": "artifacts", "mountPath": "/artifacts"}
    if mount_read_only is not None:
        entry["readOnly"] = mount_read_only
    entry.update(mount)
    pod["containers"][0].setdefault("volumeMounts", []).append(entry)
    return obj


def with_secret(obj, secret):
    pod = pod_spec(obj)
    pod.setdefault("volumes", []).append({"name": "credential", "secret": {"secretName": secret}})
    pod["containers"][0].setdefault("volumeMounts", []).append(
        {"name": "credential", "mountPath": "/run/secrets/" + secret, "readOnly": True}
    )
    return obj


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
            "roles",
            "rolebindings",
            "*",
        ]:
            self.assertFalse(any(r == forbidden for g, r, v in allowed), forbidden)
        self.assertFalse(
            any(v in ["impersonate", "escalate", "bind", "*"] for g, r, v in allowed)
        )
        self.assertFalse(any(g == "rbac.authorization.k8s.io" for g, r, v in allowed))
        # Flux health checks read Deployment ReplicaSets; the reconciler cannot change them.
        self.assertEqual(
            {v for g, r, v in allowed if (g, r) == ("apps", "replicasets")}, {"get", "list", "watch"}
        )
        # No runtime account receives Kubernetes API authority.
        self.assertNotIn("cv-render-jobs", roles)
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
            ("career-ops-service", "Job"),
            ("career-ops-service", "Deployment"),
            ("cv-coordinator", "Deployment"),
            ("cv-coordinator", "ReplicaSet"),
            ("cv-coordinator", "Pod"),
            ("cv-renderer", "Deployment"),
            ("cv-renderer", "ReplicaSet"),
            ("cv-renderer", "Pod"),
        ]:
            with self.subTest(account=account, kind=kind):
                obj = workload(account, kind)
                self.assertTrue(self.admission(obj))
                self.assertTrue(self.admission(obj, operation="UPDATE", old=obj))

    def test_only_the_service_accounts_are_enrolled(self):
        for account in [*RETIRED_ACCOUNTS, "default", "career-ops-reconciler"]:
            for kind in ["Job", "Deployment", "ReplicaSet", "Pod"]:
                with self.subTest(account=account, kind=kind):
                    self.assertFalse(self.admission(workload(account, kind)))

    def test_coordinator_and_renderer_cannot_run_as_jobs(self):
        for account in ["cv-coordinator", "cv-renderer"]:
            with self.subTest(account=account, kind="Job"):
                self.assertFalse(self.admission(workload(account, "Job")))
            with self.subTest(account=account, kind="Job Pod"):
                self.assertFalse(self.admission(job_pod(account)))
        # The reserved service keeps its one-shot Job profile and Job-owned Pods.
        self.assertTrue(self.admission(workload("career-ops-service", "Job")))
        self.assertTrue(self.admission(job_pod("career-ops-service")))
        retrying = workload("career-ops-service", "Job")
        retrying["spec"]["backoffLimit"] = 1
        self.assertFalse(self.admission(retrying))

    def test_no_account_may_mount_a_kubernetes_token(self):
        for account in SERVICE_ACCOUNTS:
            for kind in ["Deployment", "ReplicaSet", "Pod"]:
                with self.subTest(account=account, kind=kind):
                    obj = workload(account, kind)
                    pod_spec(obj)["automountServiceAccountToken"] = True
                    self.assertFalse(self.admission(obj))
                    self.assertFalse(
                        self.admission(obj, operation="UPDATE", old=workload(account, kind))
                    )
        # An explicit API-token projection is no longer an allowance for anyone.
        for account in SERVICE_ACCOUNTS:
            with self.subTest(account=account, projection="kube-api-access"):
                obj = workload(account, "Pod")
                pod = pod_spec(obj)
                pod["volumes"] = [
                    {
                        "name": "kube-api-access-fixture",
                        "projected": {
                            "sources": [
                                {"serviceAccountToken": {"path": "token"}},
                                {"configMap": {"name": "kube-root-ca.crt"}},
                            ]
                        },
                    }
                ]
                pod["containers"][0]["volumeMounts"] = [
                    {
                        "name": "kube-api-access-fixture",
                        "mountPath": "/var/run/secrets/kubernetes.io/serviceaccount",
                        "readOnly": True,
                    }
                ]
                self.assertFalse(self.admission(obj))

    def test_workloads_must_explicitly_select_token_mounting(self):
        for account in SERVICE_ACCOUNTS:
            for kind in ["Deployment", "Pod"]:
                for omitted in [False, True]:
                    with self.subTest(account=account, kind=kind, omitted=omitted):
                        obj = workload(account, kind)
                        pod = pod_spec(obj)
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
            ("terminationMessagePath", "/run/secrets/application-packages-database/password"),
            ("terminationMessagePolicy", "FallbackToLogsOnError"),
        ]:
            obj = workload("cv-coordinator", "Deployment")
            obj["spec"]["template"]["spec"]["containers"][0][field] = value
            self.assertFalse(self.admission(obj))

    def test_runtime_identity_cannot_change_during_update(self):
        old = workload("career-ops-service", "Deployment")
        new = workload("cv-coordinator", "Deployment")
        self.assertFalse(self.admission(new, operation="UPDATE", old=old))

    def test_coordinator_identity_has_no_workload_mutation_authority(self):
        # Kubernetes RBAC gives the coordinator nothing; its username is not an
        # admission allowance for retired worker Jobs either.
        for operation in ["CREATE", "UPDATE"]:
            with self.subTest(operation=operation):
                obj = workload("cv-renderer", "Job")
                self.assertFalse(
                    self.admission(obj, username=COORDINATOR, operation=operation, old=obj)
                )

    def test_platform_names_are_protected_on_create_update_delete(self):
        for kind in ["ServiceAccount", "ConfigMap", "Service"]:
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

    def test_application_cannot_manage_role_bindings(self):
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
        for operation in ["CREATE", "UPDATE", "DELETE"]:
            with self.subTest(operation=operation):
                self.assertFalse(
                    self.admission(
                        None if operation == "DELETE" else obj,
                        policy="career-ops-resources",
                        operation=operation,
                        old=obj,
                    )
                )

    def test_only_tokenless_service_accounts_are_admitted(self):
        def account(name):
            return {
                "kind": "ServiceAccount",
                "metadata": {"name": name, "namespace": "career-ops"},
                "automountServiceAccountToken": False,
            }

        for name in SERVICE_ACCOUNTS:
            with self.subTest(name=name):
                self.assertTrue(self.admission(account(name), policy="career-ops-resources"))
                bad = account(name)
                bad["automountServiceAccountToken"] = True
                self.assertFalse(self.admission(bad, policy="career-ops-resources"))
        for name in [*RETIRED_ACCOUNTS, "cv-worker"]:
            with self.subTest(name=name):
                self.assertFalse(self.admission(account(name), policy="career-ops-resources"))


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
                "career-ops-renderer",
            },
        )
        coordinator = policies["career-ops-coordinator"]
        native = policies["career-ops-boundary-coordinator"]
        # The fixture proves the shared DNS, database and API destinations; only the
        # production coordinator may call the renderer.
        self.assertEqual(native["egress"], coordinator["egress"][:3])
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
        self.assertEqual(len(coordinator["egress"]), 4)
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

    def test_coordinator_mounts_only_the_read_only_artifact_claim(self):
        for kind in ["Deployment", "ReplicaSet", "Pod"]:
            with self.subTest(kind=kind):
                self.assertTrue(self.admission(with_artifacts(workload("cv-coordinator", kind))))
        cases = {
            "writable claim": dict(claim_read_only=False),
            "claim access unset": dict(claim_read_only=None),
            "writable mount": dict(mount_read_only=False),
            "mount access unset": dict(mount_read_only=None),
            "subPath": dict(subPath="private"),
            "dynamic subPath": dict(subPathExpr="$(PRIVATE_PATH)"),
            "other path": dict(mountPath="/releases"),
        }
        for name, change in cases.items():
            with self.subTest(name):
                self.assertFalse(
                    self.admission(with_artifacts(workload("cv-coordinator", "Deployment"), **change))
                )
        for claim in ["cv-releases", "cv-requests", "career-ops-boundary-artifacts"]:
            with self.subTest(claim=claim):
                obj = with_artifacts(workload("cv-coordinator", "Deployment"))
                pod_spec(obj)["volumes"][0]["persistentVolumeClaim"]["claimName"] = claim
                self.assertFalse(self.admission(obj))

    def test_only_the_coordinator_may_mount_a_claim(self):
        for account in ["cv-renderer", "career-ops-service"]:
            for kind in ["Job", "Deployment", "ReplicaSet", "Pod"]:
                if account == "cv-renderer" and kind == "Job":
                    continue
                with self.subTest(account=account, kind=kind):
                    self.assertTrue(self.admission(workload(account, kind)))
                    self.assertFalse(self.admission(with_artifacts(workload(account, kind))))
        self.assertFalse(self.admission(with_artifacts(job_pod("cv-renderer"))))

    def test_secret_files_are_read_only_at_the_enrolled_path(self):
        for secret in ["application-packages-database", "cv-api-auth"]:
            obj = with_secret(workload("cv-coordinator", "Deployment"), secret)
            self.assertTrue(self.admission(obj), secret)
            for field, value in [
                ("readOnly", False),
                ("mountPath", "/tmp/credential"),
                ("subPath", "password"),
            ]:
                bad = copy.deepcopy(obj)
                bad["spec"]["template"]["spec"]["containers"][0]["volumeMounts"][0][field] = value
                self.assertFalse(self.admission(bad))

    def test_retired_and_unassigned_secrets_are_denied(self):
        for account in SERVICE_ACCOUNTS:
            for secret in [
                "cv-render-database",
                "cv-prepare-source",
                "application-packages-database",
                "cv-api-auth",
            ]:
                if account == "cv-coordinator" and secret in [
                    "application-packages-database",
                    "cv-api-auth",
                ]:
                    continue
                with self.subTest(account=account, secret=secret):
                    self.assertFalse(
                        self.admission(with_secret(workload(account, "Deployment"), secret))
                    )

    def test_secret_environment_and_partial_directory_delivery_are_denied(self):
        for secret in ["application-packages-database", "cv-api-auth"]:
            obj = workload("cv-coordinator", "Deployment")
            pod = obj["spec"]["template"]["spec"]
            pod["containers"][0]["env"] = [
                {
                    "name": "CREDENTIAL",
                    "valueFrom": {"secretKeyRef": {"name": secret, "key": "password"}},
                }
            ]
            with self.subTest(secret=secret, delivery="environment"):
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
            with self.subTest(secret=secret, delivery="partial-directory"):
                self.assertFalse(self.admission(obj))

    def test_per_profile_resources_and_temporary_workspace(self):
        for account, kind, cpu, memory, ephemeral in [
            ("cv-renderer", "Deployment", "1001m", "1025Mi", "2049Mi"),
            ("career-ops-service", "Job", "1001m", "1025Mi", "2049Mi"),
            ("cv-coordinator", "Deployment", "1001m", "2049Mi", "2049Mi"),
        ]:
            for resource, over in [
                ("cpu", cpu),
                ("memory", memory),
                ("ephemeral-storage", ephemeral),
            ]:
                obj = workload(account, kind)
                obj["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"][
                    resource
                ] = over
                self.assertFalse(self.admission(obj), (account, resource))
        coordinator = workload("cv-coordinator", "Deployment")
        coordinator["spec"]["template"]["spec"]["containers"][0]["resources"]["limits"].update(
            {"cpu": "1", "memory": "2Gi", "ephemeral-storage": "2Gi"}
        )
        self.assertTrue(self.admission(coordinator))
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
            "no labels": lambda s: s["metadata"].pop("labels"),
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

    def test_renderer_has_no_claims_or_worker_jobs(self):
        def with_claim(obj):
            spec = pod_spec(obj)
            spec.setdefault("volumes", []).append(
                {"name": "requests", "persistentVolumeClaim": {"claimName": "cv-requests", "readOnly": True}}
            )
            spec["containers"][0].setdefault("volumeMounts", []).append(
                {"name": "requests", "mountPath": "/input", "subPath": "requests/r1/input", "readOnly": True}
            )
            return obj

        for kind in ("Job", "Deployment", "ReplicaSet", "Pod"):
            with self.subTest(kind=kind):
                self.assertFalse(self.admission(with_claim(workload("cv-renderer", kind))))
        self.assertFalse(self.admission(with_claim(job_pod("cv-renderer"))))
        self.assertFalse(self.admission(job_pod("cv-renderer")))

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


class RendererNetworkTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.policies = [d for d in render(PLATFORM) if d["kind"] == "CiliumNetworkPolicy"]

    @staticmethod
    def selects(policy, account):
        # Conservative: a policy not pinned to another service account may select it.
        labels = policy["spec"]["endpointSelector"].get("matchLabels", {})
        pinned = {
            value for key, value in labels.items()
            if key.split(":", 1)[-1] == "io.cilium.k8s.policy.serviceaccount"
        }
        return pinned <= {account}

    def test_renderer_ingress_only_from_coordinator(self):
        renderer = [
            p for p in self.policies
            if p["spec"]["endpointSelector"].get("matchLabels")
            == {"k8s:io.cilium.k8s.policy.serviceaccount": "cv-renderer"}
        ]
        self.assertEqual(len(renderer), 1)
        spec = renderer[0]["spec"]
        self.assertNotIn("egress", spec)
        self.assertEqual(
            spec["ingress"],
            [
                {
                    "fromEndpoints": [
                        {
                            "matchLabels": {
                                "k8s:io.cilium.k8s.policy.serviceaccount": "cv-coordinator",
                                "k8s:io.kubernetes.pod.namespace": "career-ops",
                            }
                        }
                    ],
                    "toPorts": [{"ports": [{"port": "8080", "protocol": "TCP"}]}],
                }
            ],
        )

    def test_no_policy_grants_renderer_egress(self):
        for policy in self.policies:
            if self.selects(policy, "cv-renderer"):
                with self.subTest(policy["metadata"]["name"]):
                    egress = policy["spec"].get("egress", [])
                    self.assertTrue(
                        all(rule == {"toEntities": ["none"]} for rule in egress), egress
                    )

    def test_gateway_access_log_excludes_private_hosts(self):
        proxy = yaml.safe_load(
            (ROOT / "kubernetes/apps/networking/internal-gateway/app/envoyproxy.yaml").read_text()
        )
        expressions = [
            e for setting in proxy["spec"]["telemetry"]["accessLog"]["settings"]
            for e in setting.get("matches", [])
        ]
        self.assertEqual(len(expressions), 1)
        env = celpy.Environment()
        program = env.program(env.compile(expressions[0]))

        def logged(host):
            return bool(program.evaluate({"request": celpy.json_to_cel({"host": host})}))

        for host in (
            "cv.lab.supermorphic.com",
            "CV.LAB.SUPERMORPHIC.COM",
            "cv.lab.supermorphic.com.",
            "cv.lab.supermorphic.com:443",
            "searxng.lab.supermorphic.com",
        ):
            with self.subTest(excluded=host):
                self.assertFalse(logged(host))
        for host in (
            "evilcv.lab.supermorphic.com",
            "cv.lab.supermorphic.com.example",
            "n8n.lab.supermorphic.com",
        ):
            with self.subTest(logged=host):
                self.assertTrue(logged(host))

    def test_coordinator_egress_to_renderer(self):
        coordinator = next(
            p for p in self.policies if p["metadata"]["name"] == "career-ops-coordinator"
        )
        self.assertIn(
            {
                "toEndpoints": [
                    {
                        "matchLabels": {
                            "k8s:io.cilium.k8s.policy.serviceaccount": "cv-renderer",
                            "k8s:io.kubernetes.pod.namespace": "career-ops",
                        }
                    }
                ],
                "toPorts": [{"ports": [{"port": "8080", "protocol": "TCP"}]}],
            },
            coordinator["spec"]["egress"],
        )


class ApplicationMonitoringTests(unittest.TestCase):
    def test_platform_monitoring_is_armed(self):
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
        rules = [r for g in rule["spec"]["groups"] for r in g["rules"]]
        keep = monitor["spec"]["endpoints"][0]["metricRelabelings"][0]
        self.assertEqual((keep["action"], keep["sourceLabels"]), ("keep", ["__name__"]))
        used = {name for r in rules for name in re.findall(r"\bcv_render_\w+", r["expr"])}
        self.assertTrue(used)
        for name in sorted(used):
            with self.subTest(kept=name):
                self.assertRegex(name, f"^(?:{keep['regex']})$")
        self.assertEqual(
            [r["alert"] for r in rules if "alert" in r],
            ["CareerOpsCVServiceDown", "CareerOpsCVWorkStuck", "CareerOpsCVRendersFailing"],
        )
        for alert in (r for r in rules if "alert" in r):
            self.assertTrue(
                alert["expr"].endswith("and on() (career_ops_coordinator_expected == 1)"),
                alert["alert"],
            )
        expected = next(r for r in rules if "record" in r)
        self.assertEqual(
            expected, {"record": "career_ops_coordinator_expected", "expr": "vector(1)"}
        )


if __name__ == "__main__":
    unittest.main()
