"""Focused tests for the deployed web-research consumer contract runner."""

import importlib.util
import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location(
    "web_research_live_contract",
    ROOT / "scripts/test/web_research/live_contract.py",
)
live_contract = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(live_contract)


def deployment(*, observed_generation=7, ready_replicas=1):
    return {
        "metadata": {"name": "n8n", "namespace": "automation", "uid": "deploy-uid", "generation": 7},
        "spec": {
            "replicas": 1,
            "selector": {
                "matchLabels": {
                    "app.kubernetes.io/instance": "n8n",
                    "app.kubernetes.io/name": "n8n",
                }
            },
        },
        "status": {
            "observedGeneration": observed_generation,
            "replicas": 1,
            "updatedReplicas": 1,
            "readyReplicas": ready_replicas,
            "availableReplicas": ready_replicas,
            "conditions": [{"type": "Available", "status": "True"}],
        },
    }


def replica_set(*, owner_uid="deploy-uid"):
    return {
        "metadata": {
            "name": "n8n-abc",
            "uid": "rs-uid",
            "ownerReferences": [
                {
                    "apiVersion": "apps/v1",
                    "kind": "Deployment",
                    "name": "n8n",
                    "uid": owner_uid,
                    "controller": True,
                }
            ],
        }
    }


def pod(*, owner_uid="rs-uid", ready=True):
    return {
        "metadata": {
            "name": "n8n-abc-123",
            "namespace": "automation",
            "ownerReferences": [
                {
                    "apiVersion": "apps/v1",
                    "kind": "ReplicaSet",
                    "name": "n8n-abc",
                    "uid": owner_uid,
                    "controller": True,
                }
            ],
        },
        "status": {
            "phase": "Running",
            "containerStatuses": [
                {"name": "n8n-main", "ready": ready, "started": ready}
            ],
        },
    }


class FakeKubectl:
    def __init__(self, *, replacement_pod=None):
        self.replacement_pod = replacement_pod
        self.pod_reads = 0
        self.exec_inputs = []

    def __call__(self, command, *, stdin=None, timeout=None):
        if "config" in command:
            return live_contract.CommandResult(0, "")
        if "deployment" in command:
            return live_contract.CommandResult(0, json.dumps(deployment()))
        if "replicasets" in command:
            return live_contract.CommandResult(0, json.dumps({"items": [replica_set()]}))
        if "pods" in command:
            self.pod_reads += 1
            selected = (
                self.replacement_pod
                if self.pod_reads == 2 and self.replacement_pod is not None
                else pod()
            )
            return live_contract.CommandResult(0, json.dumps({"items": [selected]}))
        if "exec" in command:
            self.exec_inputs.append(stdin)
            records = [
                {
                    "phase": phase,
                    "result": "pass",
                    "status": 200,
                    "size": 1,
                    "count": 1,
                    "duration": 1,
                }
                for phase in live_contract.PHASES
            ]
            return live_contract.CommandResult(
                0, "".join(json.dumps(record) + "\n" for record in records)
            )
        raise AssertionError(command)


class LiveTargetSelectionTests(unittest.TestCase):
    def test_selects_single_ready_pod_through_deployment_owner_chain(self):
        target = live_contract.select_target(
            deployment(), {"items": [replica_set()]}, {"items": [pod()]}
        )
        self.assertEqual(target.pod_name, "n8n-abc-123")
        self.assertEqual(
            target.selector,
            "app.kubernetes.io/instance=n8n,app.kubernetes.io/name=n8n",
        )

    def test_rejects_stale_rollout_wrong_owner_and_ambiguous_ready_pods(self):
        missing_deployment_uid = deployment()
        del missing_deployment_uid["metadata"]["uid"]
        missing_replica_set_uid = replica_set()
        del missing_replica_set_uid["metadata"]["uid"]
        cases = (
            (deployment(observed_generation=6), [replica_set()], [pod()]),
            (deployment(), [replica_set(owner_uid="other")], [pod()]),
            (missing_deployment_uid, [replica_set(owner_uid=None)], [pod()]),
            (deployment(), [missing_replica_set_uid], [pod(owner_uid=None)]),
            (deployment(), [replica_set()], [pod(), {**pod(), "metadata": {**pod()["metadata"], "name": "n8n-abc-456"}}]),
        )
        for deployed, replica_sets, pods in cases:
            with self.subTest(pods=len(pods)), self.assertRaises(live_contract.ContractFailure):
                live_contract.select_target(
                    deployed, {"items": replica_sets}, {"items": pods}
                )

    def test_exec_is_fixed_to_diagnostic_n8n_main_node_stdin(self):
        command = live_contract.exec_command(Path(".kube/config"), "n8n-abc-123")
        self.assertEqual(
            command,
            [
                "kubectl",
                "--kubeconfig",
                ".kube/config",
                "--context",
                "homelab-diagnostic",
                "--namespace",
                "automation",
                "--request-timeout=9m",
                "exec",
                "-i",
                "pod/n8n-abc-123",
                "-c",
                "n8n-main",
                "--",
                "node",
            ],
        )

    def test_cluster_reads_are_fixed_to_observer_context(self):
        self.assertEqual(
            live_contract.read_command(Path(".kube/config"), "deployment", "n8n"),
            [
                "kubectl",
                "--kubeconfig",
                ".kube/config",
                "--context",
                "homelab-observer",
                "--namespace",
                "automation",
                "--request-timeout=20s",
                "get",
                "deployment",
                "n8n",
                "--output=json",
            ],
        )

    def test_target_must_remain_identical_at_final_preflight(self):
        target = live_contract.Target("n8n-abc-123", "app=n8n")
        self.assertEqual(live_contract.confirm_target(target, target), target)
        for changed in (
            live_contract.Target("n8n-def-456", "app=n8n"),
            live_contract.Target("n8n-abc-123", "app=n8n,component=main"),
        ):
            with self.subTest(changed=changed), self.assertRaises(
                live_contract.ContractFailure
            ):
                live_contract.confirm_target(target, changed)


class SanitizedResultTests(unittest.TestCase):
    def test_accepts_only_complete_fixed_result_records(self):
        records = [
            {
                "phase": phase,
                "result": "pass",
                "status": 200,
                "size": 123,
                "count": 1,
                "duration": 10,
            }
            for phase in live_contract.PHASES
        ]
        encoded = "".join(json.dumps(record) + "\n" for record in records)
        self.assertEqual(live_contract.sanitize_results(encoded), records)

    def test_rejects_content_unknown_fields_and_oversized_output(self):
        safe = {
            "phase": live_contract.PHASES[0],
            "result": "pass",
            "status": 200,
            "size": 1,
            "count": 1,
            "duration": 1,
        }
        unsafe = {**safe, "content": "Example Domain"}
        for output in (
            json.dumps(unsafe) + "\n",
            "x" * (live_contract.MAX_RESULT_BYTES + 1),
            json.dumps(safe) + "\nnot-json\n",
        ):
            with self.subTest(size=len(output)), self.assertRaises(live_contract.ContractFailure):
                live_contract.sanitize_results(output)


class LiveExecutionTests(unittest.TestCase):
    def test_rechecks_owned_target_then_runs_one_fixed_stdin_program(self):
        kubectl = FakeKubectl()
        records = live_contract.execute(
            Path(".kube/config"), "fixed-node-program", invoke=kubectl
        )
        self.assertEqual([record["phase"] for record in records], list(live_contract.PHASES))
        self.assertEqual(kubectl.pod_reads, 2)
        self.assertEqual(kubectl.exec_inputs, ["fixed-node-program"])

    def test_rejects_replaced_pod_before_exec(self):
        replacement = pod()
        replacement["metadata"]["name"] = "n8n-def-456"
        kubectl = FakeKubectl(replacement_pod=replacement)
        with self.assertRaises(live_contract.ContractFailure):
            live_contract.execute(Path(".kube/config"), "fixed-node-program", invoke=kubectl)
        self.assertEqual(kubectl.exec_inputs, [])


if __name__ == "__main__":
    unittest.main()
