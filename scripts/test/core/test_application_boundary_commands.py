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
        for doc in render(PLATFORM) + render(ROOT / "kubernetes/apps/applications"):
            obj = copy.deepcopy(doc)
            obj["metadata"]["generation"] = 1
            obj["status"] = {
                "observedGeneration": 1,
                "typeChecking": {},
                "conditions": [{"type": "Ready", "status": "True", "observedGeneration": 1}],
            }
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


if __name__ == "__main__":
    unittest.main()
