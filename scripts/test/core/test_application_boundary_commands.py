"""Run the actual observational and server-dry-run commands against synthetic responses."""

import copy
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

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
            + render(ROOT / "kubernetes/apps/applications")
            + render(PLATFORM.parent / "connection")
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
        revision = "main@sha1:" + "a" * 40
        self.objects["gitrepository/career-ops"]["status"]["artifact"] = {"revision": revision}
        self.objects["kustomization/career-ops-apps"]["status"]["lastAppliedRevision"] = revision
        self.objects["pods"] = {"items": []}
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

    def test_observational_verifier_reads_no_secrets_and_mutates_nothing(self):
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(c[0] in ["get", "auth"] for c in self.calls()))
        self.assertFalse(any("secret" in c[1].lower() for c in self.calls() if c[0] == "get"))

    def test_observational_verifier_requires_no_retired_worker_job(self):
        # The renderer runs only as a Deployment; no renderer Job exists to observe.
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("cv-bootstrap-smoke" in c for c in self.calls()))
        self.assertNotIn("bootstrap", result.stdout)

    def enroll_second_smoke(self):
        self.objects["kustomization/career-ops-apps"]["status"]["inventory"] = {
            "entries": [{"id": "career-ops_application-json-smoke_batch_Job", "v": "v1"}]
        }
        self.objects["job/application-json-smoke"] = {
            "metadata": {
                "name": "application-json-smoke",
                "namespace": "career-ops",
                "uid": "synthetic-json",
                "labels": {
                    "kustomize.toolkit.fluxcd.io/name": "career-ops-apps",
                    "kustomize.toolkit.fluxcd.io/namespace": "career-ops",
                },
            },
            "status": {"succeeded": 1, "conditions": [{"type": "Complete", "status": "True"}]},
        }
        pod = {
            "metadata": {
                "namespace": "career-ops",
                "ownerReferences": [
                    {
                        "apiVersion": "batch/v1",
                        "kind": "Job",
                        "name": "application-json-smoke",
                        "uid": "synthetic-json",
                        "controller": True,
                    }
                ],
            },
            "spec": {
                "serviceAccountName": "career-ops-service",
                "automountServiceAccountToken": False,
            },
            "status": {
                "phase": "Succeeded",
                "containerStatuses": [
                    {
                        "name": "json-check",
                        "state": {
                            "terminated": {"exitCode": 0, "message": "application-json-ok\n"}
                        },
                    }
                ],
            },
        }
        self.objects["pods"]["items"].append(pod)
        return pod

    def test_second_workload_retains_current_owned_tokenless_success(self):
        self.enroll_second_smoke()
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("application-json-smoke", result.stdout)
        self.assertTrue(all(c[0] in ["get", "auth"] for c in self.calls()))
        self.assertFalse(any("secret" in c[1].lower() for c in self.calls() if c[0] == "get"))

    def test_second_workload_rejects_stale_owner_or_invalid_termination(self):
        pod = self.enroll_second_smoke()
        for path, value in [
            (("metadata", "ownerReferences", 0, "uid"), "stale-job"),
            (("spec", "serviceAccountName"), "cv-renderer"),
            (("spec", "automountServiceAccountToken"), True),
            (("status", "containerStatuses", 0, "name"), "other-container"),
            (("status", "containerStatuses", 0, "state", "terminated", "exitCode"), 1),
            (("status", "containerStatuses", 0, "state", "terminated", "message"), "bootstrap-ok"),
        ]:
            with self.subTest(path=path):
                target = pod
                for key in path[:-1]:
                    target = target[key]
                old = target[path[-1]]
                target[path[-1]] = value
                result = self.run_command()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                target[path[-1]] = old

    def test_selected_second_workload_requires_source_owned_complete_job(self):
        self.enroll_second_smoke()
        job = self.objects["job/application-json-smoke"]
        for key, value in [("status", {}), ("metadata", {**job["metadata"], "labels": {}})]:
            with self.subTest(key=key):
                old = job[key]
                job[key] = value
                result = self.run_command()
                self.assertNotEqual(result.returncode, 0, result.stdout)
                job[key] = old
        del self.objects["job/application-json-smoke"]
        self.assertNotEqual(self.run_command().returncode, 0)

    def test_unselected_second_workload_is_not_claimed_from_leftover_job(self):
        self.enroll_second_smoke()
        del self.objects["kustomization/career-ops-apps"]["status"]["inventory"]
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("application-json-smoke: passed", result.stdout)

    def test_application_must_apply_current_source_revision(self):
        self.objects["kustomization/career-ops-apps"]["status"]["lastAppliedRevision"] = "stale"
        result = self.run_command()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("revision", result.stderr)

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

    def test_observer_requires_no_claim_or_volume(self):
        self.assertFalse(any(k.startswith("persistentvolume") for k in self.objects))
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("persistentvolume" in c[1].lower() for c in self.calls() if c[0] == "get"))

    def test_observer_preserves_monitor_check_when_platform_is_the_only_root(self):
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
        # One permitted control and nine intended workload-policy denials.
        self.assertEqual(len(requests), 10)
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


if __name__ == "__main__":
    unittest.main()
