"""Offline tests for Allure report staging and latest-run selection."""

from __future__ import annotations

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("allure_report.py")
SPEC = importlib.util.spec_from_file_location("allure_report", MODULE_PATH)
assert SPEC and SPEC.loader
allure_report = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(allure_report)


class AllureReportTests(unittest.TestCase):
    def make_run(
        self,
        root: Path,
        run_id: str,
        finished_at: str,
        *,
        result: str = "passed",
    ) -> Path:
        run_dir = root / run_id
        (run_dir / "logs").mkdir(parents=True)
        (run_dir / "diagnostics").mkdir()
        summary = {
            "run_id": run_id,
            "result": result,
            "end": finished_at,
            "duration_seconds": 3,
            "junit": {
                "tests": 4,
                "passed": 1,
                "failures": 1,
                "errors": 1,
                "skipped": 1,
            },
            "suites": [
                {
                    "id": "validation.fixture",
                    "result": result,
                    "tests": 4,
                    "failures": 1,
                    "errors": 1,
                    "skipped": 1,
                }
            ],
        }
        (run_dir / "summary.json").write_text(json.dumps(summary), encoding="utf-8")
        (run_dir / "environment.json").write_text("{}\n", encoding="utf-8")
        (run_dir / "junit.xml").write_text(
            '<testsuites><testsuite name="stable.suite">'
            '<testcase classname="stable.class" name="stable-case"/>'
            "</testsuite></testsuites>\n",
            encoding="utf-8",
        )
        (run_dir / "logs" / "fixture.log").write_text("sanitized fixture\n", encoding="utf-8")
        (run_dir / "diagnostics" / "native.json").write_text(
            '{"status":"passed"}\n', encoding="utf-8"
        )
        evidence = {
            "artifacts": [
                {"path": "diagnostics/native.json"},
                {"path": "logs/fixture.log"},
            ]
        }
        (run_dir / "evidence.json").write_text(json.dumps(evidence), encoding="utf-8")
        return run_dir

    def test_latest_uses_finalized_end_time_not_filesystem_mtime(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            older = self.make_run(
                root,
                "20260727T000000Z-aaaaaaaaaaaa-agent-00000001",
                "2026-07-27T00:00:01Z",
            )
            newer = self.make_run(
                root,
                "20260727T000001Z-aaaaaaaaaaaa-agent-00000002",
                "2026-07-27T00:00:02Z",
            )
            os.utime(older, (2_000_000_000, 2_000_000_000))
            os.utime(newer, (1_000_000_000, 1_000_000_000))
            self.assertEqual(allure_report.select_latest_run(root), newer)

    def test_latest_ignores_incomplete_and_malformed_directories(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            expected = self.make_run(
                root,
                "20260727T000000Z-aaaaaaaaaaaa-agent-00000001",
                "2026-07-27T00:00:01Z",
            )
            incomplete = root / "20260727T000001Z-aaaaaaaaaaaa-agent-00000002"
            incomplete.mkdir()
            (root / "not-a-run").mkdir()
            self.assertEqual(allure_report.select_latest_run(root), expected)

    def test_stage_preserves_junit_identity_and_copies_only_safe_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run_dir = self.make_run(
                root / "results",
                "20260727T000000Z-aaaaaaaaaaaa-agent-00000001",
                "2026-07-27T00:00:01Z",
            )
            (run_dir / "diagnostics" / "unindexed.txt").write_text(
                "must not be attached\n", encoding="utf-8"
            )
            workspace = root / "workspace"
            allure_report.stage_run(run_dir, workspace)
            self.assertEqual(
                (workspace / "allure-results" / "junit.xml").read_bytes(),
                (run_dir / "junit.xml").read_bytes(),
            )
            self.assertTrue((workspace / "attachments" / "logs" / "fixture.log").is_file())
            self.assertTrue((workspace / "attachments" / "diagnostics" / "native.json").is_file())
            self.assertFalse(
                (workspace / "attachments" / "diagnostics" / "unindexed.txt").exists()
            )
            self.assertTrue((workspace / "attachments" / "metadata" / "summary.json").is_file())

    def test_stage_rejects_traversal_duplicate_and_symlink_evidence(self):
        unsafe_values = (
            ["../outside"],
            ["logs/fixture.log", "logs/fixture.log"],
        )
        for artifacts in unsafe_values:
            with self.subTest(artifacts=artifacts), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                run_dir = self.make_run(
                    root / "results",
                    "20260727T000000Z-aaaaaaaaaaaa-agent-00000001",
                    "2026-07-27T00:00:01Z",
                )
                (run_dir / "evidence.json").write_text(
                    json.dumps({"artifacts": [{"path": item} for item in artifacts]}),
                    encoding="utf-8",
                )
                with self.assertRaises(allure_report.ReportError):
                    allure_report.stage_run(run_dir, root / "workspace")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run_dir = self.make_run(
                root / "results",
                "20260727T000000Z-aaaaaaaaaaaa-agent-00000001",
                "2026-07-27T00:00:01Z",
            )
            (run_dir / "logs" / "fixture.log").unlink()
            (run_dir / "logs" / "fixture.log").symlink_to(run_dir / "diagnostics" / "native.json")
            with self.assertRaises(allure_report.ReportError):
                allure_report.stage_run(run_dir, root / "workspace")

    def test_markdown_preserves_suite_counts_and_report_availability(self):
        summary = {
            "run_id": "fixture",
            "result": "broken",
            "duration_seconds": 7,
            "junit": {
                "tests": 4,
                "passed": 1,
                "failures": 1,
                "errors": 1,
                "skipped": 1,
            },
            "suites": [
                {
                    "id": "validation.fixture",
                    "result": "broken",
                    "tests": 4,
                    "failures": 1,
                    "errors": 1,
                    "skipped": 1,
                }
            ],
        }
        markdown = allure_report.markdown_summary(summary, True)
        self.assertIn("⚠️ **BROKEN**", markdown)
        self.assertIn("| 4 | 1 | 1 | 1 | 1 | 7s |", markdown)
        self.assertIn("static Allure Awesome report", markdown)


if __name__ == "__main__":
    unittest.main()
