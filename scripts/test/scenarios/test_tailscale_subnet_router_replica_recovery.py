"""Offline tests for the Tailscale subnet-router replica-recovery controller."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import tailscale_subnet_router_replica_recovery as tailscale
from resilience_support import ScenarioFailure


def pod(
    name: str,
    uid: str,
    node: str,
    *,
    ready: bool = True,
    deleting: bool = False,
) -> dict[str, object]:
    metadata = {"name": name, "uid": uid}
    if deleting:
        metadata["deletionTimestamp"] = "2026-07-29T12:00:00Z"
    return {
        "metadata": metadata,
        "spec": {"nodeName": node},
        "status": {
            "conditions": [
                {"type": "Ready", "status": "True" if ready else "False"},
            ]
        },
    }


class PureHelperTests(unittest.TestCase):
    def test_pod_activity_and_readiness(self):
        healthy = pod("router-0", "uid-0", "nuc1")
        terminating = pod("router-1", "uid-1", "nuc2", deleting=True)
        unready = pod("router-2", "uid-2", "nuc3", ready=False)

        self.assertTrue(tailscale.is_active(healthy))
        self.assertFalse(tailscale.is_active(terminating))
        self.assertTrue(tailscale.is_ready(healthy))
        self.assertFalse(tailscale.is_ready(unready))
        self.assertFalse(tailscale.is_ready({"status": {"conditions": []}}))
        self.assertEqual(tailscale.active_ready_pods([healthy, terminating, unready]), [healthy])

    def test_node_names_ignore_unscheduled_pods_and_deduplicate(self):
        pods = [
            pod("router-0", "uid-0", "nuc1"),
            pod("router-1", "uid-1", "nuc1"),
            pod("router-2", "uid-2", ""),
        ]
        self.assertEqual(tailscale.node_names(pods), {"nuc1"})

    def test_connector_readiness_and_advertised_routes(self):
        ready = {
            "spec": {
                "subnetRouter": {
                    "advertiseRoutes": ["192.168.90.30/32", "192.168.90.2/32"],
                }
            },
            "status": {
                "conditions": [
                    {"type": "ConnectorReady", "status": "True"},
                ]
            },
        }
        unready = {
            "status": {
                "conditions": [
                    {"type": "ConnectorReady", "status": "False"},
                ]
            }
        }

        self.assertTrue(tailscale.connector_ready(ready))
        self.assertFalse(tailscale.connector_ready(unready))
        self.assertFalse(tailscale.connector_ready({}))
        self.assertEqual(
            tailscale.advertised_routes(ready),
            ["192.168.90.2/32", "192.168.90.30/32"],
        )

    def test_device_and_pod_identities_are_stable_and_secret_free(self):
        connector = {
            "status": {
                "devices": [
                    {
                        "hostname": "router-b",
                        "tailnetIPs": ["fd7a:115c:a1e0::2", "100.64.0.2"],
                    },
                    {
                        "hostname": "router-a",
                        "tailnetIPs": ["100.64.0.1"],
                    },
                    "ignored-non-object",
                ]
            }
        }
        self.assertEqual(
            tailscale.device_identities(connector),
            [
                {"hostname": "router-a", "tailnetIPs": ["100.64.0.1"]},
                {
                    "hostname": "router-b",
                    "tailnetIPs": ["100.64.0.2", "fd7a:115c:a1e0::2"],
                },
            ],
        )
        self.assertEqual(
            tailscale.pod_identity(pod("router-0", "uid-0", "nuc1")),
            {"name": "router-0", "uid": "uid-0", "node": "nuc1"},
        )


class RecoveryPollingTests(unittest.TestCase):
    def test_cleanup_waits_for_recovery_before_recording_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            attempts = 0

            def runner(argv: list[str]) -> str:
                nonlocal attempts
                command = " ".join(argv)
                if "get pods" in command:
                    attempts += 1
                    items = [pod("router-0", "uid-0", "nuc1")]
                    if attempts > 1:
                        items.append(pod("router-1", "uid-1", "nuc2"))
                    return json.dumps({"items": items})
                if "get node nuc1" in command or "get node nuc2" in command:
                    return json.dumps(
                        {
                            "status": {
                                "conditions": [
                                    {"type": "Ready", "status": "True"},
                                ]
                            }
                        }
                    )
                if "get connector lab-subnet-router" in command:
                    return json.dumps(
                        {
                            "status": {
                                "conditions": [
                                    {"type": "ConnectorReady", "status": "True"},
                                ]
                            }
                        }
                    )
                raise AssertionError(f"unexpected command: {command}")

            controller = tailscale.Controller(
                "kubeconfig",
                run_dir,
                runner=runner,
                sleep=lambda _seconds: None,
                clock=iter((0, 0, 1)).__next__,
                timeout=5,
            )
            controller.cleanup()

            self.assertEqual(attempts, 2)
            recovery = json.loads((run_dir / "recovery.json").read_text(encoding="utf-8"))
            self.assertEqual(recovery["status"], "passed")

    def test_cleanup_records_failure_after_timeout(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            controller = tailscale.Controller(
                "kubeconfig",
                run_dir,
                runner=lambda _argv: json.dumps({"items": []}),
                sleep=lambda _seconds: None,
                clock=iter((0, 0, 5)).__next__,
                timeout=5,
            )

            with self.assertRaises(ScenarioFailure):
                controller.cleanup()

            recovery = json.loads((run_dir / "recovery.json").read_text(encoding="utf-8"))
            self.assertEqual(recovery["status"], "failed")
            self.assertIn("2/2 steady state", recovery["reason"])
