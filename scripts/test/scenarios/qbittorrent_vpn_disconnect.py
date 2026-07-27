#!/usr/bin/env python3
"""Structured phase controller for the qBittorrent VPN-disconnect test."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

from resilience_support import (
    Runner,
    ScenarioFailure,
    assert_no_secret_keys,
    atomic_write_json,
    install_interrupt_handlers,
    load_state,
    run_command,
    selected_pod,
    transition,
    utc_now,
    write_recovery,
)

NAMESPACE = "media"
SELECTOR = "app.kubernetes.io/name=qbittorrent"
STATE_NAME = "qbittorrent-vpn-disconnect-state.json"


class Controller:
    def __init__(
        self,
        kubeconfig: str,
        run_dir: Path,
        *,
        runner: Runner = run_command,
        sleep: Any = time.sleep,
        popen: Any = subprocess.Popen,
    ):
        self.kubeconfig = kubeconfig
        self.run_dir = run_dir
        self.runner = runner
        self.sleep = sleep
        self.popen = popen
        self.repo_root = Path(__file__).resolve().parents[3]
        self.probe_dir = self.repo_root / "tests/probes/vpn"
        self.state_path = run_dir / "diagnostics" / STATE_NAME
        self.timeline_dir = run_dir / "diagnostics" / "timelines"
        self.timeline_dir.mkdir(parents=True, exist_ok=True)
        self.baseline_seconds = int(os.environ.get("VPN_DISCONNECT_BASELINE_S", "15"))
        self.outage_seconds = int(os.environ.get("VPN_DISCONNECT_OUTAGE_S", "30"))
        self.settle_seconds = int(os.environ.get("VPN_DISCONNECT_SETTLE_S", "6"))

    def _pod(self) -> dict[str, Any]:
        return selected_pod(self.runner, self.kubeconfig, NAMESPACE, SELECTOR)

    def _gluetun(self, pod: str, arguments: list[str]) -> str:
        return self.runner(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "--namespace",
                NAMESPACE,
                "exec",
                pod,
                "-c",
                "gluetun",
                "--",
                *arguments,
            ]
        ).strip()

    def _api_key(self, pod: str) -> str:
        value = self._gluetun(
            pod,
            [
                "sh",
                "-c",
                ("grep -E '^apikey' /gluetun/auth/config.toml | sed -E 's/.*\"(.*)\".*/\\1/'"),
            ],
        ).replace("\r", "")
        if not value:
            raise ScenarioFailure("could not read the in-memory Gluetun API key")
        return value

    def _api_json(self, pod: str, api_key: str, path: str) -> dict[str, Any]:
        raw = self._gluetun(
            pod,
            [
                "wget",
                "-qO-",
                "--header",
                f"X-API-Key: {api_key}",
                f"http://localhost:8000{path}",
            ],
        )
        try:
            value = json.loads(raw)
        except json.JSONDecodeError as error:
            raise ScenarioFailure("Gluetun API returned invalid JSON") from error
        if not isinstance(value, dict):
            raise ScenarioFailure("Gluetun API response must be an object")
        return value

    def _vpn_status(self, pod: str, api_key: str) -> str:
        return str(self._api_json(pod, api_key, "/v1/vpn/status").get("status", "unknown"))

    def _vpn_ip(self, pod: str, api_key: str) -> str:
        return str(self._api_json(pod, api_key, "/v1/publicip/ip").get("public_ip", ""))

    def _qbit_probe(self) -> None:
        self.runner(
            [
                str(self.repo_root / "tests/probes/qbittorrent/probe.sh"),
                self.kubeconfig,
            ]
        )

    def _analyze(self, arguments: list[str], output: Path) -> None:
        verdict = self.runner(
            [
                sys.executable,
                str(self.probe_dir / "leak_sentinel.py"),
                *arguments,
            ]
        )
        output.write_text(verdict, encoding="utf-8")

    def baseline(self) -> None:
        pod = self._pod()
        pod_name = str(pod["metadata"]["name"])
        api_key = self._api_key(pod_name)
        if self._vpn_status(pod_name, api_key) != "running":
            raise ScenarioFailure("VPN is not running at baseline")
        baseline_ip = self._vpn_ip(pod_name, api_key)
        if not baseline_ip:
            raise ScenarioFailure("VPN baseline has no public IP")
        self._qbit_probe()
        home_ip = self.runner(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "--namespace",
                NAMESPACE,
                "run",
                f"vpndis-wan-{os.getpid()}",
                "--image=curlimages/curl:8.11.1",
                "--restart=Never",
                "--rm",
                "-i",
                "--quiet",
                "--command",
                "--",
                "curl",
                "-sS",
                "-m",
                "15",
                "https://ifconfig.me/ip",
            ]
        ).strip()
        if not home_ip:
            raise ScenarioFailure("could not determine node WAN IP")
        state = {
            "schemaVersion": 1,
            "scenario": "qbittorrent-vpn-disconnect",
            "phase": "baseline",
            "baselineAt": utc_now(),
            "pod": pod_name,
            "podUid": pod["metadata"]["uid"],
            "baselineVpnIp": baseline_ip,
            "homeWanIp": home_ip,
        }
        assert_no_secret_keys(state)
        atomic_write_json(self.state_path, state)
        write_recovery(self.run_dir, "not-attempted", "baseline established; recovery is pending")

    def disrupt(self) -> None:
        state = transition(
            load_state(self.state_path),
            expected={"baseline"},
            next_phase="capturing-outage",
        )
        atomic_write_json(self.state_path, state)
        pod = str(state["pod"])
        api_key = self._api_key(pod)
        timeline = self.timeline_dir / "outage.jsonl"
        with timeline.open("w", encoding="utf-8") as output:
            capture = self.popen(
                [
                    str(self.probe_dir / "capture.sh"),
                    self.kubeconfig,
                    NAMESPACE,
                    pod,
                    str(self.baseline_seconds + self.outage_seconds),
                ],
                stdout=output,
                stderr=subprocess.DEVNULL,
                text=True,
            )
            self.sleep(self.baseline_seconds)
            stopped_at = utc_now()
            try:
                self._gluetun(
                    pod,
                    [
                        "wget",
                        "-qO-",
                        "--method=PUT",
                        "--header",
                        f"X-API-Key: {api_key}",
                        "--body-data",
                        '{"status":"stopped"}',
                        "http://localhost:8000/v1/vpn/status",
                    ],
                )
            finally:
                returncode = capture.wait()
        if returncode != 0:
            raise ScenarioFailure("VPN timeline capture failed")
        state["stopTimestamp"] = stopped_at
        transition(state, expected={"capturing-outage"}, next_phase="vpn-stopped")
        assert_no_secret_keys(state)
        atomic_write_json(self.state_path, state)

    def assert_fail_closed(self) -> None:
        state = transition(
            load_state(self.state_path),
            expected={"vpn-stopped"},
            next_phase="analyzing-outage",
        )
        api_key = self._api_key(str(state["pod"]))
        if self._vpn_status(str(state["pod"]), api_key) == "running":
            raise ScenarioFailure("VPN remained running after the stop request")
        self._analyze(
            [
                "--mode",
                "outage",
                "--timeline",
                str(self.timeline_dir / "outage.jsonl"),
                "--home-wan",
                str(state["homeWanIp"]),
                "--vpn-ip",
                str(state["baselineVpnIp"]),
                "--stop-ts",
                str(state["stopTimestamp"]),
                "--settle",
                str(self.settle_seconds),
            ],
            self.timeline_dir / "outage-verdict.json",
        )
        transition(state, expected={"analyzing-outage"}, next_phase="fail-closed")
        atomic_write_json(self.state_path, state)

    def verify(self) -> None:
        state = transition(
            load_state(self.state_path),
            expected={"fail-closed"},
            next_phase="verifying-recovery",
        )
        pod = self._pod()
        pod_name = str(pod["metadata"]["name"])
        if pod["metadata"]["uid"] == state["podUid"]:
            raise ScenarioFailure("Chainsaw did not recreate the disconnected VPN pod")
        api_key = self._api_key(pod_name)
        if self._vpn_status(pod_name, api_key) != "running":
            raise ScenarioFailure("VPN is not running on the replacement pod")
        recovered_ip = self._vpn_ip(pod_name, api_key)
        if not recovered_ip:
            raise ScenarioFailure("replacement VPN has no public IP")
        recovery_timeline = self.timeline_dir / "recovery.jsonl"
        capture = self.runner(
            [
                str(self.probe_dir / "capture.sh"),
                self.kubeconfig,
                NAMESPACE,
                pod_name,
                "20",
            ]
        )
        recovery_timeline.write_text(capture, encoding="utf-8")
        self._analyze(
            [
                "--timeline",
                str(recovery_timeline),
                "--home-wan",
                str(state["homeWanIp"]),
                "--vpn-ip",
                recovered_ip,
            ],
            self.timeline_dir / "recovery-verdict.json",
        )
        self._qbit_probe()
        state.update(
            {
                "recoveryPod": pod_name,
                "recoveryPodUid": pod["metadata"]["uid"],
                "recoveryVpnIp": recovered_ip,
            }
        )
        transition(state, expected={"verifying-recovery"}, next_phase="verified")
        assert_no_secret_keys(state)
        atomic_write_json(self.state_path, state)
        atomic_write_json(self.run_dir / "evidence.json", state)

    def cleanup(self) -> None:
        state = load_state(self.state_path)
        try:
            pod = self._pod()
            api_key = self._api_key(str(pod["metadata"]["name"]))
            if self._vpn_status(str(pod["metadata"]["name"]), api_key) != "running":
                raise ScenarioFailure("VPN is not running after Chainsaw cleanup")
            if not self._vpn_ip(str(pod["metadata"]["name"]), api_key):
                raise ScenarioFailure("VPN has no public IP after Chainsaw cleanup")
        except ScenarioFailure:
            write_recovery(self.run_dir, "failed", "VPN recovery-state validation failed")
            raise
        state["recoveryValidation"] = {
            "recoveryPod": pod["metadata"]["name"],
            "validatedAt": utc_now(),
        }
        if state.get("phase") == "verified":
            state["phase"] = "cleaned"
        assert_no_secret_keys(state)
        atomic_write_json(self.state_path, state)
        write_recovery(
            self.run_dir,
            "passed",
            "Chainsaw recreated the pod and Python validated healthy VPN recovery",
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "phase",
        choices=("baseline", "disrupt", "assert-fail-closed", "verify", "cleanup"),
    )
    parser.add_argument("kubeconfig")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    install_interrupt_handlers()
    controller = Controller(args.kubeconfig, Path(os.environ["HOMELAB_TEST_RUN_DIR"]))
    method = args.phase.replace("-", "_")
    try:
        getattr(controller, method)()
    except ScenarioFailure as error:
        print(f"qBittorrent VPN phase failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
