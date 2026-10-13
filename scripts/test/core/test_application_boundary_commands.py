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
        revision = "main@sha1:" + "a" * 40
        self.objects["gitrepository/career-ops"]["status"]["artifact"] = {"revision": revision}
        self.objects["kustomization/career-ops-apps"]["status"]["lastAppliedRevision"] = revision
        for name, size in [
            ("cv-releases", "8Gi"),
            ("cv-requests", "16Gi"),
            ("cv-artifacts", "32Gi"),
        ]:
            self.objects["persistentvolumeclaim/" + name] = {
                "kind": "PersistentVolumeClaim",
                "metadata": {
                    "name": name,
                    "namespace": "career-ops",
                    "uid": "synthetic-" + name,
                    "annotations": {"kustomize.toolkit.fluxcd.io/prune": "disabled"},
                },
                "spec": {
                    "storageClassName": "career-ops-retain",
                    "accessModes": ["ReadWriteMany"],
                    "volumeMode": "Filesystem",
                    "resources": {"requests": {"storage": size}},
                    "volumeName": "synthetic-volume-" + name,
                },
                "status": {"phase": "Bound"},
            }
            self.objects["persistentvolume/synthetic-volume-" + name] = {
                "spec": {
                    "persistentVolumeReclaimPolicy": "Retain",
                    "storageClassName": "career-ops-retain",
                    "claimRef": {"uid": "synthetic-" + name},
                    "csi": {"driver": "driver.longhorn.io"},
                },
            }
        self.objects["job/cv-bootstrap-smoke"] = {
            "metadata": {
                "name": "cv-bootstrap-smoke",
                "namespace": "career-ops",
                "uid": "synthetic-bootstrap",
            },
            "status": {"succeeded": 1, "conditions": [{"type": "Complete", "status": "True"}]},
        }
        self.objects["pods"] = {
            "items": [
                {
                    "metadata": {
                        "namespace": "career-ops",
                        "ownerReferences": [
                            {
                                "apiVersion": "batch/v1",
                                "kind": "Job",
                                "name": "cv-bootstrap-smoke",
                                "uid": "synthetic-bootstrap",
                                "controller": True,
                            }
                        ],
                    },
                    "spec": {
                        "serviceAccountName": "cv-renderer",
                        "automountServiceAccountToken": False,
                    },
                    "status": {
                        "phase": "Succeeded",
                        "containerStatuses": [
                            {
                                "name": "bootstrap",
                                "state": {
                                    "terminated": {"exitCode": 0, "message": "bootstrap-ok\n"}
                                },
                            }
                        ],
                    },
                }
            ]
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

    def test_observational_verifier_checks_bootstrap_without_secret_reads_or_mutation(self):
        result = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("bootstrap", result.stdout)
        self.assertTrue(all(c[0] in ["get", "auth"] for c in self.calls()))
        self.assertFalse(any("secret" in c[1].lower() for c in self.calls() if c[0] == "get"))

    def test_bootstrap_requires_current_job_ownership_and_exact_termination_result(self):
        pod = self.objects["pods"]["items"][0]
        for path, value in [
            (("status", "containerStatuses", 0, "state", "terminated", "exitCode"), 1),
            (("status", "containerStatuses", 0, "state", "terminated", "message"), "wrong-result"),
            (("metadata", "ownerReferences", 0, "uid"), "stale-job"),
            (("spec", "automountServiceAccountToken"), True),
        ]:
            target = pod
            for key in path[:-1]:
                target = target[key]
            old = target[path[-1]]
            target[path[-1]] = value
            result = self.run_command()
            self.assertNotEqual(result.returncode, 0, path)
            self.assertIn("bootstrap", result.stderr)
            target[path[-1]] = old

    def test_application_must_apply_current_source_revision(self):
        self.objects["kustomization/career-ops-apps"]["status"]["lastAppliedRevision"] = "stale"
        result = self.run_command()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("revision", result.stderr)

    def test_application_claims_require_retention_and_owned_volume_binding(self):
        claim = self.objects["persistentvolumeclaim/cv-releases"]
        for field, value in [
            ("ownerReferences", [{"kind": "Job", "uid": "synthetic-bootstrap"}]),
            ("annotations", {}),
        ]:
            claim["metadata"][field] = value
            result = self.run_command()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("retained claim", result.stderr)
            claim["metadata"].pop(field)
            claim["metadata"]["annotations"] = {"kustomize.toolkit.fluxcd.io/prune": "disabled"}
        self.objects["persistentvolume/synthetic-volume-cv-releases"]["spec"]["claimRef"][
            "uid"
        ] = "other"
        result = self.run_command()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("volume", result.stderr)

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

        # These retained-storage fixtures exercise the pre-enrollment phase.
        for key in (
            "kustomization/career-ops-connection",
            "gitrepository/career-ops",
            "kustomization/career-ops-apps",
        ):
            self.objects[key]["spec"]["suspend"] = True
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
        witnesses = []
        runner.require_drops = witnesses.append
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
                                "message": json.dumps(
                                    {"result": "passed", "phase": "network-write-api"}
                                ),
                            }
                        }
                    }
                ],
            },
        }
        runner.read = lambda kind, *args, **kwargs: job if kind == "job" else {"items": [pod]}
        try:
            self.assertEqual(runner.wait("network-write-api"), "synthetic-node")
            self.assertEqual(witnesses, ["network-write-api"])
        except RuntimeError as error:
            self.fail(str(error))

    def test_drop_oracle_requires_one_target_phase_run_identity_and_protocol(self):
        from scripts.test.scenarios.application_boundary_native import denial_metrics

        run = "0123456789abcdef0123456789abcdef"
        for stage in ["write", "read"]:
            for target in ["api", "database", "dns-tcp", "dns-udp"]:
                phase = "network-" + stage + "-" + target
                source = ",".join(
                    [
                        "k8s:homelab.supermorphic.com/test-run=" + run,
                        "k8s:homelab.supermorphic.com/test-phase=" + phase,
                        "k8s:io.cilium.k8s.policy.serviceaccount=career-ops-boundary-renderer",
                        "k8s:io.kubernetes.pod.namespace=career-ops",
                    ]
                )
                protocol = "UDP" if target == "dns-udp" else "TCP"
                # Service-IP drops can omit destination workload context entirely.
                response = {
                    "status": "success",
                    "data": {
                        "resultType": "vector",
                        "result": [
                            {
                                "metric": {
                                    "source": source,
                                    "reason": "POLICY_DENIED",
                                    "protocol": protocol,
                                },
                                "value": [1, "2"],
                            }
                        ],
                    },
                }
                self.assertTrue(denial_metrics(response, run, phase), phase)
                self.assertFalse(denial_metrics(response, "f" * 32, phase))
                self.assertFalse(denial_metrics(response, run, "network-unknown-api"))
                self.assertFalse(denial_metrics(response, run, "read"))
                for value in ["0", "-1", "NaN", "Inf", "invalid"]:
                    bad = copy.deepcopy(response)
                    bad["data"]["result"][0]["value"][1] = value
                    self.assertFalse(denial_metrics(bad, run, phase))
                for key, value in [
                    ("reason", "NO_ROUTE"),
                    ("protocol", "ICMPv6"),
                    ("source", source.replace("test-phase=" + phase, "test-phase=write")),
                    ("source", source.replace("career-ops-boundary-renderer", "cv-renderer")),
                    ("source", source.replace("pod.namespace=career-ops", "pod.namespace=other")),
                ]:
                    bad = copy.deepcopy(response)
                    bad["data"]["result"][0]["metric"][key] = value
                    self.assertFalse(denial_metrics(bad, run, phase), (phase, key))

    def test_native_execution_checks_every_target_on_both_worker_nodes(self):
        runner = self.native_runner()
        runner.precondition = lambda: None
        events = []

        def read(kind, name=None, *args, **kwargs):
            if kind == "job":
                return None
            if kind == "service":
                return {"spec": {"clusterIP": "192.0.2.1"}}
            if kind == "nodes":
                return {
                    "items": [
                        {
                            "metadata": {"name": n, "labels": {"kubernetes.io/hostname": n}},
                            "spec": {},
                            "status": {"conditions": [{"type": "Ready", "status": "True"}]},
                        }
                        for n in ["node-a", "node-b"]
                    ]
                }
            raise AssertionError(kind)

        runner.read = read
        runner.mutate_owned = lambda operation, mode: events.append((operation, mode))

        def wait(mode):
            pod = runner.templates[mode]["spec"]["template"]["spec"]
            if mode.startswith("network-"):
                events.append(("probe", mode, pod["nodeSelector"]["kubernetes.io/hostname"]))
                self.assertEqual(len(pod["volumes"]), 1)
            return pod.get("nodeSelector", {}).get("kubernetes.io/hostname", "node-a")

        runner.wait = wait
        with patch("subprocess.check_output", return_value=""):
            runner.execute()
        wanted = [
            ("probe", "network-" + stage + "-" + target, node)
            for stage, node in [("write", "node-b"), ("read", "node-a")]
            for target in ["api", "database", "dns-tcp", "dns-udp"]
        ]
        self.assertEqual([e for e in events if e[0] == "probe"], wanted)
        for _, mode, _ in wanted:
            self.assertEqual(events.count(("create", mode)), 1)
            self.assertIn(("delete", mode), events)

    def test_native_rejects_writer_running_on_an_unselected_third_node(self):
        runner = self.native_runner()
        runner.precondition = lambda: None
        nodes = [
            {
                "metadata": {"name": n, "labels": {"kubernetes.io/hostname": n}},
                "spec": {},
                "status": {"conditions": [{"type": "Ready", "status": "True"}]},
            }
            for n in ["node-a", "node-b"]
        ]

        def read(kind, *args, **kwargs):
            if kind == "nodes":
                return {"items": nodes}
            if kind == "service":
                return {"spec": {"clusterIP": "192.0.2.1"}}
            return None

        runner.read = read
        runner.mutate_owned = lambda operation, mode: None
        runner.wait = lambda mode: "node-c" if mode == "write" else "node-a"
        runner.network_probes = lambda *args: self.fail("Probe ran on a different worker node")
        with (
            patch("subprocess.check_output", return_value=""),
            self.assertRaisesRegex(RuntimeError, "Writer.*selected"),
        ):
            runner.execute()


if __name__ == "__main__":
    unittest.main()
