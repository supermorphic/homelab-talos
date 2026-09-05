"""Exercise merge-gate decisions with independent plans and real canonical runs."""

from __future__ import annotations

import hashlib
import importlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/test/ci_reconcile.py"
BASE = "b" * 40
HEAD = "c" * 40
RUN_ID = "20260904T120000Z-cccccccccccc-github-actions-1234abcd"


class ReconciliationTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), "merge-gate reconciler is missing")
        sys.path.insert(0, str(SCRIPT.parent))
        self.addCleanup(sys.path.pop, 0)
        self.reconciler = importlib.import_module("ci_reconcile")
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.results = self.root / "downloaded results"
        self.results.mkdir()
        self.output = self.root / "output"
        self.plan_path = self.root / "plan.json"
        self.plan = {
            "schema_version": 1,
            "base_sha": BASE,
            "head_sha": HEAD,
            "mode": "selective",
            "groups": ["core"],
            "reasons": [],
        }
        self.write_plan()

    def write_json(self, path, payload):
        path.write_text(json.dumps(payload) + "\n", encoding="utf-8")

    def write_plan(self):
        payload = {key: value for key, value in self.plan.items() if key != "plan_id"}
        self.plan["plan_id"] = hashlib.sha256(
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        self.write_json(self.plan_path, self.plan)

    def make_run(self, group="core", result="passed", suffix="1234abcd", wrapper=""):
        run_id = f"20260904T120000Z-cccccccccccc-github-actions-{suffix}"
        run = self.results / wrapper / run_id
        (run / "diagnostics").mkdir(parents=True)
        (run / "logs").mkdir()
        counts = {
            "tests": 1,
            "failures": int(result == "failed"),
            "errors": int(result == "broken"),
            "skipped": int(result == "skipped"),
            "passed": int(result == "passed"),
        }
        metadata = {
            "source": "repository",
            "framework": "just",
            "suite": "ci",
            "tier": "validation",
            "target": "repository",
            "scope": "offline",
            "intent": "validation",
            "scenario": None,
        }
        self.write_json(
            run / "summary.json",
            dict(
                schema_version=1,
                run_id=run_id,
                **metadata,
                git_sha=HEAD,
                execution_origin="github-actions",
                start="2026-09-04T12:00:00Z",
                end="2026-09-04T12:00:01Z",
                duration_seconds=1,
                result=result,
                junit=counts,
                suites=[dict(id="validation.fixture", result=result, **counts)],
                phases={},
            ),
        )
        self.write_json(
            run / "environment.json",
            {
                "schema_version": 1,
                "run_id": run_id,
                "execution_origin": "github-actions",
                "start": "2026-09-04T12:00:00Z",
                "end": "2026-09-04T12:00:01Z",
                "git": {"sha": HEAD, "branch": "fixture", "dirty": False},
                "host": {"os": "fixture", "architecture": "fixture"},
                "tools": {},
                "cluster": {},
                "suite": dict(id=f"ci-{group}", **metadata),
                "confirmation_variable": None,
            },
        )
        self.write_json(
            run / "diagnostics/ci-binding.json",
            {
                "schema_version": 1,
                "plan_id": self.plan["plan_id"],
                "base_sha": BASE,
                "head_sha": HEAD,
                "group": group,
                "execution": "ci-framework" if group == "ci-framework" else f"ci-{group}",
            },
        )
        self.write_json(
            run / "evidence.json",
            {
                "schema_version": 1,
                "run_id": run_id,
                "artifacts": [{"path": "diagnostics/ci-binding.json"}],
            },
        )
        tag = {"failed": "failure", "broken": "error", "skipped": "skipped"}.get(result)
        outcome = f"<{tag}/>" if tag else ""
        (run / "junit.xml").write_text(
            f'<testsuites><testsuite name="fixture"><testcase name="case">{outcome}'
            "</testcase></testsuite></testsuites>\n",
            encoding="utf-8",
        )
        return run

    def edit_json(self, path, **changes):
        payload = json.loads(path.read_text())
        payload.update(changes)
        self.write_json(path, payload)

    def cli(self):
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--plan",
                str(self.plan_path),
                "--results",
                str(self.results),
                "--output",
                str(self.output),
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            timeout=30,
        )

    def assert_failure(self, reason):
        process = self.cli()
        self.assertEqual(process.returncode, 1, process.stdout + process.stderr)
        self.assertIn(reason, process.stderr)
        payload = json.loads((self.output / "merge-gate.json").read_text())
        self.assertEqual(payload["result"], "failed")
        self.assertIn(reason, (self.output / "merge-gate.md").read_text())
        return payload

    def test_exact_selected_results_pass_with_stable_output_and_counts(self):
        self.plan["groups"] = ["core", "automation"]
        self.write_plan()
        self.make_run("automation", suffix="1234abce", wrapper="artifact automation")
        self.make_run(wrapper="artifact core")
        expected = {
            "schema_version": 1,
            "plan_id": self.plan["plan_id"],
            "base_sha": BASE,
            "head_sha": HEAD,
            "result": "passed",
            "groups": [
                {"id": "core", "run_id": RUN_ID, "result": "passed"},
                {"id": "automation", "run_id": RUN_ID[:-8] + "1234abce", "result": "passed"},
            ],
        }
        self.assertEqual(self.reconciler.reconcile(self.plan_path, self.results), expected)
        process = self.cli()
        self.assertEqual(process.returncode, 0, process.stderr)
        json_path = self.output / "merge-gate.json"
        markdown = (self.output / "merge-gate.md").read_text()
        first = json_path.read_bytes()
        self.assertEqual(json.loads(first), expected)
        self.assertIn("| Group | Required | Run ID | Result | Suites | Tests |", markdown)
        self.assertIn(f"| core | yes | {RUN_ID} | passed | 1 | 1 |", markdown)
        self.assertEqual(self.cli().returncode, 0)
        self.assertEqual(json_path.read_bytes(), first)
        self.assertEqual(
            sorted(path.name for path in self.output.iterdir()),
            ["merge-gate.json", "merge-gate.md"],
        )

    def test_discovery_exposes_bound_group_result(self):
        run = self.make_run()
        self.assertEqual(
            self.reconciler.discover_results(self.results),
            (
                self.reconciler.GroupResult(
                    "core",
                    "ci-core",
                    self.plan["plan_id"],
                    BASE,
                    HEAD,
                    RUN_ID,
                    "passed",
                    run / "summary.json",
                ),
            ),
        )

    def test_full_plan_passes_with_all_four_groups(self):
        self.plan["groups"] = ["core", "observability", "automation", "ci-framework"]
        self.plan["mode"] = "full"
        self.write_plan()
        for index, group in enumerate(self.plan["groups"]):
            self.make_run(group, suffix=f"{index:08x}")
        process = self.cli()
        self.assertEqual(process.returncode, 0, process.stderr)

    def test_native_diagnostic_summary_is_not_a_child_run(self):
        run = self.make_run()
        self.write_json(run / "diagnostics/summary.json", {"native": "diagnostic"})
        evidence = json.loads((run / "evidence.json").read_text())
        evidence["artifacts"].append({"path": "diagnostics/summary.json"})
        self.write_json(run / "evidence.json", evidence)
        process = self.cli()
        self.assertEqual(process.returncode, 0, process.stderr)

    def test_all_invalid_children_are_reported(self):
        for suffix in ("1234abcd", "1234abce"):
            run = self.make_run(suffix=suffix)
            (run / "environment.json").unlink()
        process = self.cli()
        self.assertEqual(process.returncode, 1, process.stderr)
        self.assertIn("1234abcd", process.stderr)
        self.assertIn("1234abce", process.stderr)

    def test_unclaimed_downloaded_file_fails(self):
        self.make_run()
        (self.results / "cancelled.json").write_text('{"result":"cancelled"}')
        self.assert_failure("unexpected evidence file")

    def test_otherwise_valid_duplicate_json_field_fails(self):
        run = self.make_run()
        binding = run / "diagnostics/ci-binding.json"
        binding.write_text('{"schema_version":1,' + binding.read_text()[1:])
        self.assert_failure("invalid canonical run")

    def test_non_json_numeric_constant_fails(self):
        run = self.make_run()
        self.edit_json(run / "summary.json", measurement=float("nan"))
        self.assert_failure("invalid canonical run")

    def test_missing_or_cancelled_absent_group_fails(self):
        self.assert_failure("missing required group: core")

    def test_duplicate_group_fails(self):
        self.make_run()
        self.make_run(suffix="1234abce")
        self.assert_failure("duplicate group: core")

    def test_unexpected_group_fails(self):
        self.make_run()
        self.make_run("automation", suffix="1234abce")
        self.assert_failure("unexpected group: automation")

    def test_failed_broken_and_skipped_results_fail(self):
        for result in ("failed", "broken", "skipped"):
            with self.subTest(result=result):
                run = self.make_run(result=result)
                self.assert_failure(f"group core result is {result}")
                shutil.rmtree(run)

    def test_cancelled_marker_fails_and_writes_reports(self):
        run = self.make_run()
        self.edit_json(run / "summary.json", result="cancelled")
        self.assert_failure("invalid canonical run")

    def test_wrong_plan_base_head_and_execution_fail(self):
        for field, value in (
            ("plan_id", "a" * 64),
            ("base_sha", "d" * 40),
            ("head_sha", "d" * 40),
            ("execution", "ci-automation"),
        ):
            with self.subTest(field=field):
                run = self.make_run()
                self.edit_json(run / "diagnostics/ci-binding.json", **{field: value})
                if field == "head_sha":
                    self.edit_json(run / "summary.json", git_sha=value)
                    environment = json.loads((run / "environment.json").read_text())
                    environment["git"]["sha"] = value
                    self.write_json(run / "environment.json", environment)
                self.assert_failure(f"group core {field} mismatch")
                shutil.rmtree(run)

    def test_invalid_junit_cannot_hide_behind_passed_summary(self):
        run = self.make_run()
        (run / "junit.xml").write_text(
            '<testsuite><testcase name="failure"><failure/></testcase></testsuite>'
        )
        self.assert_failure("invalid canonical run")

    def test_invalid_canonical_run_cannot_be_ignored_beside_valid_run(self):
        self.make_run()
        run = self.make_run("automation", suffix="1234abce")
        (run / "environment.json").unlink()
        self.assert_failure("invalid canonical run")

    def test_missing_binding_or_summary_fails(self):
        for name in ("diagnostics/ci-binding.json", "summary.json"):
            with self.subTest(name=name):
                run = self.make_run()
                (run / name).unlink()
                self.assert_failure("run")
                shutil.rmtree(run)

    def test_malformed_and_duplicate_json_fields_fail(self):
        for name in (
            "summary.json",
            "environment.json",
            "evidence.json",
            "diagnostics/ci-binding.json",
        ):
            for text in ("{", '{"schema_version":1,"schema_version":1}'):
                with self.subTest(name=name, text=text):
                    run = self.make_run()
                    (run / name).write_text(text)
                    self.assert_failure("run")
                    shutil.rmtree(run)

    def test_invalid_plan_is_configuration_error(self):
        for payload in ("{", json.dumps({**self.plan, "plan_id": "a" * 64})):
            with self.subTest(payload=payload):
                self.plan_path.write_text(payload)
                process = self.cli()
                self.assertEqual(process.returncode, 2, process.stderr)
                self.assertIn("plan", process.stderr)

    def test_symlinked_inputs_rejected_before_validator_reads(self):
        run = self.make_run()
        for target in (
            self.plan_path,
            self.results,
            run,
            run / "summary.json",
            run / "diagnostics",
            run / "diagnostics/ci-binding.json",
        ):
            with self.subTest(target=target):
                saved = target.with_name(target.name + ".saved")
                target.rename(saved)
                target.symlink_to(saved, target_is_directory=saved.is_dir())
                try:
                    process = self.cli()
                    self.assertEqual(process.returncode, 2, process.stderr)
                    self.assertIn("symlink", process.stderr)
                finally:
                    target.unlink()
                    saved.rename(target)

    def test_fifo_input_rejected_without_blocking(self):
        run = self.make_run()
        (run / "summary.json").unlink()
        os.mkfifo(run / "summary.json")
        process = self.cli()
        self.assertEqual(process.returncode, 2, process.stderr)
        self.assertIn("regular", process.stderr)

    def test_symlinked_output_cannot_overwrite_target(self):
        self.make_run()
        self.output.mkdir()
        victim = self.root / "preserved.json"
        victim.write_text("preserve me")
        (self.output / "merge-gate.json").symlink_to(victim)
        process = self.cli()
        self.assertEqual(process.returncode, 2, process.stderr)
        self.assertEqual(victim.read_text(), "preserve me")


if __name__ == "__main__":
    unittest.main()
