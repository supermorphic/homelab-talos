"""Mocked offline tests for resilience phase-controller state and cleanup."""

from __future__ import annotations

import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import node_abrupt_loss as abrupt
import plex_cross_node_reschedule as plex
import qbittorrent_pod_recreation as pod_recreation
import qbittorrent_vpn_disconnect as vpn
import test_reports_persistence as reports
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


class AbruptNodeLossTests(unittest.TestCase):
    class Clock:
        def __init__(self) -> None:
            self.value = 0.0

        def now(self) -> float:
            return self.value

        def sleep(self, seconds: float) -> None:
            self.value += seconds

    class Monitor:
        def __init__(self, events: list[str]) -> None:
            self.events = events

        def start(self) -> None:
            self.events.append("probes-start")

        def stop(self) -> list[dict[str, object]]:
            self.events.append("probes-stop")
            return [{"api": True, "dns": True, "https": True, "at": 0.0}]

    def test_external_monitor_records_five_second_samples_and_sixty_second_slo(self):
        clock = self.Clock()
        results = {"api": (1, ""), "dns": (0, "192.0.2.10\n"), "https": (0, "ok\n")}

        def status_runner(argv: list[str]) -> tuple[int, str]:
            if argv[0] == "kubectl":
                return results["api"]
            if argv[0] == "dig":
                return results["dns"]
            return results["https"]

        monitor = abrupt.ExternalProbeMonitor(
            "kubeconfig",
            status_runner=status_runner,
            interval=5,
            no_success_limit=60,
            monotonic=clock.now,
        )
        monitor._sample()
        clock.sleep(55)
        monitor._sample()
        self.assertEqual(monitor.violations(), [])
        clock.sleep(5)
        monitor._sample()
        self.assertEqual(monitor.violations(), ["api"])
        self.assertEqual(monitor.interval, 5)
        self.assertTrue(
            all(set(sample) == {"at", "api", "dns", "https"} for sample in monitor.samples)
        )

    def test_baseline_records_owned_workloads_claim_identity_and_off_target_replica(self):
        with tempfile.TemporaryDirectory() as temporary:
            objects = {
                "nodes": {
                    "items": [{"metadata": {"name": name}} for name in ("nuc1", "nuc2", "nuc3")]
                },
                "pods": {
                    "items": [
                        {
                            "metadata": {
                                "name": "plex-abc",
                                "namespace": "media",
                                "uid": "pod-old",
                                "ownerReferences": [
                                    {
                                        "kind": "ReplicaSet",
                                        "name": "plex",
                                        "uid": "rs-uid",
                                        "controller": True,
                                    }
                                ],
                            },
                            "spec": {
                                "nodeName": "nuc1",
                                "volumes": [
                                    {
                                        "name": "config",
                                        "persistentVolumeClaim": {"claimName": "plex-config"},
                                    }
                                ],
                            },
                        },
                        {
                            "metadata": {
                                "name": "cilium-old",
                                "namespace": "kube-system",
                                "ownerReferences": [
                                    {"kind": "DaemonSet", "name": "cilium", "uid": "ds-uid"}
                                ],
                            },
                            "spec": {"nodeName": "nuc1"},
                        },
                    ]
                },
                "replicas": {
                    "items": [
                        {"spec": {"volumeName": "lh-volume", "nodeID": "nuc1", "failedAt": ""}},
                        {"spec": {"volumeName": "lh-volume", "nodeID": "nuc2", "failedAt": ""}},
                    ]
                },
                "pvcs": {
                    "items": [
                        {
                            "metadata": {
                                "name": "plex-config",
                                "namespace": "media",
                                "uid": "pvc-uid",
                            },
                            "spec": {"volumeName": "pv-plex"},
                        }
                    ]
                },
                "pvs": {
                    "items": [
                        {
                            "metadata": {"name": "pv-plex", "uid": "pv-uid"},
                            "spec": {"csi": {"volumeHandle": "lh-volume"}},
                        }
                    ]
                },
            }

            def status_runner(argv: list[str]) -> tuple[int, str]:
                resource = argv[argv.index("get") + 1]
                key = {
                    "nodes": "nodes",
                    "pods": "pods",
                    "replicas.longhorn.io": "replicas",
                    "persistentvolumeclaims": "pvcs",
                    "persistentvolumes": "pvs",
                }[resource]
                return 0, json.dumps(objects[key])

            controller = abrupt.Controller(
                "nuc1",
                "kubeconfig",
                "talosconfig",
                Path(temporary),
                runner=lambda argv: "",
                status_runner=status_runner,
                monitor=self.Monitor([]),
            )
            baseline = controller._baseline()
            self.assertEqual(len(baseline["targetWorkloads"]), 1)
            self.assertEqual(baseline["targetWorkloads"][0]["ownerUid"], "rs-uid")
            self.assertEqual(
                baseline["affectedClaims"],
                [
                    {
                        "namespace": "media",
                        "name": "plex-config",
                        "uid": "pvc-uid",
                        "volumeName": "pv-plex",
                        "volumeUid": "pv-uid",
                        "longhornVolume": "lh-volume",
                    }
                ],
            )

    def test_loss_is_unprepared_then_contained_observed_and_recovered(self):
        with tempfile.TemporaryDirectory() as temporary:
            events: list[str] = []
            clock = self.Clock()
            observations = iter(
                [
                    {
                        "talosLost": False,
                        "nodeNotReady": False,
                        "etcdTargetLost": False,
                        "quorumRetained": True,
                    },
                    {
                        "talosLost": True,
                        "nodeNotReady": True,
                        "etcdTargetLost": True,
                        "quorumRetained": True,
                    },
                    {
                        "talosLost": True,
                        "nodeNotReady": True,
                        "etcdTargetLost": True,
                        "quorumRetained": True,
                        "readySurvivors": 2,
                        "readyCiliumSurvivors": 2,
                        "workloads": [
                            {
                                "namespace": "media",
                                "ownerKind": "ReplicaSet",
                                "ownerName": "plex",
                                "state": "ready-on-survivor",
                            }
                        ],
                        "storage": {"survivingReplicaAvailable": True, "fullReplicaCount": False},
                    },
                ]
            )

            def baseline() -> dict[str, object]:
                events.append("baseline")
                return {"healthy": True}

            def observe() -> dict[str, object]:
                events.append("observe")
                try:
                    return next(observations)
                except StopIteration:
                    return {
                        "talosLost": True,
                        "nodeNotReady": True,
                        "etcdTargetLost": True,
                        "quorumRetained": True,
                        "readySurvivors": 2,
                        "readyCiliumSurvivors": 2,
                        "workloads": [],
                        "storage": {"survivingReplicaAvailable": True, "fullReplicaCount": False},
                    }

            def bridge(action: str) -> None:
                events.append(f"bridge:{action}")

            def prompt(message: str) -> str:
                events.append(
                    "prompt:disconnect" if "disconnect" in message.lower() else "prompt:restore"
                )
                return ""

            controller = abrupt.Controller(
                "nuc1",
                "kubeconfig",
                "talosconfig",
                Path(temporary),
                baseline=baseline,
                observe=observe,
                bridge=bridge,
                prompt=prompt,
                monotonic=clock.now,
                sleep=clock.sleep,
                monitor=self.Monitor(events),
                loss_timeout=15,
                passive_seconds=10,
                poll_seconds=5,
            )
            with patch.dict(
                os.environ,
                {
                    "CLUSTER_CHAOS_CONFIRM": "chaos:node-abrupt-loss",
                    "NODE_ABRUPT_LOSS_CONFIRM": "remove-power:nuc1:192.168.90.10",
                },
            ):
                controller.run()

            self.assertLess(events.index("prompt:disconnect"), events.index("bridge:contain"))
            self.assertGreaterEqual(events[: events.index("bridge:contain")].count("observe"), 2)
            self.assertLess(events.index("bridge:contain"), events.index("prompt:restore"))
            self.assertLess(events.index("prompt:restore"), events.index("bridge:recover"))
            state = load_state(Path(temporary) / "diagnostics" / abrupt.STATE_NAME)
            self.assertEqual(state["phase"], "recovered")
            self.assertFalse(state["passiveObservation"][-1]["storage"]["fullReplicaCount"])
            self.assertEqual(state["workloadRecoverySeconds"]["media/ReplicaSet/plex"], 0.0)

    def test_wrong_target_confirmation_stops_before_power_prompt(self):
        with tempfile.TemporaryDirectory() as temporary:
            events: list[str] = []
            controller = abrupt.Controller(
                "nuc2",
                "kubeconfig",
                "talosconfig",
                Path(temporary),
                baseline=lambda: {"healthy": True},
                observe=dict,
                bridge=lambda action: events.append(action),
                prompt=lambda message: events.append(message) or "",
                monitor=self.Monitor(events),
            )
            with (
                patch.dict(
                    os.environ,
                    {
                        "CLUSTER_CHAOS_CONFIRM": "chaos:node-abrupt-loss",
                        "NODE_ABRUPT_LOSS_CONFIRM": "remove-power:nuc1:192.168.90.10",
                    },
                ),
                self.assertRaisesRegex(ScenarioFailure, "confirmation"),
            ):
                controller.run()
            self.assertEqual(events, [])

    def test_detection_failure_requests_power_restoration_without_false_rollback(self):
        with tempfile.TemporaryDirectory() as temporary:
            events: list[str] = []
            clock = self.Clock()
            controller = abrupt.Controller(
                "nuc3",
                "kubeconfig",
                "talosconfig",
                Path(temporary),
                baseline=lambda: {"healthy": True},
                observe=lambda: {
                    "talosLost": True,
                    "nodeNotReady": True,
                    "etcdTargetLost": False,
                    "quorumRetained": True,
                },
                bridge=lambda action: events.append(f"bridge:{action}"),
                prompt=lambda message: (
                    events.append("restore" if "restore" in message.lower() else "disconnect")
                    or ""
                ),
                monotonic=clock.now,
                sleep=clock.sleep,
                monitor=self.Monitor(events),
                loss_timeout=10,
                poll_seconds=5,
            )
            with (
                patch.dict(
                    os.environ,
                    {
                        "CLUSTER_CHAOS_CONFIRM": "chaos:node-abrupt-loss",
                        "NODE_ABRUPT_LOSS_CONFIRM": "remove-power:nuc3:192.168.90.12",
                    },
                ),
                self.assertRaisesRegex(ScenarioFailure, "genuine node loss"),
            ):
                controller.run()
            self.assertIn("restore", events)
            self.assertNotIn("bridge:contain", events)
            recovery = json.loads((Path(temporary) / "recovery.json").read_text())
            self.assertEqual(recovery["status"], "failed")
            self.assertIn("unresolved", recovery["reason"])

    def test_prompt_failure_before_disruption_reports_no_recovery_needed(self):
        with tempfile.TemporaryDirectory() as temporary:
            events: list[str] = []
            controller = abrupt.Controller(
                "nuc1",
                "kubeconfig",
                "talosconfig",
                Path(temporary),
                baseline=lambda: {"healthy": True},
                observe=dict,
                bridge=lambda action: events.append(action),
                prompt=lambda _message: (_ for _ in ()).throw(EOFError("no input")),
                monitor=self.Monitor(events),
            )
            with (
                patch.dict(
                    os.environ,
                    {
                        "CLUSTER_CHAOS_CONFIRM": "chaos:node-abrupt-loss",
                        "NODE_ABRUPT_LOSS_CONFIRM": "remove-power:nuc1:192.168.90.10",
                    },
                ),
                self.assertRaisesRegex(ScenarioFailure, "no input"),
            ):
                controller.run()
            recovery = json.loads((Path(temporary) / "recovery.json").read_text())
            self.assertEqual(recovery["status"], "passed")
            self.assertIn("before disruption", recovery["reason"])
            self.assertNotIn("contain", events)

    def test_failed_recovery_is_not_retried_inside_the_same_transaction(self):
        with tempfile.TemporaryDirectory() as temporary:
            events: list[str] = []
            clock = self.Clock()

            def bridge(action: str) -> None:
                events.append(action)
                if action == "recover":
                    raise ScenarioFailure("acceptance failed")

            observation = {
                "talosLost": True,
                "nodeNotReady": True,
                "etcdTargetLost": True,
                "quorumRetained": True,
                "readySurvivors": 2,
                "readyCiliumSurvivors": 2,
                "storage": {"survivingReplicaAvailable": True},
            }
            controller = abrupt.Controller(
                "nuc2",
                "kubeconfig",
                "talosconfig",
                Path(temporary),
                baseline=lambda: {"healthy": True},
                observe=lambda: observation,
                bridge=bridge,
                prompt=lambda _message: "",
                monotonic=clock.now,
                sleep=clock.sleep,
                monitor=self.Monitor(events),
                passive_seconds=5,
                poll_seconds=5,
            )
            with (
                patch.dict(
                    os.environ,
                    {
                        "CLUSTER_CHAOS_CONFIRM": "chaos:node-abrupt-loss",
                        "NODE_ABRUPT_LOSS_CONFIRM": "remove-power:nuc2:192.168.90.11",
                    },
                ),
                self.assertRaisesRegex(ScenarioFailure, "acceptance failed"),
            ):
                controller.run()
            self.assertEqual(events.count("recover"), 1)
            recovery = json.loads((Path(temporary) / "recovery.json").read_text())
            self.assertEqual(recovery["status"], "failed")
            self.assertIn("pending", recovery["reason"])


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


def report_snapshot(
    pod_uid: str,
    *,
    pvc_uid: str = "pvc-uid",
    volume: str = "pvc-volume",
    report_digest: str = "a" * 64,
    artifact_digest: str = "b" * 64,
) -> dict[str, object]:
    return {
        "pod": {"name": f"test-reports-{pod_uid}", "uid": pod_uid, "node": "nuc2"},
        "pvc": {"uid": pvc_uid, "volume": volume},
        "generation": "generations/20260727T220000Z-deadbeef",
        "reportIndexSha256": report_digest,
        "artifactSha256": artifact_digest,
        "catalogEntry": {
            "runId": "20260727T220000Z-aaaaaaaaaaaa-operator-deadbeef",
            "gitSha": "a" * 40,
            "result": "passed",
            "authoritative": True,
        },
        "observedAt": "2026-07-27T22:00:00Z",
    }


class TestReportPersistenceTests(unittest.TestCase):
    run_id = "20260727T220000Z-aaaaaaaaaaaa-operator-deadbeef"

    def test_exact_report_and_pvc_survive_replacement(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            snapshots = iter(
                [
                    report_snapshot("old-uid"),
                    report_snapshot("new-uid"),
                    report_snapshot("new-uid"),
                ]
            )
            controller = reports.Controller(
                "kubeconfig",
                run_dir,
                run_id=self.run_id,
                snapshotter=lambda: next(snapshots),
            )
            controller.prepare()
            controller.recover()
            controller.verify()
            state = load_state(run_dir / "diagnostics" / reports.STATE_NAME)
            self.assertEqual(state["phase"], "verified")
            self.assertEqual(state["baseline"]["pod"]["uid"], "old-uid")
            self.assertEqual(state["final"]["pod"]["uid"], "new-uid")
            recovery = json.loads((run_dir / "recovery.json").read_text())
            self.assertEqual(recovery["status"], "passed")
            self.assertTrue((run_dir / "diagnostics" / reports.EVIDENCE_NAME).is_file())

    def test_unchanged_pod_identity_fails_recovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            snapshots = iter(
                [
                    report_snapshot("same-uid"),
                    report_snapshot("same-uid"),
                ]
            )
            controller = reports.Controller(
                "kubeconfig",
                run_dir,
                run_id=self.run_id,
                snapshotter=lambda: next(snapshots),
                timeout=0,
            )
            controller.prepare()
            with self.assertRaisesRegex(
                ScenarioFailure,
                "pod identity did not change",
            ):
                controller.recover()
            recovery = json.loads((run_dir / "recovery.json").read_text())
            self.assertEqual(recovery["status"], "failed")

    def test_interrupted_recovery_is_failed_and_propagated(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            calls = 0

            def snapshotter() -> dict[str, object]:
                nonlocal calls
                calls += 1
                if calls == 1:
                    return report_snapshot("old-uid")
                raise InterruptedRun("mocked persistence interruption")

            controller = reports.Controller(
                "kubeconfig",
                run_dir,
                run_id=self.run_id,
                snapshotter=snapshotter,
            )
            controller.prepare()
            with self.assertRaises(InterruptedRun):
                controller.recover()
            recovery = json.loads((run_dir / "recovery.json").read_text())
            self.assertEqual(recovery["status"], "failed")

    def test_persistence_evidence_contains_no_secret_like_keys(self):
        with tempfile.TemporaryDirectory() as temporary:
            run_dir = Path(temporary)
            snapshots = iter(
                [
                    report_snapshot("old-uid"),
                    report_snapshot("new-uid"),
                    report_snapshot("new-uid"),
                ]
            )
            controller = reports.Controller(
                "kubeconfig",
                run_dir,
                run_id=self.run_id,
                snapshotter=lambda: next(snapshots),
            )
            controller.prepare()
            controller.recover()
            controller.verify()
            persisted = (run_dir / "diagnostics" / reports.EVIDENCE_NAME).read_text()
            for forbidden in ("apikey", "api_key", "secret", "password", "token"):
                self.assertNotIn(forbidden, persisted.lower())


if __name__ == "__main__":
    unittest.main()
