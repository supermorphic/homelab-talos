"""Native fixture permissions share the shipped runtime profile invariants."""

import copy
import importlib.util
import unittest

from scripts.test.core.test_application_boundary import ApplicationFixture, workload

TEST_RUNNER = "system:serviceaccount:kube-system:homelab-test-runner"
JOB_CONTROLLER = "system:serviceaccount:kube-system:job-controller"
PREFIX = "career-ops-boundary-"
IMAGE = (
    "python:3.13.14-slim@sha256:9662417aace5ae7b8e2609cce472b72a8958e134ba372808abe9cc1a0c0125e6"
)
RUN = "1234567890abcdef1234567890abcdef"


def native_job(mode="seed"):
    account = PREFIX + ("coordinator" if mode in {"seed", "cleanup"} else "renderer")
    obj = workload(account)
    obj["metadata"].update(name=PREFIX + mode)
    obj["metadata"]["labels"]["homelab.supermorphic.com/test-run"] = RUN
    obj["spec"]["template"]["metadata"]["labels"]["homelab.supermorphic.com/test-run"] = RUN
    obj["metadata"]["labels"]["homelab.supermorphic.com/test-phase"] = mode
    obj["spec"]["template"]["metadata"]["labels"]["homelab.supermorphic.com/test-phase"] = mode
    pod = obj["spec"]["template"]["spec"]
    pod["securityContext"]["fsGroup"] = 1000
    c = pod["containers"][0]
    c.update(image=IMAGE, command=["python", "-I", "-B", "/fixture/probe.py"])
    c["args"] = [mode, RUN, "192.0.2.1", "192.0.2.2", "192.0.2.3"]
    c["volumeMounts"] = [{"name": "program", "mountPath": "/fixture", "readOnly": True}]
    pod["volumes"] = [{"name": "program", "configMap": {"name": PREFIX + "program"}}]
    return obj


class NativeFixtureAdmissionTests(ApplicationFixture, unittest.TestCase):
    def test_single_target_jobs_are_admitted_without_storage_or_other_authority(self):
        from scripts.test.scenarios.application_boundary_native import job

        for stage in ["write", "read"]:
            for target in ["api", "database", "dns-tcp", "dns-udp"]:
                mode = "network-" + stage + "-" + target
                obj = job(mode, RUN, ["192.0.2.1", "192.0.2.2", "192.0.2.3"], "synthetic-node")
                for policy in [
                    "career-ops-workloads",
                    PREFIX + "fixtures",
                    "career-ops-resources",
                    PREFIX + "test",
                ]:
                    self.assertTrue(self.admission(obj, policy, TEST_RUNNER), (mode, policy))
                pod = obj["spec"]["template"]["spec"]
                self.assertEqual(len(pod["volumes"]), 1)
                self.assertIn("configMap", pod["volumes"][0])
                bad = copy.deepcopy(obj)
                bad["spec"]["template"]["spec"]["volumes"].append(
                    {"name": "unused", "persistentVolumeClaim": {"claimName": PREFIX + "requests"}}
                )
                self.assertFalse(self.admission(bad, PREFIX + "fixtures", TEST_RUNNER))

    def test_runner_templates_pass_both_profile_and_fixture_guards(self):
        from scripts.test.core.test_application_boundary import ROOT

        path = ROOT / "scripts/test/scenarios/application_boundary_native.py"
        self.assertTrue(path.is_file(), "native runner is missing")
        spec = importlib.util.spec_from_file_location("native_runner", path)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        for mode in ["seed", "write", "read", "cleanup"]:
            obj = runner.job(mode, RUN, ["192.0.2.1", "192.0.2.2", "192.0.2.3"], "synthetic-node")
            for policy in [
                "career-ops-workloads",
                PREFIX + "fixtures",
                "career-ops-resources",
                PREFIX + "test",
            ]:
                self.assertTrue(self.admission(obj, policy, TEST_RUNNER), (mode, policy))
            pod = obj["spec"]["template"]["spec"]
            self.assertFalse(pod["automountServiceAccountToken"])
            self.assertFalse(any("secret" in v for v in pod["volumes"]))
            claims = [
                v["persistentVolumeClaim"]["claimName"]
                for v in pod["volumes"]
                if "persistentVolumeClaim" in v
            ]
            self.assertTrue(all(name.startswith(PREFIX) for name in claims))

    def test_native_identities_share_the_runtime_security_profile(self):
        for mode in ["seed", "write", "read", "cleanup"]:
            obj = native_job(mode)
            self.assertTrue(self.admission(obj, username=TEST_RUNNER), mode)
            for field, value in [("hostNetwork", True), ("automountServiceAccountToken", True)]:
                bad = copy.deepcopy(obj)
                bad["spec"]["template"]["spec"][field] = value
                self.assertFalse(self.admission(bad, username=TEST_RUNNER), field)

    def test_native_identities_cannot_mount_production_credentials_or_claims(self):
        for account in ["coordinator", "renderer"]:
            for volume in [
                {"secret": {"secretName": "cv-render-database"}},
                {"persistentVolumeClaim": {"claimName": "cv-requests"}},
                {"configMap": {"name": "application-supplied-program"}},
            ]:
                obj = native_job("seed" if account == "coordinator" else "write")
                obj["spec"]["template"]["spec"]["volumes"].append({"name": "private", **volume})
                self.assertFalse(self.admission(obj, username=TEST_RUNNER), volume)

    def test_native_identities_cannot_be_used_by_other_controllers(self):
        for kind in ["Deployment", "ReplicaSet"]:
            obj = workload(PREFIX + "coordinator", kind)
            obj["spec"]["template"]["spec"]["securityContext"]["fsGroup"] = 1000
            self.assertFalse(self.admission(obj), kind)

    def test_platform_fixture_policy_exists(self):
        self.assertIn(
            PREFIX + "fixtures",
            [
                d["metadata"]["name"]
                for d in self.documents
                if d["kind"] == "ValidatingAdmissionPolicy"
            ],
        )

    def test_fixed_program_and_ownership_cannot_be_replaced(self):
        policy = PREFIX + "fixtures"
        good = native_job()
        self.assertTrue(self.admission(good, policy, TEST_RUNNER))
        for change in [
            {"image": "example.invalid/replacement:latest"},
            {"command": ["python", "-c", "print('replacement')"]},
            {"args": ["cleanup", RUN, "192.0.2.1", "192.0.2.2", "192.0.2.3"]},
            {"args": ["seed", "../other-run", "192.0.2.1", "192.0.2.2", "192.0.2.3"]},
            {"env": [{"name": "PYTHONPATH", "value": "/requests"}]},
            {
                "lifecycle": {
                    "postStart": {"exec": {"command": ["python", "-c", "print('replacement')"]}}
                }
            },
            {"readinessProbe": {"exec": {"command": ["python", "-c", "print('replacement')"]}}},
        ]:
            bad = copy.deepcopy(good)
            bad["spec"]["template"]["spec"]["containers"][0].update(change)
            self.assertFalse(self.admission(bad, policy, TEST_RUNNER), change)
        self.assertFalse(self.admission(good, policy), "application cannot use fixture identities")
        bad = copy.deepcopy(good)
        bad["metadata"]["labels"]["homelab.supermorphic.com/test-run"] = "f" * 32
        self.assertFalse(self.admission(bad, policy, TEST_RUNNER))

    def test_controller_pods_preserve_the_fixed_program(self):
        job = native_job("write")
        pod = {
            "kind": "Pod",
            "metadata": {**job["spec"]["template"]["metadata"], "name": PREFIX + "write-pod"},
            "spec": job["spec"]["template"]["spec"],
        }
        pod["metadata"]["ownerReferences"] = [
            {
                "apiVersion": "batch/v1",
                "kind": "Job",
                "name": PREFIX + "write",
                "uid": "synthetic-job-uid",
                "controller": True,
            }
        ]
        self.assertTrue(self.admission(pod, PREFIX + "fixtures", JOB_CONTROLLER))
        self.assertFalse(self.admission(pod, PREFIX + "fixtures", TEST_RUNNER))
        pod["spec"]["containers"][0]["args"][0] = "cleanup"
        self.assertFalse(self.admission(pod, PREFIX + "fixtures", JOB_CONTROLLER))

    def test_controller_pods_accept_only_api_defaulted_tolerations(self):
        job = native_job("write")
        pod = {
            "kind": "Pod",
            "metadata": copy.deepcopy(job["spec"]["template"]["metadata"]),
            "spec": copy.deepcopy(job["spec"]["template"]["spec"]),
        }
        pod["metadata"].update(
            name=PREFIX + "write-pod",
            ownerReferences=[
                {
                    "apiVersion": "batch/v1",
                    "kind": "Job",
                    "name": PREFIX + "write",
                    "uid": "synthetic-job-uid",
                    "controller": True,
                }
            ],
        )
        pod["spec"]["tolerations"] = [
            {
                "key": "node.kubernetes.io/" + key,
                "operator": "Exists",
                "effect": "NoExecute",
                "tolerationSeconds": 300,
            }
            for key in ["not-ready", "unreachable"]
        ]
        self.assertTrue(self.admission(pod, PREFIX + "fixtures", JOB_CONTROLLER))
        pod["spec"]["tolerations"][0]["effect"] = "NoSchedule"
        self.assertFalse(self.admission(pod, PREFIX + "fixtures", JOB_CONTROLLER))


if __name__ == "__main__":
    unittest.main()
