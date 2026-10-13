"""Run the actual observational and server-dry-run commands against synthetic responses."""

import copy
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.test.core.test_application_boundary import PLATFORM, ROOT, render


class ApplicationCommandTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        (self.path / "config").touch()
        (self.path / "kubectl").symlink_to(
            ROOT / "tests/fixtures/application-boundary/fake-kubectl.py"
        )
        self.objects = {}
        for doc in (
            render(PLATFORM)
            + render(PLATFORM.parent / "fixture-storage")
            + render(ROOT / "kubernetes/apps/applications")
        ):
            obj = copy.deepcopy(doc)
            obj["metadata"]["generation"] = 1
            obj["status"] = {
                "observedGeneration": 1,
                "typeChecking": {},
                "conditions": [{"type": "Ready", "status": "True", "observedGeneration": 1}],
            }
            if obj["kind"] == "CiliumNetworkPolicy":
                obj["status"]["conditions"] = [{"type": "Valid", "status": "True"}]
            self.objects[obj["kind"].lower() + "/" + obj["metadata"]["name"]] = obj
        for obj in self.objects.values():
            if obj["kind"] != "PersistentVolumeClaim":
                continue
            name = obj["metadata"]["name"]
            obj["metadata"]["uid"] = "synthetic-" + name
            obj["spec"]["volumeName"] = "synthetic-volume-" + name
            obj["status"]["phase"] = "Bound"
        for claim in list(self.objects.values()):
            if claim["kind"] == "PersistentVolumeClaim":
                name = claim["spec"]["volumeName"]
                self.objects["persistentvolume/" + name] = {
                    "apiVersion": "v1",
                    "kind": "PersistentVolume",
                    "metadata": {"name": name},
                    "spec": {
                        "persistentVolumeReclaimPolicy": "Retain",
                        "storageClassName": "career-ops-retain",
                        "claimRef": {"uid": claim["metadata"]["uid"]},
                        "csi": {"driver": "driver.longhorn.io"},
                    },
                }
        self.objects["deployment/kustomize-controller"] = {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {"name": "kustomize-controller", "namespace": "flux-system"},
            "spec": {
                "template": {
                    "spec": {
                        "containers": [{"name": "manager", "args": ["--no-remote-bases=true"]}]
                    }
                }
            },
        }
        self.environment = {
            **os.environ,
            "PATH": str(self.path) + os.pathsep + os.environ["PATH"],
            "APPLICATION_BOUNDARY_FIXTURE_DATA": str(self.path),
            "APPLICATION_BOUNDARY_FIXTURE_IDENTITY": "system:serviceaccount:kube-system:homelab-observer",
        }

    def run_command(self, scenario=False):
        (self.path / "objects.json").write_text(json.dumps(self.objects))
        if scenario:
            self.environment.update(
                APPLICATION_BOUNDARY_FIXTURE_IDENTITY="system:serviceaccount:kube-system:homelab-test-runner",
                APPLICATION_BOUNDARY_TEST_CONFIRM="test:application-boundary:server-admission",
            )
        relative = (
            "scripts/test/scenarios/application-boundary.sh"
            if scenario
            else "scripts/verify/application-boundary.sh"
        )
        return subprocess.run(
            ["bash", str(ROOT / relative), str(self.path / "config")],
            cwd=ROOT,
            env=self.environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def calls(self):
        return [json.loads(line) for line in (self.path / "calls.jsonl").read_text().splitlines()]

    def test_observational_verifier_reports_suspended_enrollment(self):
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("enrollment suspended", result.stdout)
        self.assertTrue(all(c[0] in ["get", "auth"] for c in self.calls()))
        self.assertFalse(any("secret" in c[1].lower() for c in self.calls() if c[0] == "get"))

    def test_observer_accepts_api_defaulted_limit_range_but_rejects_changed_defaults(self):
        limit = self.objects["limitrange/career-ops-container-bounds"]["spec"]["limits"][0]
        limit["default"] = copy.deepcopy(limit["max"])
        limit["defaultRequest"] = copy.deepcopy(limit["max"])
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        limit["defaultRequest"]["cpu"] = "1"
        result = self.run_command()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from the reviewed source", result.stderr)

    def test_observation_rejects_controller_without_remote_base_guard(self):
        self.objects["deployment/kustomize-controller"]["spec"]["template"]["spec"]["containers"][
            0
        ]["args"] = []
        result = self.run_command()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("remote bases", result.stderr)

    def test_observer_checks_bound_fixture_volume_identity_and_retention(self):
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        volume = next(obj for obj in self.objects.values() if obj["kind"] == "PersistentVolume")
        volume["spec"]["persistentVolumeReclaimPolicy"] = "Delete"
        result = self.run_command()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture volume", result.stderr)

    def test_observer_preserves_monitor_check_when_storage_is_a_separate_root(self):
        monitor = self.objects["servicemonitor/career-ops-coordinator"]
        monitor["spec"]["endpoints"][0]["path"] = "/wrong-metrics"
        result = self.run_command()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ServiceMonitor/career-ops-coordinator", result.stderr)

    def test_observation_detects_added_admission_exemptions(self):
        policy = self.objects["validatingadmissionpolicy/career-ops-workloads"]
        policy["spec"]["matchConditions"] = [{"name": "bypass", "expression": "false"}]
        result = self.run_command()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from the reviewed source", result.stderr)

    def test_observation_rejects_stale_type_checking(self):
        self.objects["validatingadmissionpolicy/career-ops-workloads"]["status"][
            "observedGeneration"
        ] = 0
        result = self.run_command()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("type checking is incomplete", result.stderr)

    def test_observation_rejects_invalid_or_unvalidated_cilium_policy(self):
        policy = self.objects["ciliumnetworkpolicy/career-ops-deny"]
        for status in [{}, {"conditions": [{"type": "Valid", "status": "False"}]}]:
            policy["status"] = status
            result = self.run_command()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Cilium policy", result.stderr)

    def test_observation_rejects_elevated_identity(self):
        self.environment["APPLICATION_BOUNDARY_FIXTURE_IDENTITY"] = "operator-admin"
        result = self.run_command()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("scoped observer", result.stderr)

    def test_scenario_uses_server_dry_run_and_fresh_scope_checks(self):
        result = self.run_command(scenario=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        requests = [i for i, c in enumerate(calls) if c[0] == "create"]
        self.assertEqual(len(requests), 7)
        for i in requests:
            self.assertIn("--dry-run=server", calls[i])
            self.assertEqual(
                {c[1] for c in calls[i - 4 : i]},
                {
                    "Role",
                    "RoleBinding",
                    "ValidatingAdmissionPolicy",
                    "ValidatingAdmissionPolicyBinding",
                },
            )
        self.assertIn("No resources persisted", result.stdout)

    def test_scenario_does_not_count_authorization_failure_as_policy_denial(self):
        self.environment["APPLICATION_BOUNDARY_FIXTURE_DENIAL"] = (
            "Error from server (Forbidden): RBAC authorization denied"
        )
        result = self.run_command(scenario=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not identify the intended", result.stderr)

    def test_scenario_accepts_invalid_status_from_the_intended_admission_policy(self):
        self.environment["APPLICATION_BOUNDARY_FIXTURE_DENIAL"] = (
            'The jobs "career-ops-boundary-admission" is invalid: '
            "ValidatingAdmissionPolicy 'career-ops-workloads' with binding "
            "'career-ops-workloads' denied request: Host networking is forbidden."
        )
        result = self.run_command(scenario=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_scenario_rejects_a_different_policy_with_a_similar_name(self):
        self.environment["APPLICATION_BOUNDARY_FIXTURE_DENIAL"] = (
            "Error from server (Forbidden): ValidatingAdmissionPolicy "
            "'career-ops-workloads-other' denied request"
        )
        result = self.run_command(scenario=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not identify the intended", result.stderr)

    def test_scenario_stops_before_request_when_scope_policy_changed(self):
        self.objects["validatingadmissionpolicy/career-ops-boundary-test"]["spec"]["validations"][
            0
        ]["expression"] = "true"
        result = self.run_command(scenario=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] == "create" for c in self.calls()))

    def native_runner(self):
        from scripts.test.scenarios.application_boundary_native import NativeRunner, job

        runner = NativeRunner(self.path / "config")
        self.addCleanup(__import__("shutil").rmtree, runner.directory)
        runner.templates = {
            mode: job(mode, runner.run, ["192.0.2.1", "192.0.2.2", "192.0.2.3"])
            for mode in ["seed", "write", "read", "cleanup"]
        }
        for name in ["career-ops-platform", "career-ops-fixture-storage"]:
            self.objects["kustomization/" + name]["status"]["lastAppliedRevision"] = (
                "main@sha1:" + runner.revision
            )
        (self.path / "objects.json").write_text(json.dumps(self.objects))
        return runner

    def test_native_create_stops_before_mutation_when_scope_changes(self):
        self.environment["APPLICATION_BOUNDARY_FIXTURE_IDENTITY"] = (
            "system:serviceaccount:kube-system:homelab-test-runner"
        )
        with patch.dict(os.environ, self.environment):
            runner = self.native_runner()
            self.objects["role/career-ops-boundary-test"]["rules"][0]["verbs"].append("patch")
            (self.path / "objects.json").write_text(json.dumps(self.objects))
            with self.assertRaisesRegex(RuntimeError, "controls differ"):
                runner.mutate_owned("create", "seed")
        self.assertTrue(all(c[0] in {"get", "auth"} for c in self.calls()))

    def test_native_delete_stops_if_a_fixture_claim_was_replaced(self):
        self.environment["APPLICATION_BOUNDARY_FIXTURE_IDENTITY"] = (
            "system:serviceaccount:kube-system:homelab-test-runner"
        )
        with patch.dict(os.environ, self.environment):
            runner = self.native_runner()
            runner.precondition()
            claim = self.objects["persistentvolumeclaim/career-ops-boundary-requests"]
            claim["metadata"]["uid"] = "synthetic-replacement"
            self.objects["persistentvolume/" + claim["spec"]["volumeName"]]["spec"]["claimRef"][
                "uid"
            ] = "synthetic-replacement"
            (self.path / "objects.json").write_text(json.dumps(self.objects))
            with self.assertRaisesRegex(RuntimeError, "claim identity changed"):
                runner.mutate_owned("delete", "seed")
        self.assertTrue(all(c[0] in {"get", "auth"} for c in self.calls()))

    def test_native_precondition_rejects_a_different_credential_identity(self):
        with patch.dict(os.environ, self.environment):
            runner = self.native_runner()
            with self.assertRaisesRegex(RuntimeError, "selected test-runner"):
                runner.precondition()

    def test_native_precondition_requires_current_ready_fixture_storage(self):
        self.environment["APPLICATION_BOUNDARY_FIXTURE_IDENTITY"] = (
            "system:serviceaccount:kube-system:homelab-test-runner"
        )
        with patch.dict(os.environ, self.environment):
            runner = self.native_runner()
            fixture = self.objects.setdefault(
                "kustomization/career-ops-fixture-storage",
                {
                    "metadata": {"generation": 1},
                    "status": {},
                },
            )
            for status in [
                {"lastAppliedRevision": "main@sha1:" + "0" * 40},
                {
                    "lastAppliedRevision": "main@sha1:" + runner.revision,
                    "observedGeneration": 1,
                    "conditions": [{"type": "Ready", "status": "False", "observedGeneration": 1}],
                },
            ]:
                fixture["status"] = status
                (self.path / "objects.json").write_text(json.dumps(self.objects))
                with self.assertRaisesRegex(RuntimeError, "exact deployed|reported Ready"):
                    runner.precondition()
        self.assertTrue(all(c[0] in {"get", "auth"} for c in self.calls()))

    def test_native_stops_before_mutation_for_invalid_or_unvalidated_cilium_policy(self):
        self.environment["APPLICATION_BOUNDARY_FIXTURE_IDENTITY"] = (
            "system:serviceaccount:kube-system:homelab-test-runner"
        )
        with patch.dict(os.environ, self.environment):
            runner = self.native_runner()
            for status in [{}, {"conditions": [{"type": "Valid", "status": "False"}]}]:
                self.objects["ciliumnetworkpolicy/career-ops-deny"]["status"] = status
                (self.path / "objects.json").write_text(json.dumps(self.objects))
                with self.assertRaisesRegex(RuntimeError, "Cilium policy"):
                    runner.mutate_owned("create", "seed")
        self.assertTrue(all(c[0] in {"get", "auth"} for c in self.calls()))

    def test_native_cli_reaches_its_confirmation_guard_without_pythonpath(self):
        result = subprocess.run(
            [
                "uv",
                "run",
                "--locked",
                "python",
                str(ROOT / "scripts/test/scenarios/application_boundary_native.py"),
            ],
            cwd=ROOT,
            env={**self.environment, "PYTHONPATH": ""},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("APPLICATION_BOUNDARY_NATIVE_CONFIRM", result.stderr)
        self.assertFalse((self.path / "calls.jsonl").exists())

    def test_native_wait_uses_drop_evidence_without_deprecated_cep_policy(self):
        runner = self.native_runner()
        runner.require_drops = lambda mode: None
        job = {"metadata": {"uid": "synthetic-owned-job"}, "status": {"succeeded": 1}}
        pod = {
            "metadata": {
                "ownerReferences": [
                    {"kind": "Job", "uid": "synthetic-owned-job", "controller": True}
                ]
            },
            "spec": {"nodeName": "synthetic-node"},
            "status": {
                "phase": "Succeeded",
                "containerStatuses": [
                    {
                        "state": {
                            "terminated": {
                                "exitCode": 0,
                                "message": json.dumps({"result": "passed", "phase": "write"}),
                            }
                        }
                    }
                ],
            },
        }
        runner.read = lambda kind, *args, **kwargs: job if kind == "job" else {"items": [pod]}
        try:
            self.assertEqual(runner.wait("write"), "synthetic-node")
        except RuntimeError as error:
            self.fail(str(error))

    def test_drop_oracle_requires_current_run_phase_identity_and_all_targets(self):
        from scripts.test.scenarios import application_boundary_native

        self.assertTrue(
            hasattr(application_boundary_native, "denial_metrics"), "Hubble drop oracle is missing"
        )
        denial_metrics = application_boundary_native.denial_metrics
        run = "0123456789abcdef0123456789abcdef"
        source = ",".join(
            [
                "k8s:homelab.supermorphic.com/test-run=" + run,
                "k8s:homelab.supermorphic.com/test-phase=write",
                "k8s:io.cilium.k8s.policy.serviceaccount=career-ops-boundary-renderer",
                "k8s:io.kubernetes.pod.namespace=career-ops",
            ]
        )
        pairs = [
            ("", "TCP"),
            ("automation-data/automation-data-postgresql", "TCP"),
            ("kube-system/coredns", "TCP"),
            ("kube-system/coredns", "UDP"),
        ]
        response = {
            "status": "success",
            "data": {
                "resultType": "vector",
                "result": [
                    {
                        "metric": {
                            "source": source,
                            "reason": "POLICY_DENIED",
                            "destination": d,
                            "protocol": p,
                        },
                        "value": [1, "1"],
                    }
                    for d, p in pairs
                ],
            },
        }
        self.assertTrue(denial_metrics(response, run, "write"))
        self.assertFalse(denial_metrics(response, "f" * 32, "write"))
        self.assertFalse(denial_metrics(response, run, "read"))
        for index in range(4):
            bad = copy.deepcopy(response)
            bad["data"]["result"][index]["value"][1] = "0"
            self.assertFalse(denial_metrics(bad, run, "write"))
        bad = copy.deepcopy(response)
        bad["data"]["result"][0]["metric"]["reason"] = "NO_ROUTE"
        self.assertFalse(denial_metrics(bad, run, "write"))


if __name__ == "__main__":
    unittest.main()
