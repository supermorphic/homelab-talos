"""Mocked offline tests for resilience phase-controller state and cleanup."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import plex_cross_node_reschedule as plex
import qbittorrent_pod_recreation as pod_recreation
import qbittorrent_vpn_disconnect as vpn
from resilience_support import (
    InterruptedRun,
    ScenarioFailure,
    atomic_write_json,
    load_state,
    transition,
)


def pod_listing(
    name: str,
    uid: str,
    node: str,
    *,
    gluetun_started: bool = True,
    app_started: bool = True,
) -> str:
    return json.dumps(
        {
            "items": [
                {
                    "metadata": {"name": name, "uid": uid},
                    "spec": {"nodeName": node},
                    "status": {
                        "initContainerStatuses": [
                            {
                                "name": "gluetun",
                                "started": gluetun_started,
                                "state": {"running": {"startedAt": "2026-01-01T00:00:01Z"}},
                            }
                        ],
                        "containerStatuses": [
                            {
                                "name": "app",
                                "started": app_started,
                                "state": {"running": {"startedAt": "2026-01-01T00:00:02Z"}},
                            }
                        ],
                    },
                }
            ]
        }
    )


class StateTransitionTests(unittest.TestCase):
    def test_state_transitions_are_explicit_and_reject_replay(self):
        state = {"phase": "prepared"}
        transition(state, expected={"prepared"}, next_phase="observing")
        self.assertEqual(state["phase"], "observing")
        with self.assertRaises(ScenarioFailure):
            transition(state, expected={"prepared"}, next_phase="observing")

    def test_startup_order_sampling_is_python_owned(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            state_path = run_dir / "diagnostics" / pod_recreation.STATE_NAME
            atomic_write_json(
                state_path,
                {
                    "phase": "prepared",
                    "oldUid": "old-uid",
                    "oldPod": "qbit-old",
                    "preVolume": "pvc-1",
                    "marker": "/config/.probe",
                    "markerValue": "marker",
                },
            )

            def runner(argv: list[str]) -> str:
                self.assertIn("get", argv)
                return pod_listing("qbit-new", "new-uid", "nuc2")

            controller = pod_recreation.Controller(
                "kubeconfig", run_dir, runner=runner, sleep=lambda _seconds: None
            )
            controller.observe()
            state = load_state(state_path)
            self.assertEqual(state["phase"], "observed")
            self.assertEqual(state["newUid"], "new-uid")
            self.assertGreaterEqual(state["pollSamples"], 1)


class InterruptedRunTests(unittest.TestCase):
    def test_interrupted_cordon_persists_exact_recovery_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            state_path = run_dir / "diagnostics" / plex.STATE_NAME
            atomic_write_json(
                state_path,
                {
                    "phase": "prepared",
                    "originalNode": "nuc2",
                    "marker": "/config/.probe",
                },
            )

            def interrupted(_argv: list[str]) -> str:
                raise InterruptedRun("mocked signal interruption")

            controller = plex.Controller("kubeconfig", run_dir, runner=interrupted)
            with self.assertRaises(InterruptedRun):
                controller.cordon()
            state = load_state(state_path)
            self.assertEqual(state["phase"], "cordoning")
            self.assertEqual(state["cordonedNode"], "nuc2")


class CleanupTests(unittest.TestCase):
    def test_cleanup_uncordons_only_the_recorded_exact_node(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            state_path = run_dir / "diagnostics" / plex.STATE_NAME
            atomic_write_json(
                state_path,
                {
                    "phase": "cordoned",
                    "cordonedNode": "nuc2",
                    "marker": "/config/.probe",
                },
            )
            calls: list[list[str]] = []

            def runner(argv: list[str]) -> str:
                calls.append(argv)
                return ""

            plex.Controller("kubeconfig", run_dir, runner=runner).cleanup_node()
            self.assertEqual(
                calls,
                [
                    [
                        str(
                            Path(plex.__file__).resolve().parents[3]
                            / "scripts/test/actions/node-scheduling.sh"
                        ),
                        "uncordon",
                        "kubeconfig",
                        "nuc2",
                    ]
                ],
            )
            self.assertNotIn("all", calls[0])

    def test_cleanup_failure_is_persisted_and_propagated(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            atomic_write_json(
                run_dir / "diagnostics" / plex.STATE_NAME,
                {
                    "phase": "cordoned",
                    "cordonedNode": "nuc3",
                    "marker": "/config/.probe",
                },
            )

            def failing(_argv: list[str]) -> str:
                raise ScenarioFailure("mocked uncordon failure")

            with self.assertRaises(ScenarioFailure):
                plex.Controller("kubeconfig", run_dir, runner=failing).cleanup_node()
            recovery = json.loads((run_dir / "recovery.json").read_text(encoding="utf-8"))
            self.assertEqual(recovery["status"], "failed")
            self.assertIn("nuc3", recovery["reason"])


class SecretPersistenceTests(unittest.TestCase):
    def test_vpn_api_key_is_used_in_memory_but_never_persisted(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            observed_secret = False

            def runner(argv: list[str]) -> str:
                nonlocal observed_secret
                command = " ".join(argv)
                if "get pods" in command:
                    return pod_listing("qbit-0", "uid-0", "nuc1")
                if "grep -E" in command:
                    return "super-secret-api-key\n"
                if "/v1/vpn/status" in command:
                    observed_secret = "super-secret-api-key" in command
                    return '{"status":"running"}'
                if "/v1/publicip/ip" in command:
                    return '{"public_ip":"198.51.100.7"}'
                if "vpndis-wan-" in command:
                    return "203.0.113.9\n"
                return ""

            vpn.Controller("kubeconfig", run_dir, runner=runner).baseline()
            self.assertTrue(observed_secret)
            persisted = "\n".join(
                path.read_text(encoding="utf-8") for path in run_dir.rglob("*.json")
            )
            self.assertNotIn("super-secret-api-key", persisted)
            self.assertNotIn("apikey", persisted.lower())

    def test_recovery_validation_preserves_pre_verification_phase(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            state_path = run_dir / "diagnostics" / vpn.STATE_NAME
            atomic_write_json(state_path, {"phase": "fail-closed"})

            def runner(argv: list[str]) -> str:
                command = " ".join(argv)
                if "get pods" in command:
                    return pod_listing("qbit-recovered", "uid-new", "nuc3")
                if "grep -E" in command:
                    return "in-memory-key\n"
                if "/v1/vpn/status" in command:
                    return '{"status":"running"}'
                if "/v1/publicip/ip" in command:
                    return '{"public_ip":"198.51.100.8"}'
                return ""

            vpn.Controller("kubeconfig", run_dir, runner=runner).cleanup()
            state = load_state(state_path)
            self.assertEqual(state["phase"], "fail-closed")
            self.assertEqual(state["recoveryValidation"]["recoveryPod"], "qbit-recovered")


if __name__ == "__main__":
    unittest.main()
