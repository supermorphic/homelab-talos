#!/usr/bin/env python3
"""Structured phases for the Plex cross-node reschedule resilience test."""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import Any

from resilience_support import (
    Runner,
    ScenarioFailure,
    atomic_write_json,
    install_interrupt_handlers,
    kubectl_json,
    load_state,
    run_command,
    selected_pod,
    transition,
    utc_now,
    write_recovery,
)

NAMESPACE = "media"
SELECTOR = "app.kubernetes.io/name=plex"
STATE_NAME = "plex-cross-node-reschedule-state.json"
SMB_PATH = "/Volumes/Prometheus/media"


class Controller:
    def __init__(self, kubeconfig: str, run_dir: Path, *, runner: Runner = run_command):
        self.kubeconfig = kubeconfig
        self.run_dir = run_dir
        self.runner = runner
        self.state_path = run_dir / "diagnostics" / STATE_NAME
        self.repo_root = Path(__file__).resolve().parents[3]
        self.marker_action = self.repo_root / "scripts/test/actions/pod-marker.sh"
        self.node_action = self.repo_root / "scripts/test/actions/node-scheduling.sh"

    def _pod(self) -> dict[str, Any]:
        return selected_pod(self.runner, self.kubeconfig, NAMESPACE, SELECTOR)

    def _resource(self, namespace: str | None, arguments: list[str]) -> dict[str, Any]:
        return kubectl_json(self.runner, self.kubeconfig, namespace, [*arguments, "-o", "json"])

    def _marker(self, action: str, pod: str, path: str, value: str = "") -> str:
        command = [
            str(self.marker_action),
            action,
            self.kubeconfig,
            NAMESPACE,
            pod,
            "app",
            path,
        ]
        if value:
            command.append(value)
        return self.runner(command).strip()

    def _node(self, action: str, node: str) -> None:
        self.runner([str(self.node_action), action, self.kubeconfig, node])

    def _assert_smb(self, pod: str) -> None:
        self.runner(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "--namespace",
                NAMESPACE,
                "exec",
                pod,
                "-c",
                "app",
                "--",
                "test",
                "-d",
                SMB_PATH,
            ]
        )

    def prepare(self) -> None:
        pod = self._pod()
        pod_name = str(pod["metadata"]["name"])
        original_node = str(pod["spec"]["nodeName"])
        nodes = self._resource(None, ["get", "nodes"]).get("items", [])
        eligible = []
        original: dict[str, Any] | None = None
        for node in nodes:
            name = node.get("metadata", {}).get("name")
            ready = any(
                item.get("type") == "Ready" and item.get("status") == "True"
                for item in node.get("status", {}).get("conditions", [])
            )
            schedulable = node.get("spec", {}).get("unschedulable") is not True
            if name == original_node:
                original = node
            elif ready and schedulable:
                eligible.append(name)
        if original is None or original.get("spec", {}).get("unschedulable") is True:
            raise ScenarioFailure("Plex source node is absent or already cordoned")
        if not eligible:
            raise ScenarioFailure("no eligible landing node is available")
        pvc = self._resource(NAMESPACE, ["get", "pvc", "plex"])
        volume_name = pvc.get("spec", {}).get("volumeName")
        if not volume_name:
            raise ScenarioFailure("Plex PVC has no bound volume")
        volume = self._resource(
            "longhorn-system",
            ["get", "volumes.longhorn.io", str(volume_name)],
        )
        longhorn = volume.get("status", {})
        if longhorn.get("state") != "attached" or longhorn.get("robustness") != "healthy":
            raise ScenarioFailure("Plex Longhorn volume is not attached and healthy")
        self._assert_smb(pod_name)
        run_id = re.sub(r"[^A-Za-z0-9]", "", self.run_dir.name)
        marker = f"/config/.cross-node-reschedule-probe-{run_id}"
        marker_value = f"reschedule-{run_id}-{os.getpid()}"
        state = {
            "schemaVersion": 1,
            "scenario": "plex-cross-node-reschedule",
            "phase": "preparing",
            "preparedAt": utc_now(),
            "oldPod": pod_name,
            "oldUid": pod["metadata"]["uid"],
            "originalNode": original_node,
            "eligibleNodes": eligible,
            "preVolume": volume_name,
            "marker": marker,
            "markerValue": marker_value,
        }
        atomic_write_json(self.state_path, state)
        write_recovery(self.run_dir, "not-attempted", "scenario prepared; cleanup is pending")
        try:
            self._marker("create", pod_name, marker, marker_value)
            if self._marker("read", pod_name, marker) != marker_value:
                raise ScenarioFailure("Plex persistence marker was not readable")
        except ScenarioFailure:
            self._marker("remove", pod_name, marker)
            raise
        transition(state, expected={"preparing"}, next_phase="prepared")
        atomic_write_json(self.state_path, state)

    def cordon(self) -> None:
        state = transition(
            load_state(self.state_path),
            expected={"prepared"},
            next_phase="cordoning",
        )
        state["cordonedNode"] = state["originalNode"]
        atomic_write_json(self.state_path, state)
        self._node("cordon", str(state["originalNode"]))
        transition(state, expected={"cordoning"}, next_phase="cordoned")
        atomic_write_json(self.state_path, state)

    def observe(self) -> None:
        state = transition(
            load_state(self.state_path),
            expected={"cordoned"},
            next_phase="observing",
        )
        pod = self._pod()
        new_uid = pod["metadata"]["uid"]
        new_node = pod["spec"]["nodeName"]
        if new_uid == state["oldUid"]:
            raise ScenarioFailure("Chainsaw readiness completed on the original Plex pod")
        if new_node == state["originalNode"]:
            raise ScenarioFailure("Plex replacement returned to the cordoned node")
        state.update({"newPod": pod["metadata"]["name"], "newUid": new_uid, "newNode": new_node})
        transition(state, expected={"observing"}, next_phase="observed")
        atomic_write_json(self.state_path, state)

    def verify(self) -> None:
        state = transition(
            load_state(self.state_path),
            expected={"observed"},
            next_phase="verifying",
        )
        pod = self._pod()
        if pod["metadata"]["uid"] != state["newUid"]:
            raise ScenarioFailure("Plex replacement changed before verification")
        pvc = self._resource(NAMESPACE, ["get", "pvc", "plex"])
        post_volume = pvc.get("spec", {}).get("volumeName")
        if post_volume != state["preVolume"]:
            raise ScenarioFailure("Plex PVC changed its bound PV")
        volume = self._resource(
            "longhorn-system",
            ["get", "volumes.longhorn.io", str(post_volume)],
        )
        longhorn = volume.get("status", {})
        if (
            longhorn.get("state") != "attached"
            or longhorn.get("currentNodeID") != state["newNode"]
        ):
            raise ScenarioFailure("Longhorn did not reattach on the Plex landing node")
        if self._marker("read", state["newPod"], state["marker"]) != state["markerValue"]:
            raise ScenarioFailure("Plex marker did not survive cross-node rescheduling")
        self._assert_smb(str(state["newPod"]))
        state["postVolume"] = post_volume
        state["longhorn"] = {
            "currentNodeID": longhorn.get("currentNodeID"),
            "state": longhorn.get("state"),
            "robustness": longhorn.get("robustness"),
        }
        transition(state, expected={"verifying"}, next_phase="verified")
        atomic_write_json(self.state_path, state)
        atomic_write_json(self.run_dir / "evidence.json", state)

    def cleanup_node(self) -> None:
        state = load_state(self.state_path)
        cordoned_node = state.get("cordonedNode")
        node_failure = ""
        if cordoned_node:
            try:
                self._node("uncordon", str(cordoned_node))
            except ScenarioFailure:
                node_failure = f"failed to uncordon exact node {cordoned_node}"
        state["cleanup"] = {
            "uncordonedNode": cordoned_node,
            "nodeFailure": node_failure,
            "nodeAttemptedAt": utc_now(),
        }
        atomic_write_json(self.state_path, state)
        if node_failure:
            write_recovery(self.run_dir, "failed", node_failure)
            raise ScenarioFailure(node_failure)

    def cleanup_marker(self) -> None:
        state = load_state(self.state_path)
        failures = []
        node_failure = state.get("cleanup", {}).get("nodeFailure")
        if node_failure:
            failures.append(str(node_failure))
        try:
            pod = self._pod()
            self._marker("remove", str(pod["metadata"]["name"]), str(state["marker"]))
        except ScenarioFailure:
            failures.append("failed to remove Plex persistence marker")
        state.setdefault("cleanup", {})["failures"] = failures
        state["cleanup"]["completedAt"] = utc_now()
        state["phase"] = "cleanup-failed" if failures else "cleaned"
        atomic_write_json(self.state_path, state)
        if failures:
            write_recovery(self.run_dir, "failed", "; ".join(failures))
            raise ScenarioFailure("; ".join(failures))
        write_recovery(
            self.run_dir,
            "passed",
            "exact test node uncordoned and Plex marker removed",
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "phase",
        choices=(
            "prepare",
            "cordon",
            "observe",
            "verify",
            "cleanup-node",
            "cleanup-marker",
        ),
    )
    parser.add_argument("kubeconfig")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    install_interrupt_handlers()
    controller = Controller(args.kubeconfig, Path(os.environ["HOMELAB_TEST_RUN_DIR"]))
    try:
        getattr(controller, args.phase.replace("-", "_"))()
    except ScenarioFailure as error:
        print(f"Plex cross-node phase failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
