"""Independent request cases for the fixed, isolated OpenBao restore fixture."""

import copy
import subprocess
import unittest
from pathlib import Path

import yaml

from scripts.test.core import test_dedicated_profiles as helpers

ROOT = Path(__file__).resolve().parents[3]
NS = "openbao-restore-test"
OWNER = "homelab.supermorphic.com/test-run"
IDENTITY = "system:serviceaccount:kube-system:homelab-test-openbao-restore"


class RestoreAccessTests(unittest.TestCase):
    setUpClass = classmethod(helpers.DedicatedFluxMutationTests.setUpClass.__func__)
    policy = helpers.DedicatedFluxMutationTests.policy
    evaluate = helpers.DedicatedFluxMutationTests.evaluate
    admits = helpers.DedicatedFluxMutationTests.admits

    def request(self, obj, operation="CREATE", subresource=""):
        resources = {
            "StatefulSet": "statefulsets",
            "PersistentVolumeClaim": "persistentvolumeclaims",
            "Secret": "secrets",
            "ConfigMap": "configmaps",
            "Pod": "pods",
        }
        return {
            "operation": operation,
            "namespace": NS,
            "name": obj["metadata"]["name"],
            "resource": {
                "group": "apps" if obj["kind"] == "StatefulSet" else "",
                "version": "v1",
                "resource": resources[obj["kind"]],
            },
            "subResource": subresource,
            "userInfo": {"username": IDENTITY},
        }

    def workload(self, name):
        obj = yaml.safe_load((ROOT / f"tests/fixtures/openbao/restore/{name}.yaml").read_text())
        obj["metadata"].update(namespace=NS, annotations={OWNER: "synthetic-run"})
        if name == "statefulset":
            obj["spec"]["template"]["metadata"]["annotations"] = {OWNER: "synthetic-run"}
        return obj

    def test_fixed_baseline_has_no_scratch_account_authority(self):
        unit = yaml.safe_load(
            (ROOT / "kubernetes/apps/kube-system/agent-access/ks.yaml").read_text()
        )
        self.assertIn({"name": "openbao-restore-test"}, unit["spec"]["dependsOn"])
        path = ROOT / "kubernetes/apps/security/openbao/restore-test"
        result = subprocess.run(
            ["kustomize", "build", str(path)], capture_output=True, text=True, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        docs = list(yaml.safe_load_all(result.stdout))
        from scripts.openbao.manifests import validate_restore_baseline

        self.assertEqual(validate_restore_baseline(docs), [])
        for kind, field, value in (
            ("Namespace", "name", "other"),
            ("ServiceAccount", "automountServiceAccountToken", True),
            ("ServiceAccount", "secrets", [{"name": "other"}]),
            ("CiliumNetworkPolicy", "spec", {"endpointSelector": {}}),
        ):
            bad = copy.deepcopy(docs)
            target = next(d for d in bad if d["kind"] == kind)
            if field == "name":
                target["metadata"][field] = value
            else:
                target[field] = value
            self.assertEqual(validate_restore_baseline(bad), ["restore-baseline"])
        self.assertEqual(validate_restore_baseline(docs + [docs[0]]), ["restore-baseline"])
        self.assertEqual(
            {(d["kind"], d["metadata"]["name"]) for d in docs},
            {
                ("Namespace", NS),
                ("ServiceAccount", "scratch"),
                ("CiliumNetworkPolicy", "scratch-isolation"),
            },
        )
        account = next(d for d in docs if d["kind"] == "ServiceAccount")
        self.assertEqual(account["metadata"]["namespace"], NS)
        self.assertIs(account["automountServiceAccountToken"], False)
        self.assertNotIn("secrets", account)
        policy = next(d for d in docs if d["kind"] == "CiliumNetworkPolicy")
        self.assertEqual(
            policy["spec"],
            {
                "endpointSelector": {},
                "ingressDeny": [{"fromEntities": ["all"]}],
                "egressDeny": [{"toEntities": ["all"]}],
            },
        )
        self.assertEqual(
            next(d for d in docs if d["kind"] == "Namespace")["metadata"]["labels"][
                "pod-security.kubernetes.io/enforce"
            ],
            "restricted",
        )

    def test_restore_grants_are_confined_to_the_fixed_scratch_namespace(self):
        roles = [
            d
            for d in self.documents
            if d["kind"] == "Role"
            and d["metadata"]["name"] == "homelab-test-openbao-restore-runtime"
        ]
        self.assertEqual(len(roles), 1)
        self.assertEqual(roles[0]["metadata"]["namespace"], NS)
        self.assertEqual(
            roles[0]["rules"],
            [
                {"apiGroups": ["apps"], "resources": ["statefulsets"], "verbs": ["create"]},
                {
                    "apiGroups": ["apps"],
                    "resources": ["statefulsets"],
                    "resourceNames": ["scratch"],
                    "verbs": ["delete"],
                },
                {
                    "apiGroups": [""],
                    "resources": ["persistentvolumeclaims", "secrets", "configmaps"],
                    "verbs": ["create"],
                },
                {
                    "apiGroups": [""],
                    "resources": ["persistentvolumeclaims"],
                    "resourceNames": ["scratch-data"],
                    "verbs": ["delete"],
                },
                {
                    "apiGroups": [""],
                    "resources": ["secrets"],
                    "resourceNames": ["scratch-seal"],
                    "verbs": ["get", "delete"],
                },
                {"apiGroups": [""], "resources": ["secrets"], "verbs": ["list"]},
                {
                    "apiGroups": [""],
                    "resources": ["configmaps"],
                    "resourceNames": ["scratch-config"],
                    "verbs": ["delete"],
                },
                {
                    "apiGroups": [""],
                    "resources": ["pods"],
                    "resourceNames": ["scratch-0"],
                    "verbs": ["delete"],
                },
                {
                    "apiGroups": [""],
                    "resources": ["pods/exec"],
                    "resourceNames": ["scratch-0"],
                    "verbs": ["get", "create"],
                },
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
                    "name": "homelab-test-openbao-restore",
                    "namespace": "kube-system",
                }
            ],
        )
        self.assertEqual(
            binding["roleRef"],
            {
                "apiGroup": "rbac.authorization.k8s.io",
                "kind": "Role",
                "name": "homelab-test-openbao-restore-runtime",
            },
        )

    def test_only_the_owned_scratch_controller_pod_can_be_restarted(self):
        obj = {
            "apiVersion": "v1",
            "kind": "Pod",
            "metadata": {
                "name": "scratch-0",
                "namespace": NS,
                "uid": "pod-fixture",
                "labels": {"app": "openbao-restore-scratch"},
                "annotations": {OWNER: "synthetic-run"},
                "ownerReferences": [
                    {
                        "apiVersion": "apps/v1",
                        "kind": "StatefulSet",
                        "name": "scratch",
                        "uid": "sts-fixture",
                        "controller": True,
                    }
                ],
            },
        }
        req = self.request(obj, "DELETE")
        policy = "homelab-test-openbao-restore-pod-delete"
        self.assertTrue(self.admits(policy, req, None, obj))
        for path, value in (
            (("metadata", "uid"), ""),
            (("metadata", "annotations", OWNER), ""),
            (("metadata", "ownerReferences", 0, "name"), "production"),
            (("metadata", "ownerReferences", 0, "uid"), ""),
            (("metadata", "ownerReferences", 0, "controller"), False),
        ):
            bad = copy.deepcopy(obj)
            parent = bad
            for key in path[:-1]:
                parent = parent[key]
            parent[path[-1]] = value
            self.assertFalse(self.admits(policy, req, None, bad))
        self.assertFalse(self.admits(policy, {**req, "namespace": "openbao"}, None, obj))

    def test_known_api_defaults_preserve_the_canonical_scratch_workload(self):
        obj = self.workload("statefulset")
        obj["spec"].update(
            podManagementPolicy="OrderedReady",
            revisionHistoryLimit=10,
            persistentVolumeClaimRetentionPolicy={"whenDeleted": "Retain", "whenScaled": "Retain"},
        )
        obj["spec"]["template"]["metadata"]["creationTimestamp"] = None
        pod = obj["spec"]["template"]["spec"]
        pod.update(
            dnsPolicy="ClusterFirst",
            schedulerName="default-scheduler",
            restartPolicy="Always",
            terminationGracePeriodSeconds=30,
            serviceAccount="scratch",
        )
        for c in pod["containers"]:
            c.update(
                imagePullPolicy="IfNotPresent",
                terminationMessagePath="/dev/termination-log",
                terminationMessagePolicy="File",
            )
            c["securityContext"].update(privileged=False, procMount="Default")
        pod["volumes"][2]["configMap"]["defaultMode"] = 420
        self.assertTrue(
            self.admits("homelab-test-openbao-restore-statefulset", self.request(obj), obj)
        )
        pod["containers"][1]["securityContext"]["privileged"] = True
        self.assertFalse(
            self.admits("homelab-test-openbao-restore-statefulset", self.request(obj), obj)
        )

    def test_restore_workload_rejects_alternate_storage_identity_and_programs(self):
        sts = self.workload("statefulset")
        req = self.request(sts)
        self.assertTrue(self.admits("homelab-test-openbao-restore-statefulset", req, sts))
        paths = [
            ("spec", "replicas"),
            ("spec", "serviceName"),
            ("spec", "template", "spec", "serviceAccountName"),
            ("spec", "template", "spec", "automountServiceAccountToken"),
            ("spec", "template", "spec", "containers", 0, "image"),
            ("spec", "template", "spec", "containers", 0, "command"),
            ("spec", "template", "spec", "containers", 1, "command"),
            ("spec", "template", "spec", "volumes", 0, "persistentVolumeClaim", "claimName"),
            ("spec", "template", "spec", "volumes", 1, "secret", "secretName"),
        ]
        for path in paths:
            bad = copy.deepcopy(sts)
            parent = bad
            for key in path[:-1]:
                parent = parent[key]
            parent[path[-1]] = (
                2
                if path[-1] == "replicas"
                else True
                if path[-1] == "automountServiceAccountToken"
                else "unrelated"
            )
            with self.subTest(path=path):
                self.assertFalse(self.admits("homelab-test-openbao-restore-statefulset", req, bad))
        for key, value in (
            ("hostNetwork", True),
            ("nodeName", "fixture-node"),
            ("initContainers", [{"name": "extra", "image": "other"}]),
            ("imagePullSecrets", [{"name": "other"}]),
            ("hostAliases", []),
        ):
            bad = copy.deepcopy(sts)
            bad["spec"]["template"]["spec"][key] = value
            self.assertFalse(self.admits("homelab-test-openbao-restore-statefulset", req, bad))
        for key, value in (
            ("namespace", "openbao"),
            ("subResource", "scale"),
            ("name", "production"),
        ):
            self.assertFalse(
                self.admits("homelab-test-openbao-restore-statefulset", {**req, key: value}, sts)
            )
        self.assertFalse(
            self.admits(
                "homelab-test-openbao-restore-statefulset",
                {**req, "operation": "UPDATE"},
                sts,
                sts,
            )
        )
        stored = copy.deepcopy(sts)
        stored["metadata"]["uid"] = "fixture-uid"
        self.assertTrue(
            self.admits(
                "homelab-test-openbao-restore-statefulset",
                self.request(stored, "DELETE"),
                None,
                stored,
            )
        )
        stored["metadata"]["annotations"][OWNER] = ""
        self.assertFalse(
            self.admits(
                "homelab-test-openbao-restore-statefulset",
                self.request(stored, "DELETE"),
                None,
                stored,
            )
        )

    def test_restore_claim_is_fresh_bounded_longhorn_storage(self):
        pvc = self.workload("pvc")
        req = self.request(pvc)
        self.assertTrue(self.admits("homelab-test-openbao-restore-storage", req, pvc))
        for key, value in (
            ("storageClassName", "other"),
            ("volumeName", "existing"),
            ("dataSource", {"name": "existing", "kind": "PersistentVolumeClaim"}),
            ("dataSourceRef", {"name": "existing", "kind": "PersistentVolumeClaim"}),
            ("selector", {}),
            ("accessModes", ["ReadWriteMany"]),
        ):
            bad = copy.deepcopy(pvc)
            bad["spec"][key] = value
            self.assertFalse(self.admits("homelab-test-openbao-restore-storage", req, bad))
        bad = copy.deepcopy(pvc)
        bad["spec"]["resources"]["requests"]["storage"] = "100Gi"
        self.assertFalse(self.admits("homelab-test-openbao-restore-storage", req, bad))
        stored = copy.deepcopy(pvc)
        stored["metadata"]["uid"] = "fixture-uid"
        stored["spec"].update(volumeName="pvc-fixture-uid", volumeMode="Filesystem")
        self.assertTrue(
            self.admits(
                "homelab-test-openbao-restore-storage",
                self.request(stored, "DELETE"),
                None,
                stored,
            )
        )

    def test_restore_secret_and_config_are_named_immutable_and_loopback_only(self):
        config = (ROOT / "tests/fixtures/openbao/restore/server.hcl").read_text()
        for seal_id in ("fixture-seal", "fixture.seal_2"):
            cm = {
                "apiVersion": "v1",
                "kind": "ConfigMap",
                "metadata": {
                    "name": "scratch-config",
                    "namespace": NS,
                    "annotations": {OWNER: "synthetic-run"},
                },
                "immutable": True,
                "data": {"server.hcl": config.replace("SEAL_ID", seal_id)},
            }
            req = self.request(cm)
            self.assertTrue(self.admits("homelab-test-openbao-restore-private", req, cm))
            for text in (
                cm["data"]["server.hcl"].replace("127.0.0.1", "0.0.0.0"),
                cm["data"]["server.hcl"].replace('log_raw = "false"', 'log_raw = "true"'),
                cm["data"]["server.hcl"] + '\nseal "other" {}\n',
            ):
                bad = copy.deepcopy(cm)
                bad["data"]["server.hcl"] = text
                self.assertFalse(self.admits("homelab-test-openbao-restore-private", req, bad))
        secret = {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {
                "name": "scratch-seal",
                "namespace": NS,
                "annotations": {OWNER: "synthetic-run"},
            },
            "immutable": True,
            "type": "Opaque",
            "data": {"key": "c3ludGhldGlj"},
        }
        req = self.request(secret)
        self.assertTrue(self.admits("homelab-test-openbao-restore-private", req, secret))
        for key, value in (
            ("immutable", False),
            ("type", "kubernetes.io/service-account-token"),
            ("data", {"key": "c3ludGhldGlj", "other": "c3ludGhldGlj"}),
            ("stringData", {"other": "synthetic"}),
        ):
            self.assertFalse(
                self.admits("homelab-test-openbao-restore-private", req, {**secret, key: value})
            )

    def test_scratch_exec_cannot_change_program_container_or_target(self):
        from scripts.test.scenarios.openbao_restore import BRIDGE, PROBE

        req = {
            "operation": "CONNECT",
            "namespace": NS,
            "name": "scratch-0",
            "subResource": "exec",
            "resource": {"group": "", "version": "v1", "resource": "pods"},
            "userInfo": {"username": IDENTITY},
        }
        for program in (BRIDGE, PROBE):
            obj = {
                "container": "runner",
                "command": ["python", "-c", program],
                "stdin": True,
                "stdout": True,
                "stderr": True,
                "tty": False,
            }
            self.assertTrue(self.admits("homelab-test-openbao-restore-exec", req, obj))
            for key, value in (
                ("container", "server"),
                ("command", ["sh"]),
                ("tty", True),
                ("stdin", False),
            ):
                self.assertFalse(
                    self.admits("homelab-test-openbao-restore-exec", req, {**obj, key: value})
                )
            self.assertFalse(
                self.admits(
                    "homelab-test-openbao-restore-exec", {**req, "namespace": "openbao"}, obj
                )
            )


if __name__ == "__main__":
    unittest.main()
