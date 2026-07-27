#!/usr/bin/env python3
"""Structured phases for the qBittorrent pod-recreation resilience test."""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
from pathlib import Path
from typing import Any

from resilience_support import (
    Runner,
    ScenarioFailure,
    atomic_write_json,
    install_interrupt_handlers,
    kubectl_json,
    load_state,
    named_status,
    run_command,
    selected_pod,
    transition,
    utc_now,
    write_recovery,
)

NAMESPACE = "media"
SELECTOR = "app.kubernetes.io/name=qbittorrent"
STATE_NAME = "qbittorrent-pod-recreation-state.json"


class Controller:
    def __init__(
        self,
        kubeconfig: str,
        run_dir: Path,
        *,
        runner: Runner = run_command,
        sleep: Any = time.sleep,
        timeout: int = 300,
    ):
        self.kubeconfig = kubeconfig
        self.run_dir = run_dir
        self.runner = runner
        self.sleep = sleep
        self.timeout = timeout
        self.state_path = run_dir / "diagnostics" / STATE_NAME
        self.repo_root = Path(__file__).resolve().parents[3]
        self.marker_action = self.repo_root / "scripts/test/actions/pod-marker.sh"

    def _pod(self) -> dict[str, Any]:
        return selected_pod(self.runner, self.kubeconfig, NAMESPACE, SELECTOR)

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

    def _resource(self, namespace: str, arguments: list[str]) -> dict[str, Any]:
        return kubectl_json(self.runner, self.kubeconfig, namespace, [*arguments, "-o", "json"])

    def prepare(self) -> None:
        pod = self._pod()
        metadata = pod["metadata"]
        pvc = self._resource(NAMESPACE, ["get", "pvc", "qbittorrent"])
        volume = pvc.get("spec", {}).get("volumeName")
        if not volume:
            raise ScenarioFailure("qBittorrent PVC has no bound volume")
        run_id = re.sub(r"[^A-Za-z0-9]", "", self.run_dir.name)
        marker = f"/config/.pod-recreation-probe-{run_id}"
        marker_value = f"recreation-{run_id}-{os.getpid()}"
        pod_name = str(metadata["name"])
        state = {
            "schemaVersion": 1,
            "scenario": "qbittorrent-pod-recreation",
            "phase": "preparing",
            "preparedAt": utc_now(),
            "oldPod": pod_name,
            "oldUid": metadata["uid"],
            "preVolume": volume,
            "marker": marker,
            "markerValue": marker_value,
        }
        atomic_write_json(self.state_path, state)
        write_recovery(self.run_dir, "not-attempted", "scenario prepared; cleanup is pending")
        try:
            self._marker("create", pod_name, marker, marker_value)
            if self._marker("read", pod_name, marker) != marker_value:
                raise ScenarioFailure("persistence marker was not readable after creation")
        except ScenarioFailure:
            self._marker("remove", pod_name, marker)
            raise
        transition(state, expected={"preparing"}, next_phase="prepared")
        atomic_write_json(self.state_path, state)

    def observe(self) -> None:
        state = transition(
            load_state(self.state_path),
            expected={"prepared"},
            next_phase="observing",
        )
        atomic_write_json(self.state_path, state)
        deadline = time.monotonic() + self.timeout
        samples = 0
        violations = 0
        replacement: dict[str, Any] | None = None
        while time.monotonic() < deadline:
            try:
                pod = self._pod()
            except ScenarioFailure:
                self.sleep(1)
                continue
            metadata = pod["metadata"]
            if metadata.get("uid") == state["oldUid"]:
                self.sleep(1)
                continue
            replacement = pod
            gluetun = named_status(pod, "initContainerStatuses", "gluetun")
            app = named_status(pod, "containerStatuses", "app")
            samples += 1
            if app.get("started") is True and gluetun.get("started") is not True:
                violations += 1
            if app.get("started") is True:
                break
            self.sleep(1)
        if replacement is None:
            raise ScenarioFailure("no replacement qBittorrent pod appeared")
        if violations:
            raise ScenarioFailure(f"observed {violations} startup-order violation(s)")
        gluetun = named_status(replacement, "initContainerStatuses", "gluetun")
        app = named_status(replacement, "containerStatuses", "app")
        gluetun_at = gluetun.get("state", {}).get("running", {}).get("startedAt")
        app_at = app.get("state", {}).get("running", {}).get("startedAt")
        if not gluetun_at or not app_at or app_at < gluetun_at:
            raise ScenarioFailure("container timestamps violate VPN-before-app ordering")
        state.update(
            {
                "newPod": replacement["metadata"]["name"],
                "newUid": replacement["metadata"]["uid"],
                "gluetunStartedAt": gluetun_at,
                "appStartedAt": app_at,
                "pollSamples": samples,
            }
        )
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
            raise ScenarioFailure("observed replacement pod changed before verification")
        pvc = self._resource(NAMESPACE, ["get", "pvc", "qbittorrent"])
        post_volume = pvc.get("spec", {}).get("volumeName")
        if post_volume != state["preVolume"]:
            raise ScenarioFailure("qBittorrent PVC changed its bound PV")
        volume = self._resource(
            "longhorn-system",
            ["get", "volumes.longhorn.io", str(post_volume)],
        )
        longhorn = volume.get("status", {})
        pod_node = pod.get("spec", {}).get("nodeName")
        if longhorn.get("state") != "attached" or longhorn.get("currentNodeID") != pod_node:
            raise ScenarioFailure("Longhorn volume is not attached to the replacement node")
        if self._marker("read", state["newPod"], state["marker"]) != state["markerValue"]:
            raise ScenarioFailure("persistence marker did not survive pod recreation")
        state["postVolume"] = post_volume
        state["longhorn"] = {
            "currentNodeID": longhorn.get("currentNodeID"),
            "state": longhorn.get("state"),
            "robustness": longhorn.get("robustness"),
        }
        transition(state, expected={"verifying"}, next_phase="verified")
        atomic_write_json(self.state_path, state)
        atomic_write_json(self.run_dir / "evidence.json", state)

    def cleanup(self) -> None:
        state = load_state(self.state_path)
        try:
            pod = self._pod()
            self._marker(
                "remove",
                str(pod["metadata"]["name"]),
                str(state["marker"]),
            )
        except ScenarioFailure:
            write_recovery(self.run_dir, "failed", "persistence marker cleanup failed")
            raise
        state["cleanup"] = {"markerRemoved": True, "completedAt": utc_now()}
        state["phase"] = "cleaned"
        atomic_write_json(self.state_path, state)
        write_recovery(
            self.run_dir,
            "passed",
            "marker removed after Chainsaw verified qBittorrent recovery",
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=("prepare", "observe", "verify", "cleanup"))
    parser.add_argument("kubeconfig")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    install_interrupt_handlers()
    run_dir = Path(os.environ["HOMELAB_TEST_RUN_DIR"])
    controller = Controller(args.kubeconfig, run_dir)
    try:
        getattr(controller, args.phase)()
    except ScenarioFailure as error:
        print(f"qBittorrent pod-recreation phase failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
