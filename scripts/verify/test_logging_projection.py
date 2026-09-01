"""Contract tests for the logging verifier JSON projection boundary."""

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from logging_projection import ProjectionError, main, project


class LoggingProjectionTest(unittest.TestCase):
    # Each test names a production change that must make it fail: accepting an
    # incomplete or ambiguous response, or changing the stable compact result.
    def test_topology_projects_sorted_ready_pod_nodes(self) -> None:
        result = project(
            "topology",
            {
                "items": [
                    {
                        "metadata": {"deletionTimestamp": ""},
                        "spec": {"nodeName": "node-b"},
                        "status": {
                            "conditions": [{"type": "Ready", "status": "True"}],
                            "phase": "Running",
                        },
                    },
                    {
                        "metadata": {},
                        "spec": {"nodeName": "node-a"},
                        "status": {
                            "conditions": [{"type": "Ready", "status": "True"}],
                            "phase": "Running",
                        },
                    },
                ]
            },
        )
        self.assertEqual(
            result,
            {
                "pods": [
                    {"deleting": False, "node": "node-a", "ready": True, "running": True},
                    {"deleting": False, "node": "node-b", "ready": True, "running": True},
                ]
            },
        )

    def test_storage_projects_sorted_claim_fields(self) -> None:
        result = project(
            "storage",
            {
                "items": [
                    {
                        "metadata": {
                            "labels": {"recurring-job.longhorn.io/a": "enabled"},
                            "name": "claim-b",
                        },
                        "spec": {
                            "resources": {"requests": {"storage": "50Gi"}},
                            "volumeName": "pv-b",
                        },
                        "status": {"phase": "Bound"},
                    },
                    {
                        "metadata": {"name": "claim-a"},
                        "spec": {"resources": {"requests": {"storage": "1Gi"}}},
                        "status": {"phase": "Pending"},
                    },
                ]
            },
        )
        self.assertEqual(result["claims"][0]["name"], "claim-a")
        self.assertEqual(
            result["claims"][1]["recurring_labels"], ["recurring-job.longhorn.io/a=enabled"]
        )

    def test_runtime_limits_projects_tenant_and_resolved_config(self) -> None:
        self.assertEqual(
            project(
                "runtime-limits",
                {
                    "discover_service_name": [],
                    "retention_period": "2w",
                    "retention_stream": [],
                },
            ),
            {
                "discover_service_name_disabled": True,
                "retention_period": "2w",
                "retention_stream_count": 0,
            },
        )
        self.assertEqual(
            project("runtime-limits", {"limits_config": {"shard_streams": {"enabled": False}}}),
            {"shard_streams_enabled": False},
        )

    def test_labels_are_sorted_and_unique(self) -> None:
        self.assertEqual(
            project("labels", {"status": "success", "data": ["source", "app", "source"]}),
            {"labels": ["app", "source"]},
        )

    def test_counts_projects_positive_finite_value(self) -> None:
        self.assertEqual(
            project(
                "counts",
                {
                    "status": "success",
                    "data": {"resultType": "vector", "result": [{"value": [1, "7"]}]},
                },
            ),
            {"count": 7.0},
        )

    def test_targets_projects_sorted_target_identity(self) -> None:
        self.assertEqual(
            project(
                "targets",
                {
                    "status": "success",
                    "data": {
                        "activeTargets": [
                            {
                                "discoveredLabels": {"__meta_kubernetes_service_name": "loki"},
                                "health": "up",
                                "labels": {"job": "monitoring/loki", "service": "loki"},
                                "lastError": "",
                                "scrapePool": "serviceMonitor/monitoring/loki/0",
                            }
                        ]
                    },
                },
            ),
            {
                "targets": [
                    {
                        "health": "up",
                        "last_error": "",
                        "job": "monitoring/loki",
                        "service": "loki",
                        "service_name": "loki",
                        "scrape_pool": "serviceMonitor/monitoring/loki/0",
                    }
                ]
            },
        )

    def test_compaction_projects_finite_value(self) -> None:
        self.assertEqual(
            project(
                "compaction",
                {
                    "status": "success",
                    "data": {"resultType": "vector", "result": [{"value": [1, "600"]}]},
                },
            ),
            {"age_seconds": 600.0},
        )

    def test_rules_projects_sorted_rules(self) -> None:
        self.assertEqual(
            project(
                "rules",
                {
                    "status": "success",
                    "data": {
                        "groups": [
                            {
                                "rules": [
                                    {"health": "ok", "lastError": "", "name": "RuleB"},
                                    {"health": "ok", "lastError": "", "name": "RuleA"},
                                ]
                            }
                        ]
                    },
                },
            ),
            {
                "rules": [
                    {"health": "ok", "last_error": "", "name": "RuleA"},
                    {"health": "ok", "last_error": "", "name": "RuleB"},
                ]
            },
        )

    def test_rejects_wrong_top_level_type(self) -> None:
        with self.assertRaisesRegex(ProjectionError, "invalid labels response: expected object"):
            project("labels", [])

    def test_rejects_missing_required_field(self) -> None:
        with self.assertRaisesRegex(ProjectionError, "invalid labels response: missing data"):
            project("labels", {"status": "success"})

    def test_rejects_duplicate_target_identity(self) -> None:
        target = {
            "discoveredLabels": {"__meta_kubernetes_service_name": "loki"},
            "health": "up",
            "labels": {"job": "monitoring/loki", "service": "loki"},
            "lastError": "",
            "scrapePool": "serviceMonitor/monitoring/loki/0",
        }
        with self.assertRaisesRegex(ProjectionError, "invalid targets response: duplicate target"):
            project("targets", {"status": "success", "data": {"activeTargets": [target, target]}})

    def test_rejects_negative_count(self) -> None:
        with self.assertRaisesRegex(
            ProjectionError, "invalid counts response: count must be positive"
        ):
            project(
                "counts",
                {
                    "status": "success",
                    "data": {"resultType": "vector", "result": [{"value": [1, "-1"]}]},
                },
            )

    def test_rejects_non_finite_number(self) -> None:
        with self.assertRaisesRegex(
            ProjectionError, "invalid compaction response: age must be finite"
        ):
            project(
                "compaction",
                {
                    "status": "success",
                    "data": {"resultType": "vector", "result": [{"value": [1, "NaN"]}]},
                },
            )

    def test_error_does_not_echo_private_value(self) -> None:
        with self.assertRaisesRegex(ProjectionError, "invalid labels response") as raised:
            project("labels", {"private-node-identity": object()})
        self.assertNotIn("private-node-identity", str(raised.exception))

    def test_cli_outputs_stable_compact_json_and_redacts_invalid_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            input_path = Path(temporary_directory) / "response.json"
            input_path.write_text('{"status":"success","data":["source","app"]}', encoding="utf-8")
            stdout = io.StringIO()
            with contextlib.redirect_stdout(stdout):
                self.assertEqual(main(["--kind", "labels", "--input", str(input_path)]), 0)
            self.assertEqual(stdout.getvalue(), '{"labels":["app","source"]}\n')

            input_path.write_text('{"private-node-identity":', encoding="utf-8")
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.assertEqual(main(["--kind", "labels", "--input", str(input_path)]), 1)
            self.assertEqual(stderr.getvalue(), "invalid labels response: invalid JSON\n")


if __name__ == "__main__":
    unittest.main()
