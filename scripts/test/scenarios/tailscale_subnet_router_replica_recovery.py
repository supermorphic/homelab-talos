#!/usr/bin/env python3
"""Structured phases for the Tailscale subnet-router replica-recovery resilience test.

Contract: a single lab-subnet-router Connector replica may be lost while at least one
replica remains available, and the Tailscale Operator returns the Connector to its declared
two-replica, cross-node steady state. This is replica degradation/recovery — NOT data-plane
failover (that needs a tailnet client sentinel and is out of scope). Route approval is
control-plane state outside Kubernetes and is not asserted here.
"""

from __future__ import annotations

import argparse
import os
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
    run_command,
    transition,
    utc_now,
    write_recovery,
)

NAMESPACE = "tailscale"
SELECTOR = "tailscale.supermorphic.com/component=lab-subnet-router"
CONNECTOR = "lab-subnet-router"
STATE_NAME = "tailscale-subnet-router-replica-recovery-state.json"
# HADegraded has `for: 15m`; a healthy reschedule recovers in well under a minute, so the
# alert is expected NOT to fire. promtool (validation.tailscale-alerts) proves it WOULD fire
# if degradation persisted; we record the expectation as evidence, never as a pass gate.
HADEGRADED_FOR_SECONDS = 15 * 60


# --- pure helpers (unit-tested offline; take plain dicts, never touch kubectl) --------------


def is_active(pod: dict[str, Any]) -> bool:
    return not pod.get("metadata", {}).get("deletionTimestamp")


def is_ready(pod: dict[str, Any]) -> bool:
    for condition in pod.get("status", {}).get("conditions", []):
        if condition.get("type") == "Ready":
            return condition.get("status") == "True"
    return False


def active_ready_pods(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [pod for pod in items if is_active(pod) and is_ready(pod)]


def node_names(pods: list[dict[str, Any]]) -> set[str]:
    return {pod.get("spec", {}).get("nodeName", "") for pod in pods} - {""}


def connector_ready(connector: dict[str, Any]) -> bool:
    for condition in connector.get("status", {}).get("conditions", []):
        if condition.get("type") == "ConnectorReady":
            return condition.get("status") == "True"
    return False


def advertised_routes(connector: dict[str, Any]) -> list[str]:
    return sorted(connector.get("spec", {}).get("subnetRouter", {}).get("advertiseRoutes", []))


def device_identities(connector: dict[str, Any]) -> list[dict[str, Any]]:
    devices = connector.get("status", {}).get("devices", []) or []
    return sorted(
        (
            {"hostname": d.get("hostname"), "tailnetIPs": sorted(d.get("tailnetIPs", []) or [])}
            for d in devices
            if isinstance(d, dict)
        ),
        key=lambda d: d.get("hostname") or "",
    )


def pod_identity(pod: dict[str, Any]) -> dict[str, Any]:
    meta = pod.get("metadata", {})
    return {
        "name": meta.get("name"),
        "uid": meta.get("uid"),
        "node": pod.get("spec", {}).get("nodeName"),
    }


class Controller:
    def __init__(
        self,
        kubeconfig: str,
        run_dir: Path,
        *,
        runner: Runner = run_command,
        sleep: Any = time.sleep,
        clock: Any = time.monotonic,
        timeout: int = 300,
    ):
        self.kubeconfig = kubeconfig
        self.run_dir = run_dir
        self.runner = runner
        self.sleep = sleep
        self.clock = clock
        self.timeout = timeout
        self.state_path = run_dir / "diagnostics" / STATE_NAME

    def _pods(self) -> list[dict[str, Any]]:
        listing = kubectl_json(
            self.runner,
            self.kubeconfig,
            NAMESPACE,
            ["get", "pods", "-l", SELECTOR, "-o", "json"],
        )
        return [p for p in listing.get("items", []) if isinstance(p, dict)]

    def _connector(self) -> dict[str, Any]:
        # Connector is cluster-scoped (no namespace).
        return kubectl_json(
            self.runner,
            self.kubeconfig,
            None,
            ["get", "connector", CONNECTOR, "-o", "json"],
        )

    def _node_ready(self, node: str) -> bool:
        obj = kubectl_json(self.runner, self.kubeconfig, None, ["get", "node", node, "-o", "json"])
        for condition in obj.get("status", {}).get("conditions", []):
            if condition.get("type") == "Ready":
                return condition.get("status") == "True"
        return False

    def _require_steady(self) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        """Return (2 ready pods on 2 distinct ready nodes, ConnectorReady) or raise."""
        pods = active_ready_pods(self._pods())
        if len(pods) != 2:
            raise ScenarioFailure(f"expected 2 Ready subnet-router pods, found {len(pods)}")
        nodes = node_names(pods)
        if len(nodes) != 2:
            raise ScenarioFailure(f"expected 2 distinct nodes, found {sorted(nodes)}")
        for node in nodes:
            if not self._node_ready(node):
                raise ScenarioFailure(f"node {node} is not Ready")
        connector = self._connector()
        if not connector_ready(connector):
            raise ScenarioFailure("Connector is not ConnectorReady")
        return pods, connector

    def _wait_for_steady(self) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        deadline = self.clock() + self.timeout
        last_error: ScenarioFailure | None = None
        while self.clock() < deadline:
            try:
                return self._require_steady()
            except ScenarioFailure as error:
                last_error = error
                self.sleep(5)
        detail = f": {last_error}" if last_error else ""
        raise ScenarioFailure(
            f"Connector did not recover to 2 Ready pods on 2 nodes in time{detail}"
        )

    def baseline(self) -> None:
        # Precondition gate: refuse to mutate unless the system is fully healthy, so a
        # one-replica disruption can never turn into full routing loss.
        pods, connector = self._require_steady()
        ordered = sorted(pods, key=lambda p: p["metadata"]["name"])
        victim, survivor = ordered[0], ordered[1]
        state = {
            "schemaVersion": 1,
            "scenario": "tailscale-subnet-router-replica-recovery",
            "phase": "baseline",
            "baselineAt": utc_now(),
            "victim": pod_identity(victim),
            "survivor": pod_identity(survivor),
            "advertiseRoutes": advertised_routes(connector),
            "devicesBefore": device_identities(connector),
        }
        atomic_write_json(self.state_path, state)
        write_recovery(self.run_dir, "not-attempted", "baseline healthy; disruption pending")
        transition(state, expected={"baseline"}, next_phase="prepared")
        atomic_write_json(self.state_path, state)

    def disrupt(self) -> None:
        state = transition(
            load_state(self.state_path), expected={"prepared"}, next_phase="disrupting"
        )
        atomic_write_json(self.state_path, state)
        victim = state["victim"]["name"]
        survivor = state["survivor"]["name"]
        self.runner(
            [
                "kubectl",
                "--kubeconfig",
                self.kubeconfig,
                "--namespace",
                NAMESPACE,
                "delete",
                "pod",
                victim,
                "--wait=false",
            ]
        )
        deleted_at = utc_now()
        # Degraded-window invariant: the SURVIVING replica must stay Ready throughout.
        deadline = self.clock() + 60
        survivor_ready_samples = 0
        while self.clock() < deadline:
            by_name = {p["metadata"]["name"]: p for p in self._pods()}
            surv = by_name.get(survivor)
            if surv is None or not is_active(surv) or not is_ready(surv):
                raise ScenarioFailure("surviving replica lost Ready during the degraded window")
            survivor_ready_samples += 1
            # Stop once the victim is gone or being recreated (degraded state observed).
            victim_pod = by_name.get(victim)
            if victim_pod is None or not is_active(victim_pod) or not is_ready(victim_pod):
                break
            self.sleep(2)
        state.update(
            {
                "deletedAt": deleted_at,
                "survivorReadySamples": survivor_ready_samples,
            }
        )
        transition(state, expected={"disrupting"}, next_phase="disrupted")
        atomic_write_json(self.state_path, state)

    def verify(self) -> None:
        state = transition(
            load_state(self.state_path), expected={"disrupted"}, next_phase="verifying"
        )
        atomic_write_json(self.state_path, state)
        pods, connector = self._wait_for_steady()
        routes = advertised_routes(connector)
        if routes != state["advertiseRoutes"]:
            raise ScenarioFailure(
                f"advertised routes changed: {state['advertiseRoutes']} -> {routes}"
            )
        recovered_at = utc_now()
        state.update(
            {
                "recoveredAt": recovered_at,
                "podsAfter": sorted(
                    (pod_identity(p) for p in pods), key=lambda p: p["name"] or ""
                ),
                "devicesAfter": device_identities(connector),
                # Evidence, NOT a pass gate: recovery is far shorter than HADegraded `for: 15m`,
                # so the alert is expected not to fire. Its logic is proven by promtool offline.
                "hadegradedForSeconds": HADEGRADED_FOR_SECONDS,
                "hadegradedAlertExpectedToFire": False,
            }
        )
        transition(state, expected={"verifying"}, next_phase="verified")
        atomic_write_json(self.state_path, state)
        atomic_write_json(self.run_dir / "evidence.json", state)

    def cleanup(self) -> None:
        try:
            self._wait_for_steady()
        except ScenarioFailure as error:
            write_recovery(
                self.run_dir, "failed", f"subnet router not at 2/2 steady state: {error}"
            )
            raise
        write_recovery(
            self.run_dir, "passed", "subnet router recovered to 2 Ready replicas on 2 nodes"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", choices=("baseline", "disrupt", "verify", "cleanup"))
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
        print(f"tailscale subnet-router replica-recovery phase failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
