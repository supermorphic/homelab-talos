#!/usr/bin/env python3
"""Attended, electrically abrupt node-loss resilience controller."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

from resilience_support import (
    Runner,
    ScenarioFailure,
    atomic_write_json,
    install_interrupt_handlers,
    run_command,
    write_recovery,
)

STATE_NAME = "node-abrupt-loss-state.json"
EVIDENCE_NAME = "node-abrupt-loss-evidence.json"
NODE_IPS = {
    "nuc1": "192.168.90.10",
    "nuc2": "192.168.90.11",
    "nuc3": "192.168.90.12",
}
StatusRunner = Callable[[list[str]], tuple[int, str]]


def run_status(argv: list[str]) -> tuple[int, str]:
    result = subprocess.run(argv, text=True, capture_output=True, check=False)
    return result.returncode, result.stdout


def bounded_seconds(name: str, default: int, maximum: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as error:
        raise ScenarioFailure(f"{name} must be an integer") from error
    if not 1 <= value <= maximum:
        raise ScenarioFailure(f"{name} must be between 1 and {maximum} seconds")
    return value


class ExternalProbeMonitor:
    """Record Boolean core-path samples without persisting response content."""

    def __init__(
        self,
        kubeconfig: str,
        *,
        status_runner: StatusRunner = run_status,
        interval: int = 5,
        no_success_limit: int = 60,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self.kubeconfig = kubeconfig
        self.status_runner = status_runner
        self.interval = interval
        self.no_success_limit = no_success_limit
        self.monotonic = monotonic
        self.samples: list[dict[str, object]] = []
        self._violations: set[str] = set()
        self._last_success: dict[str, float] = {}
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._started_at = self.monotonic()

    def _sample(self) -> None:
        now = self.monotonic()
        commands = {
            "api": ["kubectl", "--kubeconfig", self.kubeconfig, "get", "--raw=/readyz"],
            "dns": ["dig", "+short", "echo.lab.supermorphic.com", "A"],
            "https": [
                "curl",
                "--silent",
                "--show-error",
                "--fail",
                "--max-time",
                "4",
                "https://echo.lab.supermorphic.com/",
            ],
        }
        sample: dict[str, object] = {"at": now}
        for name, command in commands.items():
            code, output = self.status_runner(command)
            success = code == 0 and bool(output.strip())
            sample[name] = success
            if success:
                self._last_success[name] = now
            elif now - self._last_success.get(name, self._started_at) >= self.no_success_limit:
                self._violations.add(name)
        self.samples.append(sample)

    def _run(self) -> None:
        while not self._stop.wait(self.interval):
            self._sample()

    def start(self) -> None:
        self._started_at = self.monotonic()
        self._sample()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self) -> list[dict[str, object]]:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=self.interval + 1)
        return list(self.samples)

    def violations(self) -> list[str]:
        return sorted(self._violations)


class Controller:
    def __init__(
        self,
        node: str,
        kubeconfig: str,
        talosconfig: str,
        run_dir: Path,
        *,
        runner: Runner = run_command,
        status_runner: StatusRunner = run_status,
        baseline: Callable[[], dict[str, object]] | None = None,
        observe: Callable[[], dict[str, object]] | None = None,
        bridge: Callable[[str], None] | None = None,
        prompt: Callable[[str], str] = input,
        monotonic: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
        monitor: Any | None = None,
        loss_timeout: int = 180,
        passive_seconds: int = 600,
        poll_seconds: int = 5,
    ) -> None:
        if node not in NODE_IPS:
            raise ScenarioFailure("node must be one of nuc1, nuc2, or nuc3")
        self.node = node
        self.node_ip = NODE_IPS[node]
        self.kubeconfig = kubeconfig
        self.talosconfig = talosconfig
        self.run_dir = run_dir
        self.runner = runner
        self.status_runner = status_runner
        self.baseline_fn = baseline or self._baseline
        self.observe_fn = observe or self._observe
        self.bridge_fn = bridge or self._bridge
        self.prompt = prompt
        self.monotonic = monotonic
        self.sleep = sleep
        self.loss_timeout = loss_timeout
        self.passive_seconds = passive_seconds
        self.poll_seconds = poll_seconds
        self.monitor = monitor or ExternalProbeMonitor(
            kubeconfig,
            status_runner=status_runner,
            interval=poll_seconds,
            no_success_limit=bounded_seconds("NODE_ABRUPT_CORE_NO_SUCCESS_SECONDS", 60, 300),
            monotonic=monotonic,
        )
        self.state_path = run_dir / "diagnostics" / STATE_NAME
        self.evidence_path = run_dir / "diagnostics" / EVIDENCE_NAME

    def _json_status(self, command: list[str]) -> dict[str, Any]:
        code, output = self.status_runner(command)
        if code != 0:
            return {}
        try:
            value = json.loads(output)
        except json.JSONDecodeError:
            return {}
        return value if isinstance(value, dict) else {}

    def _required_json_status(self, command: list[str], description: str) -> dict[str, Any]:
        value = self._json_status(command)
        if not value:
            raise ScenarioFailure(f"could not read {description}")
        return value

    def _verify_survivor_capacity(self, nodes: dict[str, Any], pods: dict[str, Any]) -> None:
        with tempfile.TemporaryDirectory(prefix="node-abrupt-capacity-") as temporary:
            nodes_path = Path(temporary) / "nodes.json"
            pods_path = Path(temporary) / "pods.json"
            nodes_path.write_text(json.dumps(nodes), encoding="utf-8")
            pods_path.write_text(json.dumps(pods), encoding="utf-8")
            self.runner(
                [
                    sys.executable,
                    "scripts/node/capacity.py",
                    self.node,
                    str(nodes_path),
                    str(pods_path),
                ]
            )

    @staticmethod
    def _target_workloads(pods: dict[str, Any]) -> list[dict[str, object]]:
        workloads: list[dict[str, object]] = []
        for item in pods.get("items", []):
            metadata = item.get("metadata", {})
            if "kubernetes.io/config.mirror" in metadata.get("annotations", {}):
                continue
            owners = metadata.get("ownerReferences", [])
            owner = next((value for value in owners if value.get("controller") is True), None)
            if owner is None and owners:
                owner = owners[0]
            if not owner or owner.get("kind") == "DaemonSet":
                continue
            claims = sorted(
                volume["persistentVolumeClaim"]["claimName"]
                for volume in item.get("spec", {}).get("volumes", [])
                if volume.get("persistentVolumeClaim", {}).get("claimName")
            )
            workloads.append(
                {
                    "namespace": metadata.get("namespace", ""),
                    "pod": metadata.get("name", ""),
                    "podUid": metadata.get("uid", ""),
                    "ownerKind": owner.get("kind", ""),
                    "ownerName": owner.get("name", ""),
                    "ownerUid": owner.get("uid", ""),
                    "claims": claims,
                }
            )
        return sorted(workloads, key=lambda value: (str(value["namespace"]), str(value["pod"])))

    @staticmethod
    def _affected_claims(
        workloads: list[dict[str, object]],
        pvcs: dict[str, Any],
        pvs: dict[str, Any],
    ) -> list[dict[str, str]]:
        wanted = {
            (str(workload["namespace"]), str(claim))
            for workload in workloads
            for claim in workload.get("claims", [])
        }
        pv_by_name = {
            item.get("metadata", {}).get("name", ""): item for item in pvs.get("items", [])
        }
        claims: list[dict[str, str]] = []
        for item in pvcs.get("items", []):
            metadata = item.get("metadata", {})
            key = (metadata.get("namespace", ""), metadata.get("name", ""))
            if key not in wanted:
                continue
            volume_name = item.get("spec", {}).get("volumeName", "")
            volume = pv_by_name.get(volume_name, {})
            claims.append(
                {
                    "namespace": key[0],
                    "name": key[1],
                    "uid": metadata.get("uid", ""),
                    "volumeName": volume_name,
                    "volumeUid": volume.get("metadata", {}).get("uid", ""),
                    "longhornVolume": volume.get("spec", {})
                    .get("csi", {})
                    .get("volumeHandle", ""),
                }
            )
        return sorted(claims, key=lambda value: (value["namespace"], value["name"]))

    def _workload_observations(self, pods: dict[str, Any]) -> list[dict[str, object]]:
        observations: list[dict[str, object]] = []
        for workload in getattr(self, "target_workloads", []):
            candidates = []
            for pod in pods.get("items", []):
                metadata = pod.get("metadata", {})
                if metadata.get("namespace") != workload["namespace"]:
                    continue
                if not any(
                    owner.get("uid") == workload["ownerUid"]
                    for owner in metadata.get("ownerReferences", [])
                ):
                    continue
                candidates.append(pod)
            ready_survivor = next(
                (
                    pod
                    for pod in candidates
                    if pod.get("spec", {}).get("nodeName") != self.node
                    and any(
                        condition.get("type") == "Ready" and condition.get("status") == "True"
                        for condition in pod.get("status", {}).get("conditions", [])
                    )
                ),
                None,
            )
            if ready_survivor is not None:
                state = "ready-on-survivor"
                pod = ready_survivor
            elif any(pod.get("spec", {}).get("nodeName") == self.node for pod in candidates):
                state = "stuck-on-target"
                pod = candidates[0]
            elif candidates:
                state = "pending"
                pod = candidates[0]
            else:
                state = "absent"
                pod = {}
            observations.append(
                {
                    "namespace": workload["namespace"],
                    "originalPod": workload["pod"],
                    "ownerKind": workload["ownerKind"],
                    "ownerName": workload["ownerName"],
                    "state": state,
                    "currentPod": pod.get("metadata", {}).get("name", ""),
                    "currentNode": pod.get("spec", {}).get("nodeName", ""),
                }
            )
        return observations

    def _claim_identity_preserved(self, pvcs: dict[str, Any], pvs: dict[str, Any]) -> bool:
        current = self._affected_claims(
            [
                {"namespace": claim["namespace"], "claims": [claim["name"]]}
                for claim in getattr(self, "affected_claims", [])
            ],
            pvcs,
            pvs,
        )
        return current == getattr(self, "affected_claims", [])

    def _baseline(self) -> dict[str, object]:
        self.runner(["just", "cluster", "verify"])
        nodes = self._required_json_status(
            ["kubectl", "--kubeconfig", self.kubeconfig, "get", "nodes", "-o", "json"],
            "Kubernetes Nodes",
        )
        all_pods = self._required_json_status(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "get",
                "pods",
                "--all-namespaces",
                "-o",
                "json",
            ],
            "Kubernetes Pods",
        )
        self._verify_survivor_capacity(nodes, all_pods)
        pods = self._required_json_status(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "get",
                "pods",
                "--all-namespaces",
                "--field-selector",
                f"spec.nodeName={self.node}",
                "-o",
                "json",
            ],
            "target-node Pods",
        )
        replicas = self._required_json_status(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "--namespace",
                "longhorn-system",
                "get",
                "replicas.longhorn.io",
                "-o",
                "json",
            ],
            "Longhorn Replicas",
        )
        pvcs = self._required_json_status(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "get",
                "persistentvolumeclaims",
                "--all-namespaces",
                "-o",
                "json",
            ],
            "PersistentVolumeClaims",
        )
        pvs = self._required_json_status(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "get",
                "persistentvolumes",
                "-o",
                "json",
            ],
            "PersistentVolumes",
        )
        target_workloads = self._target_workloads(pods)
        affected_claims = self._affected_claims(target_workloads, pvcs, pvs)
        affected_volumes = sorted(
            {
                item.get("spec", {}).get("volumeName", "")
                for item in replicas.get("items", [])
                if item.get("spec", {}).get("nodeID") == self.node
                and not item.get("spec", {}).get("failedAt")
            }
            - {""}
        )
        for volume in affected_volumes:
            off_target = [
                item
                for item in replicas.get("items", [])
                if item.get("spec", {}).get("volumeName") == volume
                and item.get("spec", {}).get("nodeID") != self.node
                and not item.get("spec", {}).get("failedAt")
            ]
            if not off_target:
                raise ScenarioFailure(
                    f"Longhorn volume {volume} has no healthy replica away from {self.node}"
                )
        self.affected_volumes = affected_volumes
        self.target_workloads = target_workloads
        self.affected_claims = affected_claims
        return {
            "healthy": True,
            "nodes": sorted(
                item.get("metadata", {}).get("name", "") for item in nodes.get("items", [])
            ),
            "targetWorkloads": target_workloads,
            "affectedClaims": affected_claims,
            "affectedVolumes": affected_volumes,
        }

    def _observe(self) -> dict[str, object]:
        talos_code, _ = self.status_runner(
            [
                "talosctl",
                "version",
                "--nodes",
                self.node_ip,
                "--endpoints",
                self.node_ip,
                "--talosconfig",
                self.talosconfig,
            ]
        )
        node = self._json_status(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "get",
                "node",
                self.node,
                "-o",
                "json",
            ]
        )
        ready = next(
            (
                condition.get("status")
                for condition in node.get("status", {}).get("conditions", [])
                if condition.get("type") == "Ready"
            ),
            "Unknown",
        )
        target_etcd_code, _ = self.status_runner(
            [
                "talosctl",
                "etcd",
                "status",
                "--nodes",
                self.node_ip,
                "--endpoints",
                self.node_ip,
                "--talosconfig",
                self.talosconfig,
            ]
        )
        survivors = ",".join(ip for name, ip in NODE_IPS.items() if name != self.node)
        quorum_code, quorum_output = self.status_runner(
            [
                "talosctl",
                "etcd",
                "status",
                "--nodes",
                survivors,
                "--endpoints",
                survivors,
                "--talosconfig",
                self.talosconfig,
            ]
        )
        quorum_rows = len([line for line in quorum_output.splitlines()[1:] if line.strip()])
        nodes = self._json_status(
            ["kubectl", "--kubeconfig", self.kubeconfig, "get", "nodes", "-o", "json"]
        )
        ready_survivors = sum(
            1
            for item in nodes.get("items", [])
            if item.get("metadata", {}).get("name") != self.node
            and any(
                condition.get("type") == "Ready" and condition.get("status") == "True"
                for condition in item.get("status", {}).get("conditions", [])
            )
        )
        volumes = self._json_status(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "--namespace",
                "longhorn-system",
                "get",
                "volumes.longhorn.io",
                "-o",
                "json",
            ]
        )
        pods = self._json_status(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "get",
                "pods",
                "--all-namespaces",
                "-o",
                "json",
            ]
        )
        pvcs = self._json_status(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "get",
                "persistentvolumeclaims",
                "--all-namespaces",
                "-o",
                "json",
            ]
        )
        pvs = self._json_status(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "get",
                "persistentvolumes",
                "-o",
                "json",
            ]
        )
        replicas = self._json_status(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "--namespace",
                "longhorn-system",
                "get",
                "replicas.longhorn.io",
                "-o",
                "json",
            ]
        )
        volume_items = [
            item
            for item in volumes.get("items", [])
            if item.get("metadata", {}).get("name") in getattr(self, "affected_volumes", [])
        ]
        affected_volumes = getattr(self, "affected_volumes", [])
        surviving_replica_available = all(
            any(
                item.get("spec", {}).get("volumeName") == volume
                and item.get("spec", {}).get("nodeID") != self.node
                and not item.get("spec", {}).get("failedAt")
                for item in replicas.get("items", [])
            )
            for volume in affected_volumes
        )
        cilium = self._json_status(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "--namespace",
                "kube-system",
                "get",
                "pods",
                "--selector",
                "k8s-app=cilium",
                "-o",
                "json",
            ]
        )
        ready_cilium_survivors = sum(
            1
            for item in cilium.get("items", [])
            if item.get("spec", {}).get("nodeName") != self.node
            and any(
                condition.get("type") == "Ready" and condition.get("status") == "True"
                for condition in item.get("status", {}).get("conditions", [])
            )
        )
        return {
            "talosLost": talos_code != 0,
            "nodeNotReady": ready != "True",
            "etcdTargetLost": target_etcd_code != 0,
            "quorumRetained": quorum_code == 0 and quorum_rows == 2,
            "readySurvivors": ready_survivors,
            "readyCiliumSurvivors": ready_cilium_survivors,
            "workloads": self._workload_observations(pods),
            "storage": {
                "pvcIdentityPreserved": self._claim_identity_preserved(pvcs, pvs),
                "survivingReplicaAvailable": surviving_replica_available,
                "affectedVolumeStates": [
                    {
                        "name": item.get("metadata", {}).get("name", ""),
                        "robustness": item.get("status", {}).get("robustness", "unknown"),
                        "state": item.get("status", {}).get("state", "unknown"),
                    }
                    for item in volume_items
                ],
                "fullReplicaCount": all(
                    item.get("status", {}).get("robustness") == "healthy" for item in volume_items
                ),
            },
        }

    def _bridge(self, action: str) -> None:
        holder = os.environ.get("HOMELAB_DISRUPTION_LEASE_HOLDER", "")
        if not holder:
            raise ScenarioFailure("shared disruption Lease holder is unavailable")
        self.runner(
            [
                "scripts/node/abrupt-loss-bridge.sh",
                action,
                self.node,
                self.kubeconfig,
                self.talosconfig,
                holder,
            ]
        )

    @staticmethod
    def _loss_observed(observation: dict[str, object]) -> bool:
        return all(
            observation.get(key) is True
            for key in ("talosLost", "nodeNotReady", "etcdTargetLost", "quorumRetained")
        )

    def run(self) -> None:
        expected_target = f"remove-power:{self.node}:{self.node_ip}"
        if os.environ.get("CLUSTER_CHAOS_CONFIRM") != "chaos:node-abrupt-loss":
            raise ScenarioFailure("scenario confirmation is missing or incorrect")
        if os.environ.get("NODE_ABRUPT_LOSS_CONFIRM") != expected_target:
            raise ScenarioFailure(
                "target-bound electrical-loss confirmation is missing or incorrect"
            )

        baseline = self.baseline_fn()
        state: dict[str, Any] = {
            "schemaVersion": 1,
            "phase": "baseline",
            "node": self.node,
            "baseline": baseline,
            "passiveObservation": [],
        }
        atomic_write_json(self.state_path, state)
        disruption_started = False
        loss_proven = False
        contained = False
        restore_requested = False
        recovery_attempted = False
        primary_error: ScenarioFailure | None = None
        self.monitor.start()
        try:
            self.prompt(
                f"Physically disconnect electrical input from {self.node}, then press Enter. "
                "Do not use its power button: "
            )
            disruption_started = True
            state["phase"] = "detecting-loss"
            atomic_write_json(self.state_path, state)
            deadline = self.monotonic() + self.loss_timeout
            detected: dict[str, object] | None = None
            while self.monotonic() <= deadline:
                observation = self.observe_fn()
                if self._loss_observed(observation):
                    detected = observation
                    break
                self.sleep(self.poll_seconds)
            if detected is None:
                raise ScenarioFailure("genuine node loss was not proved by all four signals")
            loss_proven = True
            loss_observed_at = self.monotonic()
            state["lossEvidence"] = detected
            self.bridge_fn("contain")
            contained = True
            state["phase"] = "contained"
            atomic_write_json(self.state_path, state)

            passive_deadline = self.monotonic() + self.passive_seconds
            while self.monotonic() < passive_deadline:
                observation = self.observe_fn()
                state["passiveObservation"].append(observation)
                if observation.get("quorumRetained") is not True:
                    raise ScenarioFailure("surviving etcd members lost quorum")
                if observation.get("readySurvivors") != 2:
                    raise ScenarioFailure("exactly two surviving Kubernetes Nodes are not Ready")
                if observation.get("readyCiliumSurvivors") != 2:
                    raise ScenarioFailure("Cilium is not Ready on both surviving Nodes")
                storage = observation.get("storage", {})
                if (
                    not isinstance(storage, dict)
                    or storage.get("survivingReplicaAvailable") is not True
                ):
                    raise ScenarioFailure("surviving Longhorn replica availability was not proved")
                if storage.get("pvcIdentityPreserved", True) is not True:
                    raise ScenarioFailure(
                        "an affected PVC or PV identity changed during node loss"
                    )
                elapsed = round(self.monotonic() - loss_observed_at, 3)
                recovery_times = state.setdefault("workloadRecoverySeconds", {})
                for workload in observation.get("workloads", []):
                    if (
                        not isinstance(workload, dict)
                        or workload.get("state") != "ready-on-survivor"
                    ):
                        continue
                    key = f"{workload.get('namespace', '')}/{workload.get('ownerKind', '')}/{workload.get('ownerName', '')}"
                    recovery_times.setdefault(key, elapsed)
                self.sleep(self.poll_seconds)

            self.prompt(
                f"Restore electrical input to {self.node}; require firmware automatic power-on, "
                "then press Enter: "
            )
            restore_requested = True
            state["phase"] = "recovering"
            atomic_write_json(self.state_path, state)
            recovery_attempted = True
            self.bridge_fn("recover")
            state["phase"] = "recovered"
            write_recovery(
                self.run_dir, "passed", f"{self.node} passed contained recovery acceptance"
            )
        except (ScenarioFailure, EOFError, KeyboardInterrupt) as error:
            primary_error = (
                error if isinstance(error, ScenarioFailure) else ScenarioFailure(str(error))
            )
            state["phase"] = "failed"
            state["failure"] = str(error)
            if disruption_started and not restore_requested:
                self.prompt(
                    f"Restore electrical input to {self.node} now, then press Enter. "
                    "The lifecycle state remains unresolved: "
                )
                restore_requested = True
            if loss_proven and not contained:
                try:
                    self.bridge_fn("contain")
                except ScenarioFailure:
                    pass
                else:
                    contained = True
            if not disruption_started:
                write_recovery(
                    self.run_dir,
                    "passed",
                    f"{self.node} was unchanged because execution stopped before disruption",
                )
            elif contained and not recovery_attempted:
                try:
                    recovery_attempted = True
                    self.bridge_fn("recover")
                except ScenarioFailure:
                    write_recovery(
                        self.run_dir,
                        "failed",
                        f"unresolved lifecycle recovery for {self.node}",
                    )
                else:
                    write_recovery(
                        self.run_dir,
                        "passed",
                        f"{self.node} recovered after a failed resilience assertion",
                    )
            elif contained:
                write_recovery(
                    self.run_dir,
                    "failed",
                    f"recovery acceptance remains pending for {self.node}",
                )
            else:
                write_recovery(
                    self.run_dir,
                    "failed",
                    f"unresolved uncontained abrupt loss for {self.node}",
                )
        finally:
            samples = self.monitor.stop()
            state["externalProbes"] = samples
            violations = self.monitor.violations() if hasattr(self.monitor, "violations") else []
            state["corePathSloViolations"] = violations
            atomic_write_json(self.state_path, state)
            atomic_write_json(self.evidence_path, state)
        if primary_error is not None:
            raise primary_error
        if violations:
            raise ScenarioFailure(
                "core external paths exceeded the no-success limit: " + ", ".join(violations)
            )


def main() -> int:
    if len(sys.argv) != 4:
        print("Usage: node_abrupt_loss.py <node> <kubeconfig> <talosconfig>", file=sys.stderr)
        return 2
    run_dir_raw = os.environ.get("HOMELAB_TEST_RUN_DIR", "")
    if not run_dir_raw:
        print("HOMELAB_TEST_RUN_DIR is required.", file=sys.stderr)
        return 1
    try:
        install_interrupt_handlers()
        controller = Controller(
            sys.argv[1],
            sys.argv[2],
            sys.argv[3],
            Path(run_dir_raw),
            loss_timeout=bounded_seconds("NODE_ABRUPT_LOSS_TIMEOUT_SECONDS", 180, 600),
            passive_seconds=bounded_seconds("NODE_ABRUPT_PASSIVE_SECONDS", 600, 1800),
            poll_seconds=bounded_seconds("NODE_ABRUPT_PROBE_SECONDS", 5, 30),
        )
        controller.run()
    except ScenarioFailure as error:
        print(f"Node abrupt-loss scenario failed: {error}.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
