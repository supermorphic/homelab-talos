#!/usr/bin/env python3
"""Structured phases for the persistent test-report pod-recreation proof."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

from resilience_support import (
    InterruptedRun,
    Runner,
    ScenarioFailure,
    assert_no_secret_keys,
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

NAMESPACE = "test-reports"
SELECTOR = "app.kubernetes.io/name=test-reports"
STATE_NAME = "test-reports-persistence-state.json"
EVIDENCE_NAME = "test-reports-persistence-evidence.json"
HOST = "tests.lab.supermorphic.com"
RUN_ID_PATTERN = re.compile(
    r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}-(?:agent|github-actions|operator)-[0-9a-f]{8}$"
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
Snapshotter = Callable[[], dict[str, Any]]


class Controller:
    def __init__(
        self,
        kubeconfig: str,
        run_dir: Path,
        *,
        run_id: str | None = None,
        runner: Runner = run_command,
        snapshotter: Snapshotter | None = None,
        sleep: Any = time.sleep,
        timeout: int = 300,
    ):
        self.kubeconfig = kubeconfig
        self.run_dir = run_dir
        self.run_id = run_id or os.environ.get("TEST_REPORT_RUN_ID", "")
        if not RUN_ID_PATTERN.fullmatch(self.run_id):
            raise ScenarioFailure("TEST_REPORT_RUN_ID must name one canonical published run")
        self.runner = runner
        self.sleep = sleep
        self.timeout = timeout
        self.state_path = run_dir / "diagnostics" / STATE_NAME
        self.evidence_path = run_dir / "diagnostics" / EVIDENCE_NAME
        self.snapshotter = snapshotter or self._snapshot

    def _resource(self, arguments: list[str]) -> dict[str, Any]:
        return kubectl_json(
            self.runner,
            self.kubeconfig,
            NAMESPACE,
            [*arguments, "-o", "json"],
        )

    def _exec(self, arguments: list[str]) -> str:
        return self.runner(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "--namespace",
                NAMESPACE,
                "exec",
                "deployment/test-reports",
                "-c",
                "caddy",
                "--",
                *arguments,
            ]
        ).strip()

    def _sha256(self, path: str) -> str:
        output = self._exec(["sha256sum", path])
        digest = output.split(maxsplit=1)[0] if output else ""
        if not SHA256_PATTERN.fullmatch(digest):
            raise ScenarioFailure(f"invalid SHA-256 output for {Path(path).name}")
        return digest

    def _catalog_entry(self) -> dict[str, Any]:
        try:
            catalog = json.loads(self._exec(["cat", "/srv/state/current/catalog.json"]))
        except json.JSONDecodeError as error:
            raise ScenarioFailure("published catalog is not valid JSON") from error
        if not isinstance(catalog, dict):
            raise ScenarioFailure("published catalog root is not an object")
        runs = catalog.get("runs")
        if not isinstance(runs, list):
            raise ScenarioFailure("published catalog runs are missing or invalid")
        entries = [
            entry
            for entry in runs
            if isinstance(entry, dict) and entry.get("run_id") == self.run_id
        ]
        if len(entries) != 1 or entries[0].get("authoritative") is not True:
            raise ScenarioFailure("selected report is missing or not authoritative in the catalog")
        entry = entries[0]
        return {
            "runId": self.run_id,
            "gitSha": entry.get("git_sha"),
            "result": entry.get("result"),
            "authoritative": True,
        }

    def _snapshot(self) -> dict[str, Any]:
        pod = selected_pod(
            self.runner,
            self.kubeconfig,
            NAMESPACE,
            SELECTOR,
        )
        pvc = self._resource(["get", "persistentvolumeclaim", "test-reports"])
        pod_name = pod.get("metadata", {}).get("name")
        pod_uid = pod.get("metadata", {}).get("uid")
        pvc_uid = pvc.get("metadata", {}).get("uid")
        if not all(isinstance(value, str) and value for value in (pod_name, pod_uid, pvc_uid)):
            raise ScenarioFailure("test-report pod or PVC identity is incomplete")
        volume = pvc.get("spec", {}).get("volumeName")
        if not volume:
            raise ScenarioFailure("test-report PVC has no bound volume")
        generation = self._exec(["readlink", "/srv/state/current"])
        if not re.fullmatch(r"generations/[0-9A-Za-z._-]+", generation):
            raise ScenarioFailure("test-report current generation link is invalid")
        report_path = f"/srv/reports/{self.run_id}/awesome/index.html"
        artifact_path = f"/srv/artifacts/{self.run_id}.tar.gz"
        body = self.runner(
            [
                "curl",
                "--silent",
                "--show-error",
                "--fail",
                "--max-time",
                "15",
                f"https://{HOST}/reports/{self.run_id}/awesome/",
            ]
        )
        if "<html" not in body.lower():
            raise ScenarioFailure("published Allure entrypoint is not HTML")
        return {
            "pod": {
                "name": pod_name,
                "uid": pod_uid,
                "node": pod.get("spec", {}).get("nodeName"),
            },
            "pvc": {
                "uid": pvc_uid,
                "volume": volume,
            },
            "generation": generation,
            "reportIndexSha256": self._sha256(report_path),
            "artifactSha256": self._sha256(artifact_path),
            "catalogEntry": self._catalog_entry(),
            "observedAt": utc_now(),
        }

    @staticmethod
    def _assert_persisted(
        baseline: dict[str, Any],
        recovered: dict[str, Any],
    ) -> None:
        if recovered["pod"]["uid"] == baseline["pod"]["uid"]:
            raise ScenarioFailure("test-report pod identity did not change")
        if recovered["pvc"] != baseline["pvc"]:
            raise ScenarioFailure("test-report PVC identity or bound volume changed")
        for field in ("reportIndexSha256", "artifactSha256", "catalogEntry"):
            if recovered[field] != baseline[field]:
                raise ScenarioFailure(f"published {field} changed after pod recreation")

    def prepare(self) -> None:
        write_recovery(
            self.run_dir,
            "not-attempted",
            "baseline captured; pod recreation recovery is pending",
        )
        baseline = self.snapshotter()
        state = {
            "schemaVersion": 1,
            "scenario": "test-reports-persistence",
            "runId": self.run_id,
            "phase": "prepared",
            "preparedAt": utc_now(),
            "baseline": baseline,
        }
        assert_no_secret_keys(state)
        atomic_write_json(self.state_path, state)

    def recover(self) -> None:
        state = transition(
            load_state(self.state_path),
            expected={"prepared"},
            next_phase="recovering",
        )
        atomic_write_json(self.state_path, state)
        deadline = time.monotonic() + self.timeout
        last_error: ScenarioFailure | None = None
        while True:
            try:
                recovered = self.snapshotter()
                self._assert_persisted(state["baseline"], recovered)
                break
            except InterruptedRun as error:
                write_recovery(
                    self.run_dir,
                    "failed",
                    f"test-report recovery validation failed: {error}",
                )
                raise
            except ScenarioFailure as error:
                last_error = error
                if time.monotonic() >= deadline:
                    write_recovery(
                        self.run_dir,
                        "failed",
                        f"test-report recovery validation failed: {error}",
                    )
                    raise
                self.sleep(2)
        if last_error is not None:
            state["recoveryRetries"] = True
        state["recovered"] = recovered
        transition(state, expected={"recovering"}, next_phase="recovered")
        assert_no_secret_keys(state)
        atomic_write_json(self.state_path, state)
        write_recovery(
            self.run_dir,
            "passed",
            "published report and original PVC survived Caddy pod recreation",
        )

    def verify(self) -> None:
        state = transition(
            load_state(self.state_path),
            expected={"recovered"},
            next_phase="verifying",
        )
        final = self.snapshotter()
        self._assert_persisted(state["baseline"], final)
        if final["pod"]["uid"] != state["recovered"]["pod"]["uid"]:
            raise ScenarioFailure("replacement test-report pod changed before final proof")
        state["final"] = final
        transition(state, expected={"verifying"}, next_phase="verified")
        assert_no_secret_keys(state)
        atomic_write_json(self.state_path, state)
        atomic_write_json(self.evidence_path, state)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=("prepare", "recover", "verify"))
    parser.add_argument("kubeconfig")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    install_interrupt_handlers()
    run_dir = Path(os.environ["HOMELAB_TEST_RUN_DIR"])
    try:
        controller = Controller(args.kubeconfig, run_dir)
        getattr(controller, args.phase)()
    except ScenarioFailure as error:
        print(f"test-report persistence phase failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
