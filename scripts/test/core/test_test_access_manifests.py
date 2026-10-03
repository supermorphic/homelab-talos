"""Independent request fixtures exercise the CEL shipped to Kubernetes."""

import copy
import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import celpy
import yaml
from celpy.adapter import json_to_cel

ROOT = Path(__file__).resolve().parents[3]
PACKAGE = ROOT / "kubernetes/apps/kube-system/agent-access/app"
IDENTITY = "system:serviceaccount:kube-system:homelab-test-runner"


class TestAccessPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.documents = []
        for package in (PACKAGE, ROOT / "kubernetes/apps/monitoring/test-reports/app"):
            rendered = subprocess.run(
                ["kustomize", "build", str(package)], capture_output=True, text=True, check=True
            )
            cls.documents.extend(yaml.safe_load_all(rendered.stdout))
        cls.env = celpy.Environment()
        cls.programs = {}

    def policy(self, name):
        found = [
            d
            for d in self.documents
            if d["kind"] == "ValidatingAdmissionPolicy" and d["metadata"]["name"] == name
        ]
        self.assertEqual(len(found), 1, f"missing enforced admission policy {name}")
        policy = found[0]
        self.assertEqual(policy["spec"]["failurePolicy"], "Fail")
        bindings = [
            d
            for d in self.documents
            if d["kind"] == "ValidatingAdmissionPolicyBinding" and d["spec"]["policyName"] == name
        ]
        self.assertEqual(len(bindings), 1)
        self.assertEqual(bindings[0]["spec"]["validationActions"], ["Deny"])
        return policy["spec"]

    def evaluate(self, expression, activation):
        if expression not in self.programs:
            self.programs[expression] = self.env.program(self.env.compile(expression))
        return self.programs[expression].evaluate(activation)

    def admits(self, policy_name, request, obj, old=None, params=None):
        spec = self.policy(policy_name)
        activation = {
            "request": json_to_cel(request),
            "object": json_to_cel(obj),
            "oldObject": json_to_cel(old),
            "params": json_to_cel(params),
            "variables": json_to_cel({}),
        }
        try:
            for condition in spec.get("matchConditions", []):
                if not self.evaluate(condition["expression"], activation):
                    return True
            variables = {}
            for variable in spec.get("variables", []):
                variables[variable["name"]] = self.evaluate(variable["expression"], activation)
                activation["variables"] = celpy.celtypes.MapType(variables)
            return all(
                bool(self.evaluate(v["expression"], activation)) for v in spec["validations"]
            )
        except celpy.CELEvalError:
            return False

    def test_restore_host_mapping_uses_the_actual_scratch_service_parameter(self):
        for family, prefix, namespace, role, app_suffix, policy in (
            (
                "automation-data-restore-drill",
                "ad",
                "automation",
                "ad-database",
                "n8n",
                "homelab-test-ad-restore-hosts",
            ),
            (
                "nocodb-restore-drill",
                "nc",
                "automation-data",
                "database",
                "nocodb",
                "homelab-test-nc-restore-hosts",
            ),
        ):
            run = "abc12345def6"
            obj = {
                "metadata": {
                    "name": f"{prefix}-restore-{run}-{app_suffix}",
                    "labels": {"homelab-talos/test": family, "homelab-talos/run-id": run},
                },
                "spec": {
                    "template": {
                        "spec": {
                            "hostAliases": [
                                {
                                    "ip": "192.0.2.45",
                                    "hostnames": [
                                        "automation-data-postgresql",
                                        "automation-data-postgresql.automation-data.svc.cluster.local",
                                    ],
                                }
                            ]
                        }
                    }
                },
            }
            service = {
                "metadata": {
                    "name": f"{prefix}-restore-{run}-db",
                    "namespace": "automation-data",
                    "uid": "synthetic-service",
                    "labels": {
                        "homelab-talos/test": family,
                        "homelab-talos/run-id": run,
                        "homelab-talos/role": role,
                    },
                },
                "spec": {"type": "ClusterIP", "clusterIP": "192.0.2.45"},
            }
            req = self.request("deployments", namespace, name=obj["metadata"]["name"])
            self.assertTrue(self.admits(policy, req, obj, params=service))
            self.assertFalse(self.admits(policy, req, obj))
            for change in (
                "ip",
                "hostname",
                "extra-alias",
                "run",
                "service-run",
                "service-role",
                "service-namespace",
                "service-name",
                "headless",
                "service-type",
                "namespace",
            ):
                bad, param, request = (
                    copy.deepcopy(obj),
                    copy.deepcopy(service),
                    copy.deepcopy(req),
                )
                if change == "ip":
                    bad["spec"]["template"]["spec"]["hostAliases"][0]["ip"] = "192.0.2.99"
                elif change == "hostname":
                    bad["spec"]["template"]["spec"]["hostAliases"][0]["hostnames"][0] = (
                        "production"
                    )
                elif change == "extra-alias":
                    bad["spec"]["template"]["spec"]["hostAliases"].append(
                        {"ip": "192.0.2.99", "hostnames": ["other"]}
                    )
                elif change == "run":
                    bad["metadata"]["labels"]["homelab-talos/run-id"] = "other"
                elif change == "service-run":
                    param["metadata"]["labels"]["homelab-talos/run-id"] = "other"
                elif change == "service-role":
                    param["metadata"]["labels"]["homelab-talos/role"] = "n8n"
                elif change == "service-namespace":
                    param["metadata"]["namespace"] = "automation"
                elif change == "service-name":
                    param["metadata"]["name"] = "production"
                elif change == "headless":
                    param["spec"]["clusterIP"] = "None"
                elif change == "service-type":
                    param["spec"]["type"] = "ExternalName"
                elif change == "namespace":
                    request["namespace"] = "media"
                with self.subTest(family=family, change=change):
                    self.assertFalse(self.admits(policy, request, bad, params=param))
            definition = self.policy(policy)
            self.assertEqual(definition["paramKind"], {"apiVersion": "v1", "kind": "Service"})
            self.assertEqual(
                definition["matchConstraints"]["resourceRules"][0]["operations"],
                ["CREATE", "UPDATE"],
            )
            binding = next(
                d["spec"]
                for d in self.documents
                if d["kind"] == "ValidatingAdmissionPolicyBinding"
                and d["spec"]["policyName"] == policy
            )
            self.assertEqual(
                binding["paramRef"],
                {
                    "namespace": "automation-data",
                    "parameterNotFoundAction": "Deny",
                    "selector": {
                        "matchLabels": {"homelab-talos/test": family, "homelab-talos/role": role}
                    },
                },
            )
            # Param collection precedes username matchConditions in Kubernetes 1.35.
            # Limit lookup to mandatory family labels, keeping unrelated production writes out.
            self.assertEqual(
                binding["matchResources"]["objectSelector"],
                {"matchLabels": {"homelab-talos/test": family}},
            )

    @staticmethod
    def request(resource, namespace, operation="CREATE", name="fixture", user=IDENTITY):
        return {
            "resource": {"group": "", "version": "v1", "resource": resource},
            "subResource": "",
            "namespace": namespace,
            "name": name,
            "operation": operation,
            "userInfo": {"username": user},
        }

    def admits_jobs(self, request, obj, old=None):
        return all(
            self.admits(name, request, obj, old)
            for name in (
                "homelab-test-jobs",
                "homelab-test-n8n-restore-jobs",
                "homelab-test-n8n-persistence-jobs",
                "homelab-test-n8n-request-jobs",
                "homelab-test-qbit-manage-jobs",
                "homelab-test-workload-security",
            )
        )

    @staticmethod
    def render_restore_backends():
        def function(source, name):
            start = source.index(name + "() {")
            return source[start : source.index("\n}\n", start) + 3]

        ad = (ROOT / "scripts/test/scenarios/automation-data-restore-drill.sh").read_text()
        nc = (ROOT / "scripts/test/scenarios/nocodb-restore-drill.sh").read_text()
        library = (ROOT / "scripts/test/lib/nocodb-restore-command.sh").read_text()
        programs = (
            "run_hash=0123456789ab\nprefix=ad-restore-$run_hash\n"
            "ad_database=$prefix-db\nad_service=$ad_database\nad_data_pvc=$prefix-ad-data\n"
            "n8n_database=$prefix-n8n-db\nn8n_service=$n8n_database\n"
            "n8n_data_pvc=$prefix-n8n-data\nn8n_app=$prefix-n8n\n"
            + function(ad, "platform_manifests")
            + function(ad, "n8n_application_manifests")
            + "platform_manifests\nn8n_application_manifests 192.0.2.45\n",
            "run_hash=0123456789ab\nprefix=nc-restore-$run_hash\n"
            "database=$prefix-db\ndatabase_service=$database\ndatabase_pvc=$prefix-db-data\n"
            + function(nc, "database_manifests")
            + function(library, "nocodb_restore_application_manifests")
            + "database_manifests\n"
            'nocodb_restore_application_manifests "$prefix-nocodb" "$prefix-nocodb" 192.0.2.45 "$run_hash"\n',
        )
        documents = []
        for program in programs:
            rendered = subprocess.run(
                ["bash", "-c", "set -euo pipefail\n" + program],
                capture_output=True,
                text=True,
                check=True,
                cwd=ROOT,
            )
            documents.extend(yaml.safe_load_all(rendered.stdout))
        return documents

    def test_restore_backend_claims_and_services_match_enforced_allocation(self):
        documents = self.render_restore_backends()
        claims = [d for d in documents if d["kind"] == "PersistentVolumeClaim"]
        services = [d for d in documents if d["kind"] == "Service"]
        self.assertEqual(len(claims), 3)
        self.assertEqual(len(services), 5)
        for obj in claims + services:
            metadata = obj["metadata"]
            resource = "services" if obj["kind"] == "Service" else "persistentvolumeclaims"
            policy = "homelab-test-services" if resource == "services" else "homelab-test-storage"
            req = self.request(resource, metadata["namespace"], name=metadata["name"])
            if resource == "services":
                # Kubernetes defaults an omitted ServicePort protocol before admission.
                for port in obj["spec"]["ports"]:
                    port.setdefault("protocol", "TCP")
            with self.subTest(resource=resource, name=metadata["name"]):
                self.assertTrue(self.admits(policy, req, obj))
                self.assertTrue(self.admits(policy, {**req, "operation": "DELETE"}, None, obj))

    def test_restore_allocation_grants_are_namespaced_and_individual(self):
        for namespace in ("automation", "automation-data"):
            roles = [
                d
                for d in self.documents
                if d["kind"] == "Role"
                and d["metadata"]["namespace"] == namespace
                and d["metadata"]["name"] == "homelab-test-restore-storage"
            ]
            self.assertEqual(len(roles), 1)
            self.assertEqual(
                roles[0]["rules"],
                [
                    {
                        "apiGroups": [""],
                        "resources": ["persistentvolumeclaims"],
                        "verbs": ["create", "delete"],
                    }
                ],
            )
        role = next(
            (
                d
                for d in self.documents
                if d["kind"] == "Role"
                and d["metadata"]["namespace"] == "automation-data"
                and d["metadata"]["name"] == "homelab-test-restore-services"
            ),
            None,
        )
        self.assertIsNotNone(role)
        self.assertEqual(
            role["rules"],
            [{"apiGroups": [""], "resources": ["services"], "verbs": ["create", "delete"]}],
        )

    @staticmethod
    def restore_database_fixture(family="automation-data-restore-drill", role="ad-database"):
        run = "0123456789ab"
        prefix = ("nc" if family == "nocodb-restore-drill" else "ad") + "-restore-" + run
        n8n = role == "n8n-database"
        name = prefix + ("-n8n-db" if n8n else "-db")
        claim = prefix + (
            "-n8n-data" if n8n else "-db-data" if family == "nocodb-restore-drill" else "-ad-data"
        )
        labels = {
            "homelab-talos/test": family,
            "homelab-talos/run-id": run,
            "homelab-talos/role": role,
        }
        env = [
            {"name": "PGDATA", "value": "/var/lib/postgresql/data/pgdata"},
            {"name": "POSTGRES_DB", "value": "postgres"},
        ]
        if n8n:
            env.append({"name": "POSTGRES_USER", "value": "n8n"})
        env.append(
            {
                "name": "POSTGRES_PASSWORD",
                "valueFrom": {
                    "secretKeyRef": {
                        "name": "postgresql-credentials",
                        "key": "n8n-password" if n8n else "postgres-superuser-password",
                    }
                },
            }
        )
        return {
            "apiVersion": "apps/v1",
            "kind": "StatefulSet",
            "metadata": {
                "name": name,
                "namespace": "automation" if n8n else "automation-data",
                "labels": labels,
            },
            "spec": {
                "replicas": 1,
                "serviceName": name,
                "selector": {"matchLabels": labels},
                "template": {
                    "metadata": {"labels": labels},
                    "spec": {
                        "automountServiceAccountToken": False,
                        "securityContext": {
                            "fsGroup": 70,
                            "fsGroupChangePolicy": "OnRootMismatch",
                            "seccompProfile": {"type": "RuntimeDefault"},
                        },
                        "containers": [
                            {
                                "name": "postgresql",
                                "image": "postgres:17.11-alpine3.24",
                                "imagePullPolicy": "IfNotPresent",
                                "env": env,
                                "ports": [{"name": "postgresql", "containerPort": 5432}],
                                "readinessProbe": {
                                    "exec": {
                                        "command": [
                                            "pg_isready",
                                            "--username=" + ("n8n" if n8n else "postgres"),
                                            "--dbname=postgres",
                                        ]
                                    },
                                    "periodSeconds": 5,
                                    "failureThreshold": 120
                                    if family == "nocodb-restore-drill"
                                    else 60,
                                },
                                "resources": {
                                    "requests": {"cpu": "50m", "memory": "128Mi"},
                                    "limits": {"memory": "1Gi"},
                                },
                                "securityContext": {
                                    "allowPrivilegeEscalation": False,
                                    "capabilities": {"drop": ["ALL"]},
                                    "readOnlyRootFilesystem": True,
                                    "runAsNonRoot": True,
                                    "runAsUser": 70,
                                    "runAsGroup": 70,
                                },
                                "volumeMounts": [
                                    {"name": "data", "mountPath": "/var/lib/postgresql/data"},
                                    {"name": "run", "mountPath": "/var/run/postgresql"},
                                    {"name": "tmp", "mountPath": "/tmp"},
                                ],
                            }
                        ],
                        "volumes": [
                            {"name": "data", "persistentVolumeClaim": {"claimName": claim}},
                            {"name": "run", "emptyDir": {}},
                            {"name": "tmp", "emptyDir": {}},
                        ],
                    },
                },
            },
        }

    def test_restore_database_controller_grants_are_namespaced(self):
        roles = [
            d
            for d in self.documents
            if d["kind"] == "Role" and d["metadata"]["name"] == "homelab-test-restore-databases"
        ]
        self.assertEqual(
            {d["metadata"]["namespace"] for d in roles}, {"automation", "automation-data"}
        )
        for role in roles:
            self.assertEqual(
                role["rules"],
                [
                    {
                        "apiGroups": ["apps"],
                        "resources": ["statefulsets"],
                        "verbs": ["create", "delete"],
                    }
                ],
            )

    def test_restored_applications_use_fixed_credentials_and_service_bound_hosts(self):
        for obj in self.render_restore_backends():
            if obj["kind"] != "Deployment":
                continue
            family = obj["metadata"]["labels"]["homelab-talos/test"]
            nc = family == "nocodb-restore-drill"
            namespace = "automation-data" if nc else "automation"
            req = self.request("deployments", namespace, name=obj["metadata"]["name"])
            req["resource"]["group"] = "apps"
            service = {
                "metadata": {
                    "name": ("nc" if nc else "ad") + "-restore-0123456789ab-db",
                    "namespace": "automation-data",
                    "uid": "synthetic-service",
                    "labels": {
                        "homelab-talos/test": family,
                        "homelab-talos/run-id": "0123456789ab",
                        "homelab-talos/role": "database" if nc else "ad-database",
                    },
                },
                "spec": {"type": "ClusterIP", "clusterIP": "192.0.2.45"},
            }

            def allowed(candidate, request=req, nc=nc, service=service):
                parent = all(
                    self.admits(policy, request, candidate)
                    for policy in (
                        "homelab-test-workload-security",
                        "homelab-test-n8n-applications",
                        "homelab-test-nocodb-applications",
                    )
                )
                return parent and self.admits(
                    "homelab-test-nc-restore-hosts" if nc else "homelab-test-ad-restore-hosts",
                    request,
                    candidate,
                    params=service,
                )

            self.assertTrue(allowed(obj))
            for change in (
                "namespace",
                "family",
                "role",
                "run",
                "name",
                "labels",
                "selector",
                "image",
                "command",
                "args",
                "env",
                "secret",
                "database",
                "host-ip",
                "hostnames",
                "hostalias",
                "identity",
                "token",
                "volume",
                "sidecar",
                "init",
                "probe",
                "hook",
                "owner",
                "annotation",
                "runtime-class",
                "resource-limit",
            ):
                bad, request = copy.deepcopy(obj), copy.deepcopy(req)
                pod = bad["spec"]["template"]["spec"]
                app = pod["containers"][0]
                if change == "namespace":
                    request["namespace"] = "security"
                elif change in ("family", "role", "run"):
                    bad["metadata"]["labels"][
                        "homelab-talos/"
                        + {"family": "test", "role": "role", "run": "run-id"}[change]
                    ] = "other"
                elif change == "name":
                    bad["metadata"]["name"] = "production"
                elif change == "labels":
                    bad["spec"]["template"]["metadata"]["labels"]["app.kubernetes.io/name"] = "n8n"
                elif change == "selector":
                    bad["spec"]["selector"]["matchLabels"] = {"app.kubernetes.io/name": "n8n"}
                elif change == "image":
                    app["image"] = "busybox:latest"
                elif change == "command":
                    app["command"] = ["sh", "-c", "env"]
                elif change == "args":
                    app["args"] = ["other"]
                elif change == "env":
                    app["env"].append({"name": "NODE_OPTIONS", "value": "--require=/tmp/other.js"})
                elif change == "secret":
                    next(e for e in app["env"] if "valueFrom" in e)["valueFrom"]["secretKeyRef"][
                        "name"
                    ] = "other"
                elif change == "database":
                    if nc:
                        next(e for e in app["env"] if e["name"] == "DATABASE_URL").update(
                            value="synthetic"
                        )
                    else:
                        next(e for e in app["env"] if e["name"] == "DB_POSTGRESDB_HOST")[
                            "value"
                        ] = "n8n-postgresql"
                elif change == "host-ip":
                    pod["hostAliases"][0]["ip"] = "192.0.2.99"
                elif change == "hostnames":
                    pod["hostAliases"][0]["hostnames"] = ["production"]
                elif change == "hostalias":
                    pod["hostAliases"].append({"ip": "192.0.2.99", "hostnames": ["other"]})
                elif change == "identity":
                    pod["serviceAccountName"] = "elevated"
                elif change == "runtime-class":
                    pod["runtimeClassName"] = "other"
                elif change == "resource-limit":
                    app["resources"]["limits"]["memory"] = "20Gi"
                elif change == "token":
                    pod["automountServiceAccountToken"] = True
                elif change == "volume":
                    pod["volumes"][0] = {
                        "name": "data",
                        "persistentVolumeClaim": {"claimName": "production"},
                    }
                elif change == "sidecar":
                    pod["containers"].append(copy.deepcopy(app))
                elif change == "init":
                    pod["initContainers"] = [copy.deepcopy(app)]
                elif change == "probe":
                    app["readinessProbe"] = {"exec": {"command": ["env"]}}
                elif change == "hook":
                    app["lifecycle"] = {"postStart": {"exec": {"command": ["env"]}}}
                elif change == "owner":
                    bad["metadata"]["ownerReferences"] = [{"uid": "synthetic"}]
                else:
                    bad["spec"]["template"]["metadata"]["annotations"] = {
                        "test.example/inject": "true"
                    }
                with self.subTest(family=family, change=change):
                    self.assertFalse(allowed(bad, request))
            for policy in (
                "homelab-test-workload-security",
                "homelab-test-n8n-applications",
                "homelab-test-nocodb-applications",
            ):
                self.assertTrue(self.admits(policy, {**req, "operation": "DELETE"}, None, obj))
                self.assertFalse(
                    self.admits(
                        "homelab-test-nocodb-applications"
                        if nc
                        else "homelab-test-n8n-applications",
                        {**req, "operation": "UPDATE"},
                        obj,
                        obj,
                    )
                )

    def test_nocodb_application_grant_has_only_individual_fixture_actions(self):
        roles = [
            d
            for d in self.documents
            if d["kind"] == "Role" and d["metadata"]["name"] == "homelab-test-restore-applications"
        ]
        self.assertEqual(len(roles), 1)
        self.assertEqual(roles[0]["metadata"]["namespace"], "automation-data")
        self.assertEqual(
            roles[0]["rules"],
            [{"apiGroups": ["apps"], "resources": ["deployments"], "verbs": ["create", "delete"]}],
        )

    def test_restore_database_controllers_cannot_select_other_authority(self):
        for family, role in (
            ("automation-data-restore-drill", "ad-database"),
            ("automation-data-restore-drill", "n8n-database"),
            ("nocodb-restore-drill", "database"),
        ):
            obj = self.restore_database_fixture(family, role)
            req = self.request(
                "statefulsets", obj["metadata"]["namespace"], name=obj["metadata"]["name"]
            )
            req["resource"]["group"] = "apps"
            self.assertTrue(self.admits("homelab-test-restore-databases", req, obj))
            self.assertTrue(
                self.admits(
                    "homelab-test-restore-databases", {**req, "operation": "DELETE"}, None, obj
                )
            )
            self.assertFalse(
                self.admits(
                    "homelab-test-restore-databases", {**req, "operation": "UPDATE"}, obj, obj
                )
            )
            for change in (
                "namespace",
                "name",
                "family",
                "role",
                "labels",
                "selector",
                "sa",
                "token",
                "image",
                "command",
                "args",
                "secret",
                "password",
                "envFrom",
                "extra-env",
                "mount",
                "claim",
                "hostpath",
                "sidecar",
                "init",
                "exec-probe",
                "http-probe",
                "port",
                "host-network",
                "dns",
                "privilege",
                "root",
                "hook",
                "owner",
                "annotation",
                "claim-template",
                "resource-limit",
                "runtime-class",
            ):
                bad, request = copy.deepcopy(obj), copy.deepcopy(req)
                pod = bad["spec"]["template"]["spec"]
                container = pod["containers"][0]
                if change == "namespace":
                    request["namespace"] = "security"
                elif change == "name":
                    bad["metadata"]["name"] = "production"
                elif change in ("family", "role"):
                    bad["metadata"]["labels"][
                        "homelab-talos/" + ("test" if change == "family" else "role")
                    ] = "other"
                elif change == "labels":
                    bad["spec"]["template"]["metadata"]["labels"]["app.kubernetes.io/name"] = (
                        "postgresql"
                    )
                elif change == "selector":
                    bad["spec"]["selector"]["matchLabels"] = {
                        "app.kubernetes.io/name": "postgresql"
                    }
                elif change == "sa":
                    pod["serviceAccountName"] = "elevated"
                elif change == "token":
                    pod["automountServiceAccountToken"] = True
                elif change == "image":
                    container["image"] = "busybox:latest"
                elif change == "command":
                    container["command"] = ["sh", "-c", "env"]
                elif change == "args":
                    container["args"] = ["-c", "config_file=/tmp/other"]
                elif change == "secret":
                    container["env"][-1]["valueFrom"]["secretKeyRef"]["name"] = "other"
                elif change == "password":
                    container["env"][-1] = {"name": "POSTGRES_PASSWORD", "value": "synthetic"}
                elif change == "envFrom":
                    container["envFrom"] = [{"secretRef": {"name": "other"}}]
                elif change == "extra-env":
                    container["env"].append(
                        {"name": "POSTGRES_INITDB_ARGS", "value": "--auth=trust"}
                    )
                elif change == "mount":
                    container["volumeMounts"][0]["mountPath"] = "/other"
                elif change == "claim":
                    pod["volumes"][0]["persistentVolumeClaim"]["claimName"] = "production"
                elif change == "hostpath":
                    pod["volumes"][0] = {"name": "data", "hostPath": {"path": "/"}}
                elif change == "sidecar":
                    pod["containers"].append(copy.deepcopy(container))
                elif change == "init":
                    pod["initContainers"] = [copy.deepcopy(container)]
                elif change == "exec-probe":
                    container["readinessProbe"]["exec"]["command"] = ["sh", "-c", "env"]
                elif change == "http-probe":
                    container["readinessProbe"] = {"httpGet": {"host": "production", "port": 80}}
                elif change == "port":
                    container["ports"][0]["hostPort"] = 5432
                elif change == "host-network":
                    pod["hostNetwork"] = True
                elif change == "resource-limit":
                    container["resources"]["limits"]["memory"] = "20Gi"
                elif change == "runtime-class":
                    pod["runtimeClassName"] = "other"
                elif change == "dns":
                    pod["hostAliases"] = [{"ip": "192.0.2.1", "hostnames": ["production"]}]
                elif change == "privilege":
                    container["securityContext"]["privileged"] = True
                elif change == "root":
                    container["securityContext"]["runAsUser"] = 0
                elif change == "hook":
                    container["lifecycle"] = {"postStart": {"exec": {"command": ["env"]}}}
                elif change == "owner":
                    bad["metadata"]["ownerReferences"] = [{"uid": "synthetic"}]
                elif change == "annotation":
                    bad["spec"]["template"]["metadata"]["annotations"] = {
                        "test.example/inject": "true"
                    }
                else:
                    bad["spec"]["volumeClaimTemplates"] = [{"metadata": {"name": "other"}}]
                with self.subTest(family=family, role=role, change=change):
                    self.assertFalse(self.admits("homelab-test-restore-databases", request, bad))
        for obj in self.render_restore_backends():
            if obj["kind"] != "StatefulSet":
                continue
            req = self.request(
                "statefulsets", obj["metadata"]["namespace"], name=obj["metadata"]["name"]
            )
            self.assertTrue(self.admits("homelab-test-restore-databases", req, obj))

    @staticmethod
    def qbit_fixture(phase="limits", run="abc12345def67890"):
        labels = {
            "homelab-talos/test": "qbit-manage-policy",
            "homelab-talos/run-id": run,
            "homelab-talos/e2e-target": "qbit-manage-policy",
            "homelab-talos/e2e-run": run,
        }
        security = {"allowPrivilegeEscalation": False, "capabilities": {"drop": ["ALL"]}}
        return {
            "metadata": {"name": f"qbm-e2e-{run}-{phase}", "labels": labels},
            "spec": {
                "activeDeadlineSeconds": 120,
                "backoffLimit": 0,
                "ttlSecondsAfterFinished": 600,
                "template": {
                    "metadata": {"labels": labels},
                    "spec": {
                        "restartPolicy": "Never",
                        "automountServiceAccountToken": False,
                        "securityContext": {
                            "runAsNonRoot": True,
                            "runAsUser": 568,
                            "runAsGroup": 568,
                            "fsGroup": 568,
                            "fsGroupChangePolicy": "OnRootMismatch",
                            "seccompProfile": {"type": "RuntimeDefault"},
                        },
                        "initContainers": [
                            {
                                "name": "init-config",
                                "image": "ghcr.io/stuffanthings/qbit_manage:v4.10.0",
                                "command": [
                                    "python3",
                                    "/helpers/qbm-policy-config.py",
                                    run,
                                    phase,
                                ],
                                "securityContext": security,
                                "volumeMounts": [
                                    {"name": "config", "mountPath": "/config"},
                                    {"name": "helpers", "mountPath": "/helpers", "readOnly": True},
                                ],
                            }
                        ],
                        "containers": [
                            {
                                "name": "app",
                                "image": "ghcr.io/stuffanthings/qbit_manage:v4.10.0",
                                "command": ["/bin/sh", "-eu", "/helpers/qbm-policy-run.sh"],
                                "securityContext": security,
                                "env": [
                                    {"name": "QBT_WEB_SERVER", "value": "false"},
                                    {"name": "QBT_CONFIG_DIR", "value": "/config"},
                                    {"name": "QBT_LOGFILE", "value": "qbit_manage.log"},
                                    {"name": "QBT_LOG_LEVEL", "value": "INFO"},
                                    {"name": "PYTHONDONTWRITEBYTECODE", "value": "1"},
                                ],
                                "envFrom": [{"secretRef": {"name": "qbit-manage-secret"}}],
                                "volumeMounts": [
                                    {"name": "config", "mountPath": "/config"},
                                    {"name": "helpers", "mountPath": "/helpers", "readOnly": True},
                                    {
                                        "name": "data",
                                        "mountPath": "/data/downloads",
                                        "subPath": "downloads",
                                    },
                                ],
                            }
                        ],
                        "volumes": [
                            {"name": "config", "emptyDir": {}},
                            {
                                "name": "helpers",
                                "configMap": {
                                    "name": "qbit-manage-test-helpers-v1",
                                    "defaultMode": 292,
                                },
                            },
                            {"name": "data", "persistentVolumeClaim": {"claimName": "media-data"}},
                        ],
                    },
                },
            },
        }

    def test_qbit_manage_admits_all_fixed_phases_and_rejects_template_escape(self):
        for phase in ("cz-apply", "cz-repeat", "private", "limits", "cleanup", "cleanup-repeat"):
            for run in ("abc12345", "abc12345def67890", "abcdefghijklmnopqrstuvwx"):
                obj = self.qbit_fixture(phase, run)
                req = self.request("jobs", "media", name=obj["metadata"]["name"])
                with self.subTest(phase=phase, run=run):
                    self.assertTrue(self.admits_jobs(req, obj))
                    self.assertTrue(self.admits_jobs({**req, "operation": "DELETE"}, None, obj))
                    self.assertFalse(self.admits_jobs({**req, "operation": "UPDATE"}, obj, obj))
        obj = self.qbit_fixture()
        req = self.request("jobs", "media", name=obj["metadata"]["name"])
        for change in (
            "namespace",
            "phase",
            "init-command",
            "main-command",
            "init-env",
            "secret",
            "env",
            "init-sidecar",
            "sidecar",
            "token",
            "identity",
            "host-network",
            "dns",
            "helper-cm",
            "helper-items",
            "media-mount",
            "mount-expression",
            "hostpath",
            "init-hook",
            "main-hook",
            "image",
            "init-image",
            "root",
            "init-root",
            "capabilities",
            "privileged",
            "args",
            "probe",
            "annotation",
            "owner",
            "label",
            "run",
            "timeout",
            "init-mount",
            "init-secret",
            "pod-seccomp",
        ):
            bad = copy.deepcopy(obj)
            request = copy.deepcopy(req)
            ps = bad["spec"]["template"]["spec"]
            app, init = ps["containers"][0], ps["initContainers"][0]
            if change == "namespace":
                request["namespace"] = "automation"
            elif change == "phase":
                bad["metadata"]["name"] += "-other"
            elif change == "init-command":
                init["command"] = ["sh", "-c", "env"]
            elif change == "main-command":
                app["command"] = ["sh", "-c", "env"]
            elif change == "init-env":
                init["env"] = [{"name": "PYTHONPATH", "value": "/config"}]
            elif change == "secret":
                app["envFrom"][0]["secretRef"]["name"] = "other-secret"
            elif change == "env":
                app["env"].append({"name": "QBT_TAG_UPDATE", "value": "true"})
            elif change == "init-sidecar":
                ps["initContainers"].append(copy.deepcopy(init))
            elif change == "sidecar":
                ps["containers"].append(copy.deepcopy(app))
            elif change == "token":
                ps["automountServiceAccountToken"] = True
            elif change == "identity":
                ps["serviceAccountName"] = "openbao"
            elif change == "host-network":
                ps["hostNetwork"] = True
            elif change == "dns":
                ps["dnsConfig"] = {"nameservers": ["192.0.2.1"]}
            elif change == "helper-cm":
                ps["volumes"][1]["configMap"]["name"] = "caller-script"
            elif change == "helper-items":
                ps["volumes"][1]["configMap"]["items"] = [
                    {"key": "qbm-policy-run.sh", "path": "other.sh"}
                ]
            elif change == "media-mount":
                app["volumeMounts"][2]["mountPath"] = "/data/media"
            elif change == "mount-expression":
                app["volumeMounts"][2]["subPathExpr"] = "$(QBT_CONFIG_DIR)"
            elif change == "hostpath":
                ps["volumes"][2] = {"name": "data", "hostPath": {"path": "/"}}
            elif change == "init-hook":
                init["lifecycle"] = {"postStart": {"exec": {"command": ["env"]}}}
            elif change == "main-hook":
                app["lifecycle"] = {"postStart": {"exec": {"command": ["env"]}}}
            elif change == "image":
                app["image"] = "busybox:latest"
            elif change == "init-image":
                init["image"] = "busybox:latest"
            elif change == "root":
                app["securityContext"]["runAsUser"] = 0
            elif change == "init-root":
                init["securityContext"]["runAsUser"] = 0
            elif change == "capabilities":
                app["securityContext"]["capabilities"]["add"] = ["SYS_ADMIN"]
            elif change == "privileged":
                init["securityContext"]["privileged"] = True
            elif change == "args":
                app["args"] = ["-c", "env"]
            elif change == "probe":
                app["readinessProbe"] = {"exec": {"command": ["env"]}}
            elif change == "annotation":
                bad["spec"]["template"]["metadata"]["annotations"] = {"inject": "true"}
            elif change == "owner":
                bad["metadata"]["ownerReferences"] = [
                    {"kind": "Secret", "name": "production", "uid": "synthetic"}
                ]
            elif change == "label":
                bad["metadata"]["labels"]["homelab-talos/e2e-run"] = "other1234"
            elif change == "run":
                bad["metadata"]["labels"]["homelab-talos/run-id"] = "short"
            elif change == "timeout":
                bad["spec"]["activeDeadlineSeconds"] = 3600
            elif change == "init-mount":
                init["volumeMounts"][1]["readOnly"] = False
            elif change == "init-secret":
                init["envFrom"] = [{"secretRef": {"name": "qbit-manage-secret"}}]
            elif change == "pod-seccomp":
                ps["securityContext"]["seccompProfile"] = {"type": "Unconfined"}
            with self.subTest(change=change):
                self.assertFalse(self.admits_jobs(request, bad))

    def test_qbit_manage_backend_render_matches_enforced_fixture(self):
        import sys

        sys.path.insert(0, str(ROOT / "scripts/test/scenarios"))
        import qbit_manage_policy as qbm

        for phase in ("cz-apply", "cz-repeat", "private", "limits", "cleanup", "cleanup-repeat"):
            obj = qbm.job_manifest(qbm.RunIdentity("abc12345def67890"), phase, qbm.QBM_IMAGE)
            req = self.request("jobs", "media", name=obj["metadata"]["name"])
            self.assertTrue(self.admits_jobs(req, obj))

    def test_media_runtime_access_is_limited_to_registered_targets(self):
        role = next(
            (
                d
                for d in self.documents
                if d["kind"] == "Role"
                and d["metadata"]["name"] == "homelab-test-media-runtime"
                and d["metadata"]["namespace"] == "media"
            ),
            None,
        )
        self.assertIsNotNone(role)
        self.assertEqual(
            role["rules"],
            [
                {"apiGroups": [""], "resources": ["pods"], "verbs": ["create"]},
                {"apiGroups": [""], "resources": ["pods/exec"], "verbs": ["get", "create"]},
            ],
        )
        for target, container, stdin in (
            ("qbit-manage-756dbd787f-abcde", "app", True),
            ("sonarr-756dbd787f-abcde", "app", False),
            ("qbittorrent-756dbd787f-abcde", "app", True),
            ("plex-756dbd787f-abcde", "app", False),
            ("plex-policy-control-1770000000-123", "", False),
            ("plex-policy-selected-1770000000-123", "probe", False),
        ):
            req = self.request("pods", "media", "CONNECT", name=target)
            req["subResource"] = "exec"
            obj = {
                "command": ["sh", "-c", "true"],
                "container": container,
                "stdin": stdin,
                "tty": False,
            }
            self.assertTrue(self.admits("homelab-test-media-runtime", req, obj))
            for field, value in (
                ("name", "unrelated-756dbd787f-abcde"),
                ("container", "gluetun"),
                ("container", "init-config"),
                ("tty", True),
            ):
                bad_req, bad = copy.deepcopy(req), copy.deepcopy(obj)
                (bad_req if field == "name" else bad)[field] = value
                with self.subTest(target=target, field=field, value=value):
                    self.assertFalse(self.admits("homelab-test-media-runtime", bad_req, bad))

    def test_plex_probes_have_fixed_selected_and_control_shapes(self):
        for role, label in (("control", "plex-policy-control"), ("selected", "plex")):
            run = "1770000000-123"
            name = f"plex-policy-{role}-{run}"
            labels = {
                "app.kubernetes.io/name": label,
                "app.kubernetes.io/instance": "plex-network-policy-test",
                "homelab-talos/test": "plex-network-policy",
                "homelab-talos/run-id": run,
            }
            obj = {
                "metadata": {"name": name, "labels": labels},
                "spec": {
                    "activeDeadlineSeconds": 1800,
                    "restartPolicy": "Never",
                    "automountServiceAccountToken": False,
                    "securityContext": {
                        "runAsNonRoot": True,
                        "runAsUser": 568,
                        "runAsGroup": 568,
                        "fsGroup": 568,
                        "seccompProfile": {"type": "RuntimeDefault"},
                    },
                    "containers": [
                        {
                            "name": "probe",
                            "image": "ghcr.io/home-operations/plex:1.43.3.10828@sha256:0c0b6899339503af17cb190b25af6acf10f0030e2820985e16ee14ef428f49d7",
                            "command": ["sleep", "infinity"],
                            "securityContext": {
                                "allowPrivilegeEscalation": False,
                                "readOnlyRootFilesystem": True,
                                "capabilities": {"drop": ["ALL"]},
                            },
                        }
                    ],
                },
            }
            req = self.request("pods", "media", name=name)
            self.assertTrue(self.admits("homelab-test-probe-pods", req, obj))
            self.assertTrue(
                self.admits("homelab-test-probe-pods", {**req, "operation": "DELETE"}, None, obj)
            )
            self.assertTrue(
                self.admits("homelab-test-disruption", {**req, "operation": "DELETE"}, None, obj)
            )
            self.assertFalse(
                self.admits("homelab-test-probe-pods", {**req, "operation": "UPDATE"}, obj, obj)
            )
            for field in (
                "service-label",
                "secret",
                "token",
                "image",
                "program",
                "env",
                "owner",
                "init",
                "hook",
                "root",
            ):
                bad = copy.deepcopy(obj)
                ps, app = bad["spec"], bad["spec"]["containers"][0]
                if field == "service-label":
                    bad["metadata"]["labels"]["app.kubernetes.io/instance"] = "plex"
                elif field == "secret":
                    ps["volumes"] = [{"name": "secret", "secret": {"secretName": "production"}}]
                elif field == "token":
                    ps["automountServiceAccountToken"] = True
                elif field == "image":
                    app["image"] = "busybox:latest"
                elif field == "program":
                    app["command"] = ["sh", "-c", "env"]
                elif field == "env":
                    app["envFrom"] = [{"secretRef": {"name": "production"}}]
                elif field == "owner":
                    bad["metadata"]["ownerReferences"] = [
                        {"kind": "Deployment", "name": "plex", "uid": "synthetic"}
                    ]
                elif field == "init":
                    ps["initContainers"] = [copy.deepcopy(app)]
                elif field == "hook":
                    app["readinessProbe"] = {"exec": {"command": ["env"]}}
                elif field == "root":
                    app["securityContext"]["runAsUser"] = 0
                with self.subTest(role=role, field=field):
                    self.assertFalse(self.admits("homelab-test-probe-pods", req, bad))

    def test_plex_backend_renders_the_admitted_control_and_selected_probes(self):
        source = (ROOT / "scripts/test/scenarios/plex-network-policy.sh").read_text()
        program = source[
            source.index("render_probe() {") : source.index('\nrender_probe "$control_pod"')
        ]
        image = re.search(r"^image='([^']+)'$", source, re.MULTILINE)[1]
        with tempfile.TemporaryDirectory() as directory:
            for role, app in (("control", "plex-policy-control"), ("selected", "plex")):
                name = f"plex-policy-{role}-1770000000-123"
                subprocess.run(
                    ["bash", "-eu", "-c", program + '\nrender_probe "$pod_name" "$app_name"'],
                    check=True,
                    env={
                        **os.environ,
                        "temp_dir": directory,
                        "namespace": "media",
                        "run_suffix": "1770000000-123",
                        "image": image,
                        "pod_name": name,
                        "app_name": app,
                    },
                )
                obj = yaml.safe_load((Path(directory) / f"{name}.yaml").read_text())
                req = self.request("pods", "media", name=name)
                self.assertTrue(self.admits("homelab-test-probe-pods", req, obj))
                self.assertTrue(
                    self.admits(
                        "homelab-test-probe-pods", {**req, "operation": "DELETE"}, None, obj
                    )
                )

    def test_generalized_runner_has_no_unrestricted_mutation_or_secret_grants(self):
        accounts = [
            d
            for d in self.documents
            if d["kind"] == "ServiceAccount" and d["metadata"]["name"] == "homelab-test-runner"
        ]
        self.assertEqual(len(accounts), 1)
        roles = {
            (d["kind"], d["metadata"].get("namespace", ""), d["metadata"]["name"]): d
            for d in self.documents
            if d["kind"] in {"Role", "ClusterRole"}
        }
        bindings = [
            d
            for d in self.documents
            if d["kind"] in {"RoleBinding", "ClusterRoleBinding"}
            and any(
                s.get("name") == "homelab-test-runner" and s.get("namespace") == "kube-system"
                for s in d.get("subjects", [])
            )
        ]
        self.assertTrue(bindings)
        for binding in bindings:
            ref = binding["roleRef"]
            if ref["name"] == "view":
                continue
            role = roles[
                (
                    ref["kind"],
                    binding["metadata"].get("namespace", "") if ref["kind"] == "Role" else "",
                    ref["name"],
                )
            ]
            for rule in role["rules"]:
                self.assertNotIn("*", rule["apiGroups"])
                self.assertNotIn("*", rule["resources"])
                self.assertNotIn("*", rule["verbs"])
                self.assertFalse(
                    set(rule["verbs"]) & {"bind", "escalate", "impersonate", "deletecollection"}
                )
                writes = set(rule["verbs"]) - {"get", "list", "watch"}
                if writes:
                    self.assertFalse(
                        set(rule["resources"])
                        & {
                            "nodes",
                            "namespaces",
                            "serviceaccounts",
                            "serviceaccounts/token",
                            "roles",
                            "rolebindings",
                            "clusterroles",
                            "clusterrolebindings",
                        }
                    )
                if "secrets" in rule["resources"]:
                    self.assertTrue(rule.get("resourceNames"))
                    self.assertNotIn("list", rule["verbs"])

    def test_fresh_pvc_allowed_but_unrelated_claim_and_shape_denied(self):
        request = self.request(
            "persistentvolumeclaims", "longhorn-system", name="storage-provisioning-123-456"
        )
        obj = {
            "metadata": {
                "name": request["name"],
                "namespace": request["namespace"],
                "labels": {"homelab-talos/test": "storage-provisioning"},
            },
            "spec": {
                "accessModes": ["ReadWriteOnce"],
                "storageClassName": "longhorn",
                "resources": {"requests": {"storage": "1Gi"}},
            },
        }
        self.assertTrue(self.admits("homelab-test-storage", request, obj))
        for change in ("name", "namespace", "class", "size", "dataSource"):
            bad, req = copy.deepcopy(obj), copy.deepcopy(request)
            if change == "name":
                bad["metadata"]["name"] = req["name"] = "production-claim"
            elif change == "namespace":
                req["namespace"] = bad["metadata"]["namespace"] = "openbao"
            elif change == "class":
                bad["spec"]["storageClassName"] = "other"
            elif change == "size":
                bad["spec"]["resources"]["requests"]["storage"] = "1Ti"
            else:
                bad["spec"]["dataSource"] = {"kind": "PersistentVolumeClaim", "name": "production"}
            with self.subTest(change=change):
                self.assertFalse(self.admits("homelab-test-storage", req, bad))
        deleting = {**request, "operation": "DELETE"}
        self.assertTrue(self.admits("homelab-test-storage", deleting, None, obj))

    def test_restore_claims_must_be_fresh_bounded_and_owned(self):
        for family, namespace, role, suffix in (
            ("automation-data-restore-drill", "automation-data", "ad-data", "ad-data"),
            ("automation-data-restore-drill", "automation", "n8n-data", "n8n-data"),
            ("nocodb-restore-drill", "automation-data", "database-data", "db-data"),
        ):
            run = "abc12345def6"
            prefix = "ad" if family.startswith("automation") else "nc"
            name = f"{prefix}-restore-{run}-{suffix}"
            obj = {
                "metadata": {
                    "name": name,
                    "labels": {
                        "homelab-talos/test": family,
                        "homelab-talos/run-id": run,
                        "homelab-talos/role": role,
                    },
                },
                "spec": {
                    "accessModes": ["ReadWriteOnce"],
                    "storageClassName": "longhorn",
                    "resources": {"requests": {"storage": "20Gi"}},
                },
            }
            req = self.request("persistentvolumeclaims", namespace, name=name)
            self.assertTrue(self.admits("homelab-test-storage", req, obj))
            self.assertFalse(
                self.admits("homelab-test-storage", {**req, "operation": "UPDATE"}, obj, obj)
            )
            deleting = copy.deepcopy(obj)
            deleting["spec"]["volumeName"] = "synthetic-controller-volume"
            deleting["metadata"]["finalizers"] = ["kubernetes.io/pvc-protection"]
            self.assertTrue(
                self.admits("homelab-test-storage", {**req, "operation": "DELETE"}, None, deleting)
            )
            for change in (
                "namespace",
                "role",
                "name",
                "class",
                "size",
                "access",
                "source",
                "binding",
                "annotation",
                "owner",
            ):
                bad, request = copy.deepcopy(obj), copy.deepcopy(req)
                if change == "namespace":
                    request["namespace"] = "openbao"
                elif change == "role":
                    bad["metadata"]["labels"]["homelab-talos/role"] = "production"
                elif change == "name":
                    bad["metadata"]["name"] = "production-data"
                elif change == "class":
                    bad["spec"]["storageClassName"] = "other"
                elif change == "size":
                    bad["spec"]["resources"]["requests"]["storage"] = "1Ti"
                elif change == "access":
                    bad["spec"]["accessModes"] = ["ReadWriteMany"]
                elif change == "source":
                    bad["spec"]["dataSourceRef"] = {
                        "kind": "PersistentVolumeClaim",
                        "name": "production",
                    }
                elif change == "binding":
                    bad["spec"]["volumeName"] = "existing-volume"
                elif change == "annotation":
                    bad["metadata"]["annotations"] = {"storage.example/override": "true"}
                elif change == "owner":
                    bad["metadata"]["ownerReferences"] = [
                        {"kind": "Secret", "name": "production", "uid": "synthetic"}
                    ]
                with self.subTest(family=family, role=role, change=change):
                    self.assertFalse(self.admits("homelab-test-storage", request, bad))

    def test_restore_services_cannot_capture_production_selectors_or_ports(self):
        cases = (
            (
                "automation-data-restore-drill",
                "automation-data",
                "ad-database",
                "db",
                5432,
                "postgresql",
            ),
            (
                "automation-data-restore-drill",
                "automation",
                "n8n-database",
                "n8n-db",
                5432,
                "postgresql",
            ),
            ("automation-data-restore-drill", "automation", "n8n", "n8n", 5678, "http"),
            ("nocodb-restore-drill", "automation-data", "database", "db", 5432, "postgresql"),
            ("nocodb-restore-drill", "automation-data", "nocodb", "nocodb", 8080, "http"),
        )
        for family, namespace, role, suffix, port, port_name in cases:
            run = "abc12345def6"
            prefix = "ad" if family.startswith("automation") else "nc"
            labels = {
                "homelab-talos/test": family,
                "homelab-talos/run-id": run,
                "homelab-talos/role": role,
            }
            obj = {
                "metadata": {"name": f"{prefix}-restore-{run}-{suffix}", "labels": labels},
                "spec": {
                    "type": "ClusterIP",
                    "selector": labels,
                    "ports": [
                        {
                            "name": port_name,
                            "port": port,
                            "targetPort": port_name,
                            "protocol": "TCP",
                        }
                    ],
                },
            }
            req = self.request("services", namespace, name=obj["metadata"]["name"])
            self.assertTrue(self.admits("homelab-test-services", req, obj))
            self.assertTrue(
                self.admits("homelab-test-services", {**req, "operation": "DELETE"}, None, obj)
            )
            self.assertFalse(
                self.admits("homelab-test-services", {**req, "operation": "UPDATE"}, obj, obj)
            )
            for change in (
                "namespace",
                "name",
                "role",
                "selector",
                "external",
                "port",
                "target",
                "type",
            ):
                bad, request = copy.deepcopy(obj), copy.deepcopy(req)
                if change == "namespace":
                    request["namespace"] = "openbao"
                elif change == "name":
                    bad["metadata"]["name"] = "production-service"
                elif change == "role":
                    bad["metadata"]["labels"]["homelab-talos/role"] = "other"
                elif change == "selector":
                    bad["spec"]["selector"] = {"app.kubernetes.io/name": "n8n"}
                elif change == "external":
                    bad["spec"]["externalIPs"] = ["192.0.2.1"]
                elif change == "port":
                    bad["spec"]["ports"][0]["port"] = 80
                elif change == "target":
                    bad["spec"]["ports"][0]["targetPort"] = 80
                elif change == "type":
                    bad["spec"]["type"] = "ExternalName"
                with self.subTest(family=family, role=role, change=change):
                    self.assertFalse(self.admits("homelab-test-services", request, bad))

    def test_report_exec_only_reads_canonical_paths(self):
        req = self.request("pods", "test-reports", "CONNECT", "test-reports-123abc-abc12")
        req["subResource"] = "exec"
        obj = {
            "container": "caddy",
            "stdin": False,
            "stdout": True,
            "stderr": True,
            "tty": False,
            "command": ["readlink", "/srv/state/current"],
        }
        self.assertTrue(self.admits("homelab-test-report-exec", req, obj))
        for command in (
            ["cat", "/srv/state/current/catalog.json"],
            [
                "sha256sum",
                "/srv/reports/20261002T120000Z-0123456789ab-agent-01234567/awesome/index.html",
            ],
            ["sha256sum", "/srv/artifacts/20261002T120000Z-0123456789ab-agent-01234567.tar.gz"],
        ):
            self.assertTrue(
                self.admits("homelab-test-report-exec", req, {**obj, "command": command})
            )
        for change in (
            {"command": ["sh", "-c", "cat /srv/state/current/catalog.json"]},
            {"command": ["rm", "/srv/state/current/catalog.json"]},
            {"command": ["cat", "/etc/passwd"]},
            {"command": ["sha256sum", "/srv/reports/../state/catalog.json"]},
            {"stdin": True},
            {"tty": True},
            {"container": "other"},
        ):
            with self.subTest(change=change):
                self.assertFalse(self.admits("homelab-test-report-exec", req, {**obj, **change}))

    def test_n8n_helper_only_uses_fixed_program_and_scratch_database(self):
        req = self.request("jobs", "automation", name="n8n-restore-0123456789ab-load")
        req["resource"]["group"] = "batch"
        labels = {
            "homelab-talos/test": "n8n-restore-drill",
            "homelab-talos/run-id": "0123456789ab",
            "homelab-talos/role": "database-helper",
        }
        container = {
            "name": "restore",
            "image": "postgres:17.11-alpine3.24",
            "command": ["/bin/sh", "-eu", "/helpers/n8n-restore-load.sh"],
            "env": [
                {"name": "PGHOST", "value": "n8n-postgresql.automation.svc.cluster.local"},
                {"name": "PGPORT", "value": "5432"},
                {"name": "PGUSER", "value": "postgres"},
                {
                    "name": "PGPASSWORD",
                    "valueFrom": {
                        "secretKeyRef": {
                            "name": "postgresql-credentials",
                            "key": "postgres-superuser-password",
                        }
                    },
                },
                {"name": "RESTORE_DATABASE", "value": "n8n_restore_0123456789ab"},
            ],
            "securityContext": {
                "allowPrivilegeEscalation": False,
                "capabilities": {"drop": ["ALL"]},
                "readOnlyRootFilesystem": True,
            },
            "volumeMounts": [
                {"name": "helpers", "mountPath": "/helpers", "readOnly": True},
                {"name": "backups", "mountPath": "/backups", "readOnly": True},
                {"name": "tmp", "mountPath": "/tmp"},
            ],
        }
        ps = {
            "automountServiceAccountToken": False,
            "restartPolicy": "Never",
            "securityContext": {
                "runAsNonRoot": True,
                "runAsUser": 70,
                "runAsGroup": 70,
                "fsGroup": 70,
                "seccompProfile": {"type": "RuntimeDefault"},
            },
            "containers": [container],
            "volumes": [
                {"name": "helpers", "configMap": {"name": "n8n-test-helpers-v1"}},
                {
                    "name": "backups",
                    "persistentVolumeClaim": {"claimName": "n8n-postgresql-backups"},
                },
                {"name": "tmp", "emptyDir": {}},
            ],
        }
        obj = {
            "metadata": {"name": req["name"], "labels": labels},
            "spec": {
                "activeDeadlineSeconds": 1800,
                "backoffLimit": 0,
                "template": {"metadata": {"labels": labels}, "spec": ps},
            },
        }
        self.assertTrue(self.admits_jobs(req, obj))
        for change in (
            "command",
            "database",
            "secret",
            "image",
            "serviceaccount",
            "token",
            "hostpath",
            "script",
            "sidecar",
            "dns",
            "backup-write",
            "probe",
            "container-user",
            "annotations",
            "owner",
        ):
            bad = copy.deepcopy(obj)
            pod = bad["spec"]["template"]["spec"]
            app = pod["containers"][0]
            if change == "command":
                app["command"] = ["/bin/sh", "-c", "env"]
            elif change == "database":
                app["env"][4]["value"] = "postgres"
            elif change == "secret":
                app["env"][3]["valueFrom"]["secretKeyRef"]["name"] = "other-secret"
            elif change == "image":
                app["image"] = "busybox:latest"
            elif change == "serviceaccount":
                pod["serviceAccountName"] = "openbao"
            elif change == "token":
                pod["automountServiceAccountToken"] = True
            elif change == "hostpath":
                pod["volumes"][2] = {"name": "tmp", "hostPath": {"path": "/"}}
            elif change == "script":
                pod["volumes"][0]["configMap"]["name"] = "mutable-script"
            elif change == "sidecar":
                pod["containers"].append(copy.deepcopy(app))
            elif change == "dns":
                pod["hostAliases"] = [
                    {
                        "ip": "192.0.2.1",
                        "hostnames": ["n8n-postgresql.automation.svc.cluster.local"],
                    }
                ]
            elif change == "backup-write":
                app["volumeMounts"][1]["readOnly"] = False
            elif change == "probe":
                app["livenessProbe"] = {"exec": {"command": ["sh", "-c", "env"]}}
            elif change == "container-user":
                app["securityContext"]["runAsUser"] = 0
            elif change == "annotations":
                bad["spec"]["template"]["metadata"]["annotations"] = {
                    "test.example/inject": "true"
                }
            else:
                bad["metadata"]["ownerReferences"] = [
                    {
                        "apiVersion": "v1",
                        "kind": "Secret",
                        "name": "production",
                        "uid": "synthetic",
                    }
                ]
            with self.subTest(change=change):
                self.assertFalse(self.admits_jobs(req, bad))

    def test_n8n_backend_manifests_match_policy_and_immutable_helpers(self):
        source = (ROOT / "scripts/test/scenarios/n8n-restore-drill.sh").read_text()
        application = source.split("application_manifests() {", 1)[1].split(
            "\nrequest_job_manifest() {", 1
        )[0]
        rendered = subprocess.run(
            [
                "bash",
                "-c",
                "set -euo pipefail\nrun_hash=0123456789ab\n"
                "database_name=n8n_restore_$run_hash\n"
                "deployment=n8n-restore-$run_hash\n"
                "application_manifests() {" + application + "\napplication_manifests\n",
            ],
            capture_output=True,
            text=True,
            check=True,
            cwd=ROOT,
        )
        service = next(d for d in yaml.safe_load_all(rendered.stdout) if d["kind"] == "Service")
        req = self.request("services", "automation", name=service["metadata"]["name"])
        self.assertTrue(self.admits("homelab-test-services", req, service))
        self.assertTrue(
            self.admits("homelab-test-services", {**req, "operation": "DELETE"}, None, service)
        )
        function = source.split("database_job_manifest() {", 1)[1].split(
            "\napplication_manifests() {", 1
        )[0]
        script = (
            "set -euo pipefail\nrun_hash=0123456789ab\n"
            "database_name=n8n_restore_$run_hash\n"
            "database_job_manifest() {" + function
        )
        for phase, operation in (("load", "restore"), ("drop", "drop")):
            name = f"n8n-restore-0123456789ab-{phase}"
            rendered = subprocess.run(
                ["bash", "-c", script + f"\ndatabase_job_manifest {name} {operation}\n"],
                capture_output=True,
                text=True,
                check=True,
                cwd=ROOT,
            )
            obj = yaml.safe_load(rendered.stdout)
            req = self.request("jobs", "automation", name=name)
            req["resource"]["group"] = "batch"
            self.assertTrue(self.admits_jobs(req, obj))
            self.assertTrue(self.admits_jobs({**req, "operation": "DELETE"}, None, obj))
            self.assertFalse(self.admits_jobs({**req, "operation": "UPDATE"}, obj, obj))
        rendered = subprocess.run(
            ["kustomize", "build", str(ROOT / "kubernetes/apps/automation/n8n/app")],
            capture_output=True,
            text=True,
            check=True,
        )
        helpers = [
            d
            for d in yaml.safe_load_all(rendered.stdout)
            if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "n8n-test-helpers-v1"
        ]
        self.assertEqual(len(helpers), 1)
        self.assertTrue(helpers[0]["immutable"])
        self.assertEqual(
            set(helpers[0]["data"]),
            {
                "n8n-restore-common.sh",
                "n8n-restore-load.sh",
                "n8n-restore-drop.sh",
                "n8n-restore-isolated.sh",
            },
        )
        for name, content in helpers[0]["data"].items():
            self.assertEqual(
                content,
                (ROOT / "kubernetes/apps/automation/n8n/app/test-helpers" / name).read_text(),
            )

    def test_n8n_persistence_cannot_read_or_write_other_paths(self):
        req = self.request("jobs", "automation", name="n8n-persistence-0123456789ab-write")
        req["resource"]["group"] = "batch"
        labels = {"homelab-talos/test": "n8n-persistence", "homelab-talos/run-id": "0123456789ab"}
        container = {
            "name": "sentinel",
            "image": "docker.n8n.io/n8nio/n8n:2.36.7",
            "command": ["/bin/sh", "-ceu"],
            "args": [
                'umask 077; printf %s "$SENTINEL_VALUE" >"$SENTINEL"; sync; test "$(cat "$SENTINEL")" = "$SENTINEL_VALUE"'
            ],
            "env": [
                {"name": "SENTINEL", "value": "/data/.homelab-n8n-persistence-0123456789ab"},
                {"name": "SENTINEL_VALUE", "value": "homelab-n8n-persistence-0123456789ab"},
            ],
            "securityContext": {
                "allowPrivilegeEscalation": False,
                "capabilities": {"drop": ["ALL"]},
                "readOnlyRootFilesystem": True,
                "runAsGroup": 1000,
                "runAsUser": 1000,
                "runAsNonRoot": True,
            },
            "volumeMounts": [{"name": "data", "mountPath": "/data"}],
        }
        pod = {
            "automountServiceAccountToken": False,
            "nodeName": "synthetic-node",
            "restartPolicy": "Never",
            "securityContext": {"fsGroup": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
            "containers": [container],
            "volumes": [{"name": "data", "persistentVolumeClaim": {"claimName": "n8n-data"}}],
        }
        obj = {
            "metadata": {"name": req["name"], "labels": labels},
            "spec": {
                "activeDeadlineSeconds": 300,
                "backoffLimit": 0,
                "template": {"metadata": {"labels": labels}, "spec": pod},
            },
        }
        self.assertTrue(self.admits_jobs(req, obj))
        for change in (
            "path",
            "program",
            "claim",
            "env",
            "probe",
            "identity",
            "token",
            "image",
            "labels",
        ):
            bad = copy.deepcopy(obj)
            ps = bad["spec"]["template"]["spec"]
            app = ps["containers"][0]
            if change == "path":
                app["env"][0]["value"] = "/data/database.sqlite"
            elif change == "program":
                app["args"] = ["cat /data/database.sqlite"]
            elif change == "claim":
                ps["volumes"][0]["persistentVolumeClaim"]["claimName"] = "other"
            elif change == "env":
                app["env"].append({"name": "ENV", "value": "/data/injected.sh"})
            elif change == "probe":
                app["readinessProbe"] = {"exec": {"command": ["sh", "-c", "env"]}}
            elif change == "identity":
                ps["serviceAccountName"] = "n8n"
            elif change == "token":
                ps["automountServiceAccountToken"] = True
            elif change == "image":
                app["image"] = "busybox:latest"
            else:
                bad["spec"]["template"]["metadata"]["labels"]["app.kubernetes.io/name"] = "n8n"
            with self.subTest(change=change):
                self.assertFalse(self.admits_jobs(req, bad))

    def test_n8n_persistence_backend_all_phases_match_policy(self):
        source = (ROOT / "scripts/test/scenarios/n8n-persistence.sh").read_text()
        function = source.split("job_manifest() {", 1)[1].split("\njob_absent() {", 1)[0]
        script = (
            "set -euo pipefail\nrun_hash=0123456789ab\n"
            "sentinel=/data/.homelab-n8n-persistence-$run_hash\n"
            "sentinel_value=homelab-n8n-persistence-$run_hash\n"
            "job_manifest() {" + function
        )
        for phase, operation in (
            ("write", "write"),
            ("verify", "verify-remove"),
            ("cleanup", "cleanup"),
        ):
            name = f"n8n-persistence-0123456789ab-{phase}"
            rendered = subprocess.run(
                ["bash", "-c", script + f"\njob_manifest {name} synthetic-node {operation}\n"],
                capture_output=True,
                text=True,
                check=True,
                cwd=ROOT,
            )
            obj = yaml.safe_load(rendered.stdout)
            req = self.request("jobs", "automation", name=name)
            req["resource"]["group"] = "batch"
            self.assertTrue(self.admits_jobs(req, obj))
            self.assertTrue(self.admits_jobs({**req, "operation": "DELETE"}, None, obj))
            self.assertFalse(self.admits_jobs({**req, "operation": "UPDATE"}, obj, obj))

    def test_n8n_request_credentials_stay_in_fixed_helper(self):
        req = self.request("jobs", "gatus", name="n8n-restore-0123456789ab-request")
        req["resource"]["group"] = "batch"
        labels = {
            "homelab-talos/test": "n8n-restore-drill",
            "homelab-talos/run-id": "0123456789ab",
            "homelab-talos/role": "request",
        }
        app = {
            "name": "request",
            "image": "docker.n8n.io/n8nio/n8n:2.36.7",
            "command": ["node", "/helpers/n8n-restore-request.mjs"],
            "env": [
                {"name": "APP_NAME", "value": "n8n-restore-0123456789ab"},
                {"name": "RUN_HASH", "value": "0123456789ab"},
                {
                    "name": "CANARY_TOKEN",
                    "valueFrom": {"secretKeyRef": {"name": "n8n-canary", "key": "token"}},
                },
                {"name": "HOME", "value": "/tmp"},
            ],
            "securityContext": {
                "allowPrivilegeEscalation": False,
                "capabilities": {"drop": ["ALL"]},
                "readOnlyRootFilesystem": True,
                "runAsGroup": 1000,
                "runAsUser": 1000,
                "runAsNonRoot": True,
            },
            "volumeMounts": [
                {"name": "helpers", "mountPath": "/helpers", "readOnly": True},
                {"name": "tmp", "mountPath": "/tmp"},
            ],
        }
        pod = {
            "automountServiceAccountToken": False,
            "restartPolicy": "Never",
            "securityContext": {
                "runAsNonRoot": True,
                "seccompProfile": {"type": "RuntimeDefault"},
            },
            "containers": [app],
            "volumes": [
                {"name": "helpers", "configMap": {"name": "n8n-test-request-helpers-v1"}},
                {"name": "tmp", "emptyDir": {}},
            ],
        }
        obj = {
            "metadata": {"name": req["name"], "labels": labels},
            "spec": {
                "activeDeadlineSeconds": 300,
                "backoffLimit": 0,
                "template": {"metadata": {"labels": labels}, "spec": pod},
            },
        }
        self.assertTrue(self.admits_jobs(req, obj))
        for change in ("endpoint", "script", "env", "image", "identity", "token"):
            bad = copy.deepcopy(obj)
            ps = bad["spec"]["template"]["spec"]
            app = ps["containers"][0]
            if change == "endpoint":
                app["env"][0]["value"] = "production"
            elif change == "script":
                app["command"] = ["node", "--eval", "console.log(process.env)"]
            elif change == "env":
                app["env"].append({"name": "NODE_OPTIONS", "value": "--require=/tmp/injected.js"})
            elif change == "image":
                app["image"] = "busybox:latest"
            elif change == "identity":
                ps["serviceAccountName"] = "gatus"
            else:
                app["env"][2]["valueFrom"]["secretKeyRef"]["name"] = "other-secret"
            with self.subTest(change=change):
                self.assertFalse(self.admits_jobs(req, bad))

    def test_n8n_request_backend_uses_immutable_program(self):
        source = (ROOT / "scripts/test/scenarios/n8n-restore-drill.sh").read_text()
        function = source.split("request_job_manifest() {", 1)[1].split("\ncleanup() {", 1)[0]
        script = (
            "set -euo pipefail\nrun_hash=0123456789ab\nservice=n8n-restore-$run_hash\n"
            "request_job=$service-request\nrequest_job_manifest() {"
            + function
            + "\nrequest_job_manifest\n"
        )
        rendered = subprocess.run(
            ["bash", "-c", script], capture_output=True, text=True, check=True, cwd=ROOT
        )
        obj = yaml.safe_load(rendered.stdout)
        req = self.request("jobs", "gatus", name="n8n-restore-0123456789ab-request")
        req["resource"]["group"] = "batch"
        self.assertTrue(self.admits_jobs(req, obj))
        self.assertTrue(self.admits_jobs({**req, "operation": "DELETE"}, None, obj))
        rendered = subprocess.run(
            ["kustomize", "build", str(ROOT / "kubernetes/apps/monitoring/gatus/app")],
            capture_output=True,
            text=True,
            check=True,
        )
        helpers = [
            d
            for d in yaml.safe_load_all(rendered.stdout)
            if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "n8n-test-request-helpers-v1"
        ]
        self.assertEqual(len(helpers), 1)
        self.assertTrue(helpers[0]["immutable"])
        self.assertEqual(set(helpers[0]["data"]), {"n8n-restore-request.mjs"})

    def test_fixed_request_program_preserves_authenticated_canary_contract(self):
        program = (
            ROOT / "kubernetes/apps/monitoring/gatus/app/test-helpers/n8n-restore-request.mjs"
        ).as_uri()
        expected = {
            "status": "ok",
            "correlation": "restore-0123456789ab",
            "executionId": "synthetic-execution",
        }
        cases = (
            (401, expected, True),
            (200, expected, False),
            (401, {**expected, "executionId": ""}, False),
            (401, {**expected, "correlation": "other-run"}, False),
            (401, {**expected, "extra": "unexpected"}, False),
        )
        for negative_status, body, succeeds in cases:
            script = (
                "import assert from 'node:assert/strict';\nlet calls=0;\n"
                "globalThis.fetch=async (url, options) => {\n"
                "assert.equal(url, 'http://n8n-restore-0123456789ab.automation.svc.cluster.local:5678/webhook/platform-canary');\n"
                "assert.equal(options.method, 'POST');\n"
                "assert.equal(options.headers['Content-Type'], 'application/json');\n"
                "calls++;\nif (calls === 1) {\n"
                "assert.equal(options.headers['X-Platform-Canary'], undefined);\n"
                "assert.deepEqual(JSON.parse(options.body), {correlation:'restore-negative-0123456789ab'});\n"
                f"return {{status:{negative_status}}};\n}}\n"
                "assert.equal(calls, 2);\nassert.equal(options.headers['X-Platform-Canary'], 'synthetic-canary');\n"
                "assert.deepEqual(JSON.parse(options.body), {correlation:'restore-0123456789ab'});\n"
                f"return {{ok:true,json:async()=>({json.dumps(body)})}};\n}};\n"
                f"await import({json.dumps(program)});\nassert.equal(calls, 2);\n"
            )
            result = subprocess.run(
                ["node", "--input-type=module", "--eval", script],
                capture_output=True,
                text=True,
                check=False,
                env={
                    **os.environ,
                    "APP_NAME": "n8n-restore-0123456789ab",
                    "RUN_HASH": "0123456789ab",
                    "CANARY_TOKEN": "synthetic-canary",
                },
            )
            with self.subTest(negative_status=negative_status, body=body):
                self.assertEqual(result.returncode == 0, succeeds, result.stderr)

    def test_disruption_deletes_only_registered_controller_pods(self):
        cases = (
            ("automation", "n8n", "ReplicaSet", "n8n-123abc", "n8n-123abc-abc12"),
            ("automation", "n8n-postgresql", "StatefulSet", "n8n-postgresql", "n8n-postgresql-0"),
            (
                "media",
                "qbittorrent",
                "ReplicaSet",
                "qbittorrent-123abc",
                "qbittorrent-123abc-abc12",
            ),
            ("portainer", "portainer", "ReplicaSet", "portainer-123abc", "portainer-123abc-abc12"),
            (
                "test-reports",
                "test-reports",
                "ReplicaSet",
                "test-reports-123abc",
                "test-reports-123abc-abc12",
            ),
            (
                "tailscale",
                "lab-subnet-router",
                "StatefulSet",
                "ts-lab-subnet-router-abc12",
                "ts-lab-subnet-router-abc12-1",
            ),
        )
        for ns, app, kind, owner, name in cases:
            labels = (
                {"tailscale.supermorphic.com/component": app}
                if ns == "tailscale"
                else {"app.kubernetes.io/name": app}
            )
            req = self.request("pods", ns, "DELETE", name)
            obj = {
                "metadata": {
                    "name": name,
                    "namespace": ns,
                    "labels": labels,
                    "ownerReferences": [
                        {
                            "apiVersion": "apps/v1",
                            "kind": kind,
                            "name": owner,
                            "uid": "synthetic-uid",
                            "controller": True,
                        }
                    ],
                }
            }
            with self.subTest(namespace=ns, app=app):
                self.assertTrue(self.admits("homelab-test-disruption", req, None, obj))
                for change in ("namespace", "label", "owner", "controller", "kind", "name"):
                    bad, request = copy.deepcopy(obj), copy.deepcopy(req)
                    if change == "namespace":
                        request["namespace"] = bad["metadata"]["namespace"] = "openbao"
                    elif change == "label":
                        bad["metadata"]["labels"] = {"app.kubernetes.io/name": "other"}
                    elif change == "owner":
                        bad["metadata"]["ownerReferences"][0]["name"] = "other-controller"
                    elif change == "controller":
                        bad["metadata"]["ownerReferences"][0]["controller"] = False
                    elif change == "kind":
                        bad["metadata"]["ownerReferences"][0]["kind"] = "Job"
                    else:
                        bad["metadata"]["name"] = request["name"] = "other-pod"
                    self.assertFalse(
                        self.admits("homelab-test-disruption", request, None, bad), change
                    )
                self.assertFalse(self.admits("homelab-test-disruption", req, None, None))

    def test_disruption_roles_have_only_individual_pod_deletion(self):
        roles = [
            d
            for d in self.documents
            if d["kind"] == "Role" and d["metadata"]["name"] == "homelab-test-disruption"
        ]
        self.assertEqual(
            {d["metadata"]["namespace"] for d in roles},
            {"automation", "media", "portainer", "test-reports", "tailscale"},
        )
        self.assertEqual(len(roles), 5)
        for role in roles:
            self.assertEqual(
                role["rules"], [{"apiGroups": [""], "resources": ["pods"], "verbs": ["delete"]}]
            )
            bindings = [
                d
                for d in self.documents
                if d["kind"] == "RoleBinding" and d["metadata"] == role["metadata"]
            ]
            self.assertEqual(len(bindings), 1)
            self.assertEqual(
                bindings[0]["subjects"],
                [
                    {
                        "kind": "ServiceAccount",
                        "name": "homelab-test-runner",
                        "namespace": "kube-system",
                    }
                ],
            )
        spec = self.policy("homelab-test-disruption")
        self.assertEqual(
            spec["matchConstraints"]["resourceRules"],
            [
                {
                    "apiGroups": [""],
                    "apiVersions": ["v1"],
                    "operations": ["DELETE"],
                    "resources": ["pods"],
                }
            ],
        )

    def test_n8n_application_cannot_select_production_database_or_hooks(self):
        source = (ROOT / "scripts/test/scenarios/n8n-restore-drill.sh").read_text()
        function = source.split("application_manifests() {", 1)[1].split(
            "\nrequest_job_manifest() {", 1
        )[0]
        script = (
            "set -euo pipefail\nrun_hash=0123456789ab\ndeployment=n8n-restore-$run_hash\n"
            "database_name=n8n_restore_$run_hash\napplication_manifests() {"
            + function
            + "\napplication_manifests\n"
        )
        rendered = subprocess.run(
            ["bash", "-c", script], capture_output=True, text=True, check=True, cwd=ROOT
        )
        obj = next(d for d in yaml.safe_load_all(rendered.stdout) if d["kind"] == "Deployment")
        req = self.request("deployments", "automation", name="n8n-restore-0123456789ab")
        req["resource"]["group"] = "apps"
        self.assertEqual(obj["spec"]["replicas"], 1)
        self.assertEqual(obj["spec"]["strategy"]["type"], "Recreate")

        def allowed(candidate):
            return all(
                self.admits(name, req, candidate)
                for name in ("homelab-test-workload-security", "homelab-test-n8n-applications")
            )

        self.assertTrue(allowed(obj))
        for change in (
            "database",
            "secret",
            "image",
            "command",
            "env",
            "probe",
            "identity",
            "token",
            "hostpath",
            "labels",
            "selector",
        ):
            bad = copy.deepcopy(obj)
            ps = bad["spec"]["template"]["spec"]
            app = ps["containers"][0]
            if change == "database":
                next(e for e in app["env"] if e["name"] == "DB_POSTGRESDB_DATABASE")["value"] = (
                    "n8n"
                )
            elif change == "secret":
                next(e for e in app["env"] if e["name"] == "N8N_ENCRYPTION_KEY")["valueFrom"][
                    "secretKeyRef"
                ]["name"] = "other"
            elif change == "image":
                app["image"] = "busybox:latest"
            elif change == "command":
                app["command"] = ["sh", "-c", "env"]
            elif change == "env":
                app["env"].append({"name": "NODE_OPTIONS", "value": "--require=/tmp/injected.js"})
            elif change == "probe":
                app["readinessProbe"] = {"exec": {"command": ["sh", "-c", "env"]}}
            elif change == "identity":
                ps["serviceAccountName"] = "n8n"
            elif change == "token":
                ps["automountServiceAccountToken"] = True
            elif change == "hostpath":
                ps["volumes"][0] = {"name": "data", "hostPath": {"path": "/"}}
            elif change == "labels":
                bad["spec"]["template"]["metadata"]["labels"]["app.kubernetes.io/name"] = "n8n"
            else:
                bad["spec"]["selector"]["matchLabels"] = {"app.kubernetes.io/name": "n8n"}
            with self.subTest(change=change):
                self.assertFalse(allowed(bad))

    def test_n8n_service_cannot_select_production_or_external_endpoint(self):
        req = self.request("services", "automation", name="n8n-restore-0123456789ab")
        obj = {
            "metadata": {
                "name": req["name"],
                "labels": {
                    "homelab-talos/test": "n8n-restore-drill",
                    "homelab-talos/run-id": "0123456789ab",
                    "homelab-talos/role": "n8n",
                },
            },
            "spec": {
                "type": "ClusterIP",
                "selector": {
                    "homelab-talos/test": "n8n-restore-drill",
                    "homelab-talos/run-id": "0123456789ab",
                    "homelab-talos/role": "n8n",
                },
                "ports": [{"name": "http", "port": 5678, "targetPort": "http", "protocol": "TCP"}],
            },
        }
        self.assertTrue(self.admits("homelab-test-services", req, obj))
        for change in (
            "selector",
            "external",
            "nodeport",
            "port",
            "protocol",
            "owner",
            "namespace",
            "annotations",
        ):
            bad, request = copy.deepcopy(obj), copy.deepcopy(req)
            if change == "selector":
                bad["spec"]["selector"] = {"app.kubernetes.io/name": "n8n"}
            elif change == "external":
                bad["spec"]["externalIPs"] = ["192.0.2.1"]
            elif change == "nodeport":
                bad["spec"]["type"] = "NodePort"
            elif change == "port":
                bad["spec"]["ports"][0]["targetPort"] = 5432
            elif change == "protocol":
                bad["spec"]["ports"][0]["protocol"] = "UDP"
            elif change == "owner":
                bad["metadata"]["ownerReferences"] = [
                    {"kind": "Secret", "name": "other", "uid": "synthetic"}
                ]
            elif change == "namespace":
                request["namespace"] = "openbao"
            else:
                bad["metadata"]["annotations"] = {
                    "external-dns.alpha.kubernetes.io/hostname": "outside.example"
                }
            with self.subTest(change=change):
                self.assertFalse(self.admits("homelab-test-services", request, bad))
        self.assertFalse(
            self.admits("homelab-test-services", {**req, "operation": "UPDATE"}, obj, obj)
        )
        self.assertTrue(
            self.admits("homelab-test-services", {**req, "operation": "DELETE"}, None, obj)
        )

    def test_n8n_network_policy_cannot_widen_peers_or_selectors(self):
        source = (ROOT / "scripts/test/scenarios/n8n-restore-drill.sh").read_text()
        function = source.split("policy_manifest() {", 1)[1].split(
            "\ndatabase_job_manifest() {", 1
        )[0]
        script = (
            "set -euo pipefail\nrun_hash=0123456789ab\n"
            "automation_policy=n8n-restore-$run_hash-automation\nrequest_policy=n8n-restore-$run_hash-request\n"
            "policy_manifest() {" + function + "\npolicy_manifest\n"
        )
        rendered = subprocess.run(
            ["bash", "-c", script], capture_output=True, text=True, check=True, cwd=ROOT
        )
        policies = list(yaml.safe_load_all(rendered.stdout))
        self.assertEqual(len(policies), 2)
        for obj in policies:
            req = self.request(
                "ciliumnetworkpolicies", obj["metadata"]["namespace"], name=obj["metadata"]["name"]
            )
            req["resource"].update({"group": "cilium.io", "version": "v2"})
            self.assertTrue(self.admits("homelab-test-network-policies", req, obj))
            self.assertTrue(
                self.admits(
                    "homelab-test-network-policies", {**req, "operation": "DELETE"}, None, obj
                )
            )
            self.assertFalse(
                self.admits(
                    "homelab-test-network-policies", {**req, "operation": "UPDATE"}, obj, obj
                )
            )
            for change in (
                "selector",
                "world",
                "port",
                "peer",
                "requires",
                "default-deny",
                "tls",
                "rule",
            ):
                bad = copy.deepcopy(obj)
                rule = bad["specs"][0] if "specs" in bad else bad["spec"]
                if change == "selector":
                    rule["endpointSelector"] = {"matchLabels": {}}
                elif change == "world":
                    rule["egress"][0] = {"toEntities": ["world"]}
                elif change == "port":
                    rule["egress"][0]["toPorts"][0]["ports"][0]["port"] = "443"
                elif change == "peer":
                    rule["egress"][0]["toEndpoints"][0]["matchLabels"] = {}
                elif change == "requires":
                    rule["egress"][0]["toRequires"] = [{"matchLabels": {"app": "other"}}]
                elif change == "default-deny":
                    rule["enableDefaultDeny"] = {"egress": False}
                elif change == "tls":
                    rule["egress"][0]["toPorts"][0]["terminatingTLS"] = {
                        "secret": {"namespace": "automation", "name": "other-secret"}
                    }
                else:
                    bad.setdefault("specs", []).append(copy.deepcopy(rule))
                with self.subTest(namespace=req["namespace"], change=change):
                    self.assertFalse(self.admits("homelab-test-network-policies", req, bad))

    def test_n8n_fixture_grants_are_namespace_and_resource_limited(self):
        expected = {
            ("homelab-test-application-fixtures", "automation"): [
                {
                    "apiGroups": ["apps"],
                    "resources": ["deployments"],
                    "verbs": ["create", "delete"],
                },
                {"apiGroups": [""], "resources": ["services"], "verbs": ["create", "delete"]},
            ],
            ("homelab-test-network-policies", "automation"): [
                {
                    "apiGroups": ["cilium.io"],
                    "resources": ["ciliumnetworkpolicies"],
                    "verbs": ["create", "delete"],
                }
            ],
            ("homelab-test-network-policies", "gatus"): [
                {
                    "apiGroups": ["cilium.io"],
                    "resources": ["ciliumnetworkpolicies"],
                    "verbs": ["create", "delete"],
                }
            ],
        }
        for (name, namespace), rules in expected.items():
            roles = [
                d
                for d in self.documents
                if d["kind"] == "Role" and d["metadata"] == {"name": name, "namespace": namespace}
            ]
            self.assertEqual(len(roles), 1)
            self.assertEqual(roles[0]["rules"], rules)
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
                        "name": "homelab-test-runner",
                        "namespace": "kube-system",
                    }
                ],
            )

    def test_publisher_and_coordinator_do_not_inherit_test_or_observer_grants(self):
        allowed = {
            "homelab-report-publisher": {
                "homelab-report-publisher-flux-system",
                "homelab-report-publisher-test-reports",
            },
            "homelab-campaign-coordinator": {"homelab-campaign-coordinator"},
        }
        for account, refs in allowed.items():
            bindings = [
                d
                for d in self.documents
                if d["kind"] in {"RoleBinding", "ClusterRoleBinding"}
                and any(
                    s.get("name") == account and s.get("namespace") == "kube-system"
                    for s in d.get("subjects", [])
                )
            ]
            self.assertEqual({d["roleRef"]["name"] for d in bindings}, refs)
            self.assertTrue(all(d["roleRef"]["kind"] == "Role" for d in bindings))

    def test_flux_canary_keeps_named_encrypted_secret_recreation(self):
        roles = [
            d
            for d in self.documents
            if d["kind"] == "Role"
            and d["metadata"] == {"name": "homelab-test-flux-canary", "namespace": "flux-system"}
        ]
        self.assertEqual(len(roles), 1)
        self.assertEqual(
            roles[0]["rules"],
            [
                {
                    "apiGroups": [""],
                    "resources": ["secrets"],
                    "resourceNames": ["flux-canary"],
                    "verbs": ["get", "delete"],
                }
            ],
        )
        canary = yaml.safe_load(
            (ROOT / "kubernetes/apps/flux-system/flux-canary/app/secret.sops.yaml").read_text()
        )
        self.assertEqual(canary["kind"], "Secret")
        self.assertEqual(canary["metadata"]["name"], "flux-canary")
        self.assertIn("sops", canary)
        self.assertTrue(canary["stringData"]["marker"].startswith("ENC["))
        recipe = (
            (ROOT / "kubernetes/mod.just")
            .read_text()
            .split("_flux-canary-test-raw: flux-verify", 1)[1]
            .split("\n# Validate the Longhorn", 1)[0]
        )
        self.assertIn('"$new_uid" != "$old_uid"', recipe)
        self.assertIn("delete secret flux-canary", recipe)
        self.assertIn("--with-source", recipe)

    def test_flux_alert_fixture_cannot_choose_a_real_source_or_privileged_fields(self):
        name = "flux-alert-e2e-20261002120000-12345"
        req = self.request("kustomizations", "flux-system", name=name)
        req["resource"]["group"] = "kustomize.toolkit.fluxcd.io"
        obj = {
            "metadata": {"name": name, "labels": {"homelab-talos/test": "flux-alert-delivery"}},
            "spec": {
                "interval": "1m",
                "retryInterval": "30s",
                "timeout": "30s",
                "prune": False,
                "wait": True,
                "path": "./.homelab-talos-tests/" + name,
                "sourceRef": {
                    "apiVersion": "source.toolkit.fluxcd.io/v1",
                    "kind": "GitRepository",
                    "name": name + "-source-does-not-exist",
                },
            },
        }
        self.assertTrue(self.admits("homelab-test-flux-fixtures", req, obj))
        for change in (
            "source",
            "path",
            "serviceaccount",
            "decryption",
            "kubeconfig",
            "patches",
            "postbuild",
            "target",
            "prune",
            "owner",
            "namespace",
        ):
            bad, request = copy.deepcopy(obj), copy.deepcopy(req)
            if change == "source":
                bad["spec"]["sourceRef"]["name"] = "flux-system"
            elif change == "path":
                bad["spec"]["path"] = "./kubernetes/apps"
            elif change == "serviceaccount":
                bad["spec"]["serviceAccountName"] = "kustomize-controller"
            elif change == "decryption":
                bad["spec"]["decryption"] = {"provider": "sops", "secretRef": {"name": "sops-age"}}
            elif change == "kubeconfig":
                bad["spec"]["kubeConfig"] = {"secretRef": {"name": "other"}}
            elif change == "patches":
                bad["spec"]["patches"] = [{"patch": "{}"}]
            elif change == "postbuild":
                bad["spec"]["postBuild"] = {
                    "substituteFrom": [{"kind": "Secret", "name": "other"}]
                }
            elif change == "target":
                bad["spec"]["targetNamespace"] = "openbao"
            elif change == "prune":
                bad["spec"]["prune"] = True
            elif change == "owner":
                bad["metadata"]["ownerReferences"] = [
                    {"kind": "Secret", "name": "other", "uid": "synthetic"}
                ]
            else:
                request["namespace"] = "openbao"
            with self.subTest(change=change):
                self.assertFalse(self.admits("homelab-test-flux-fixtures", request, bad))
        deleting = copy.deepcopy(obj)
        deleting["metadata"]["finalizers"] = ["finalizers.fluxcd.io"]
        self.assertTrue(
            self.admits(
                "homelab-test-flux-fixtures", {**req, "operation": "DELETE"}, None, deleting
            )
        )

    def test_flux_reconciliation_changes_only_named_request_annotation(self):
        for group, resource, name in (
            ("source.toolkit.fluxcd.io", "gitrepositories", "flux-system"),
            ("kustomize.toolkit.fluxcd.io", "kustomizations", "flux-canary"),
        ):
            req = self.request(resource, "flux-system", "UPDATE", name)
            req["resource"]["group"] = group
            old = {
                "metadata": {
                    "name": name,
                    "namespace": "flux-system",
                    "labels": {"app": "fixture"},
                    "annotations": {"fixture.example/keep": "fixed"},
                    "finalizers": ["finalizers.fluxcd.io"],
                },
                "spec": {"interval": "1m"},
            }
            obj = copy.deepcopy(old)
            obj["metadata"]["annotations"]["reconcile.fluxcd.io/requestedAt"] = (
                "2026-10-02T12:00:00.123456789-06:00"
            )
            self.assertTrue(self.admits("homelab-test-flux-reconcile", req, obj, old))
            for change in (
                "spec",
                "labels",
                "finalizers",
                "annotation",
                "remove",
                "timestamp",
                "name",
                "namespace",
            ):
                bad, request = copy.deepcopy(obj), copy.deepcopy(req)
                if change == "spec":
                    bad["spec"]["interval"] = "1s"
                elif change == "labels":
                    bad["metadata"]["labels"]["app"] = "other"
                elif change == "finalizers":
                    bad["metadata"]["finalizers"] = []
                elif change == "annotation":
                    bad["metadata"]["annotations"]["fixture.example/keep"] = "other"
                elif change == "remove":
                    del bad["metadata"]["annotations"]["fixture.example/keep"]
                elif change == "timestamp":
                    bad["metadata"]["annotations"]["reconcile.fluxcd.io/requestedAt"] = "payload"
                elif change == "name":
                    bad["metadata"]["name"] = request["name"] = "other"
                else:
                    request["namespace"] = "openbao"
                with self.subTest(group=group, change=change):
                    self.assertFalse(self.admits("homelab-test-flux-reconcile", request, bad, old))
