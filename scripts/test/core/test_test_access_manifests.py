"""Independent request fixtures exercise the CEL shipped to Kubernetes."""

import copy
import json
import os
import subprocess
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
        rendered = subprocess.run(
            ["kustomize", "build", str(PACKAGE)], capture_output=True, text=True, check=True
        )
        cls.documents = list(yaml.safe_load_all(rendered.stdout))
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

    def admits(self, policy_name, request, obj, old=None):
        spec = self.policy(policy_name)
        activation = {
            "request": json_to_cel(request),
            "object": json_to_cel(obj),
            "oldObject": json_to_cel(old),
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
            {"n8n-restore-common.sh", "n8n-restore-load.sh", "n8n-restore-drop.sh"},
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
