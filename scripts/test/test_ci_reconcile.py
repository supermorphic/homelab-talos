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

import yaml

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/test/ci_reconcile.py"
BASE = "b" * 40
HEAD = subprocess.run(
    ["git", "rev-parse", "HEAD"], cwd=ROOT, check=True, capture_output=True, text=True
).stdout.strip()
RUN_ID = f"20260904T120000Z-{HEAD[:12]}-github-actions-1234abcd"


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
        self.catalog_path = ROOT / "tests/catalog.yaml"
        self.executions = yaml.safe_load(self.catalog_path.read_text())["executions"]
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

    def make_run(self, group="core", result="passed", suffix="1234abcd", wrapper="", suites=None):
        head = self.plan["head_sha"]
        run_id = f"20260904T120000Z-{head[:12]}-github-actions-{suffix}"
        run = self.results / wrapper / run_id
        (run / "diagnostics").mkdir(parents=True)
        (run / "logs").mkdir()
        execution = "ci-framework" if group == "ci-framework" else f"ci-{group}"
        if suites is None:
            suites = [(suite_id, result) for suite_id in self.executions[execution]]
        records = [
            {
                "id": suite_id,
                "result": suite_result,
                "duration_ms": 1,
                "tests": 1,
                "failures": int(suite_result == "failed"),
                "errors": int(suite_result == "broken"),
                "skipped": int(suite_result == "skipped"),
                "passed": int(suite_result == "passed"),
            }
            for suite_id, suite_result in suites
        ]
        counts = {
            field: sum(record[field] for record in records)
            for field in ("tests", "failures", "errors", "skipped", "passed")
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
                git_sha=head,
                execution_origin="github-actions",
                start="2026-09-04T12:00:00Z",
                end="2026-09-04T12:00:01Z",
                duration_seconds=1,
                result=result,
                junit=counts,
                suites=records,
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
                "git": {"sha": head, "branch": "fixture", "dirty": False},
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
                "head_sha": head,
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
        cases = []
        for suite_id, suite_result in suites:
            tag = {"failed": "failure", "broken": "error", "skipped": "skipped"}.get(suite_result)
            outcome = f"<{tag}/>" if tag else ""
            cases.append(f'<testcase name="{suite_id}">{outcome}</testcase>')
        (run / "junit.xml").write_text(
            '<testsuites><testsuite name="fixture">'
            + "".join(cases)
            + "</testsuite></testsuites>\n",
            encoding="utf-8",
        )
        return run

    def edit_json(self, path, **changes):
        payload = json.loads(path.read_text())
        payload.update(changes)
        self.write_json(path, payload)

    def cli(self, *args):
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
                *args,
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
            timeout=30,
        )

    def assert_failure(self, reason):
        payload, reasons, _rows = self.reconciler.evaluate_results(
            self.reconciler.read_plan(self.plan_path), self.results, self.executions
        )
        self.assertEqual(payload["result"], "failed")
        self.assertIn(reason, "\n".join(reasons))
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
        self.assertIn(f"| core | yes | {RUN_ID} | passed | 32 | 32 |", markdown)
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
        payload, reasons, _rows = self.reconciler.evaluate_results(
            self.reconciler.read_plan(self.plan_path), self.results, self.executions
        )
        self.assertEqual(payload["result"], "passed", reasons)
        self.assertEqual([group["id"] for group in payload["groups"]], self.plan["groups"])

    def test_native_diagnostic_summary_is_not_a_child_run(self):
        run = self.make_run()
        self.write_json(run / "diagnostics/summary.json", {"native": "diagnostic"})
        evidence = json.loads((run / "evidence.json").read_text())
        evidence["artifacts"].append({"path": "diagnostics/summary.json"})
        self.write_json(run / "evidence.json", evidence)
        self.assertEqual(len(self.reconciler.discover_results(self.results)), 1)

    def test_all_invalid_children_are_reported(self):
        for suffix in ("1234abcd", "1234abce"):
            run = self.make_run(suffix=suffix)
            (run / "environment.json").unlink()
        with self.assertRaises(self.reconciler.InvalidResults) as raised:
            self.reconciler.discover_results(self.results)
        self.assertIn("1234abcd", str(raised.exception))
        self.assertIn("1234abce", str(raised.exception))

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

    def test_missing_expected_suite_fails_despite_consistent_passed_run(self):
        suites = [(suite_id, "passed") for suite_id in self.executions["ci-core"][1:]]
        self.make_run(suites=suites)
        self.assert_failure("group core missing expected suite")

    def test_unexpected_suite_fails_despite_consistent_passed_run(self):
        suites = [(suite_id, "passed") for suite_id in self.executions["ci-core"]]
        self.make_run(suites=[*suites, ("validation.unexpected", "passed")])
        self.assert_failure("group core unexpected suite: validation.unexpected")

    def test_skipped_suite_fails_beneath_passed_group(self):
        suites = [(suite_id, "passed") for suite_id in self.executions["ci-core"]]
        suite_id = suites[0][0]
        suites[0] = (suite_id, "skipped")
        self.make_run(suites=suites)
        self.assert_failure(f"group core suite {suite_id} result is skipped")

    def test_incomplete_suite_cli_fails_and_writes_both_reports(self):
        complete = [(suite_id, "passed") for suite_id in self.executions["ci-core"]]
        for suites, reason in (
            (complete[1:], "missing expected suite"),
            ([*complete, ("validation.unexpected", "passed")], "unexpected suite"),
            ([(complete[0][0], "skipped"), *complete[1:]], "result is skipped"),
        ):
            with self.subTest(reason=reason):
                run = self.make_run(suites=suites)
                process = self.cli()
                self.assertEqual(process.returncode, 1, process.stderr)
                self.assertIn(reason, process.stderr)
                payload = json.loads((self.output / "merge-gate.json").read_text())
                self.assertEqual(payload["result"], "failed")
                self.assertIn(reason, (self.output / "merge-gate.md").read_text())
                shutil.rmtree(run)

    def test_unexpected_groups_follow_complete_canonical_order(self):
        self.plan["groups"] = ["core", "automation"]
        self.write_plan()
        for index, group in enumerate(("core", "observability", "automation", "ci-framework")):
            self.make_run(group, suffix=f"{index:08x}")
        payload = self.assert_failure("unexpected group: observability")
        self.assertEqual(
            [group["id"] for group in payload["groups"]],
            ["core", "observability", "automation", "ci-framework"],
        )

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

    def candidate_repo(self, content):
        repo = self.root / "candidate"
        repo.mkdir(exist_ok=True)
        subprocess.run(["git", "init", "--quiet", str(repo)], check=True)
        if content is not None:
            (repo / "tests").mkdir(exist_ok=True)
            (repo / "tests/catalog.yaml").write_text(content)
            subprocess.run(["git", "-C", str(repo), "add", "tests/catalog.yaml"], check=True)
        subprocess.run(
            [
                "git",
                "-C",
                str(repo),
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "-c",
                "core.hooksPath=/dev/null",
                "commit",
                "--quiet",
                "--allow-empty",
                "-m",
                "candidate catalog fixture",
            ],
            check=True,
        )
        self.plan["head_sha"] = subprocess.run(
            ["git", "-C", str(repo), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.write_plan()
        return repo

    def assert_catalog_error(self, *args):
        process = self.cli(*args)
        self.assertEqual(process.returncode, 2, process.stderr)
        self.assertIn("candidate catalog", process.stderr)
        self.assertNotIn("Traceback", process.stderr)
        self.assertFalse(self.output.exists())

    def test_unavailable_candidate_commit_is_configuration_error(self):
        self.plan["head_sha"] = "0" * 40
        self.write_plan()
        self.assert_catalog_error()

    def test_missing_candidate_catalog_is_configuration_error(self):
        repo = self.candidate_repo(None)
        self.assert_catalog_error("--repo", str(repo))

    def test_inaccessible_candidate_repository_is_configuration_error(self):
        repo = self.candidate_repo(self.catalog_path.read_text())
        original_mode = repo.stat().st_mode
        try:
            repo.chmod(0)
            try:
                list(repo.iterdir())
            except PermissionError:
                pass
            else:
                self.skipTest("current user can read mode-000 directories")
            self.assert_catalog_error("--repo", str(repo))
        finally:
            repo.chmod(original_mode)

    def test_malformed_candidate_catalog_is_configuration_error(self):
        original = self.catalog_path.read_text()
        for content in (
            "{",
            "schema_version: 2\nsuites: []\n",
            original + "\nexecutions: {}\n",
            original.replace("  ci-core:\n", "  missing-core:\n", 1),
            original.replace(
                "mise exec -- just test validate core",
                "mise exec -- just test validate automation",
                1,
            ),
        ):
            with self.subTest(content=content[:40]):
                repo = self.candidate_repo(content)
                self.assert_catalog_error("--repo", str(repo))
                shutil.rmtree(repo)

    def test_just_interface_reads_complete_immutable_candidate_catalog(self):
        self.make_run()
        process = subprocess.run(
            [
                "just",
                "test",
                "ci-reconcile",
                str(self.plan_path),
                str(self.results),
                str(self.output),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(process.returncode, 0, process.stderr)

    def test_worktree_catalog_cannot_replace_candidate_catalog(self):
        repo = self.candidate_repo(self.catalog_path.read_text())
        (repo / "tests/catalog.yaml").write_text("invalid working-tree catalog")
        self.make_run()
        process = self.cli("--repo", str(repo))
        self.assertEqual(process.returncode, 0, process.stderr)

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
                    if target == self.plan_path:
                        process = self.cli()
                        self.assertEqual(process.returncode, 2, process.stderr)
                        self.assertIn("symlink", process.stderr)
                    else:
                        with self.assertRaisesRegex(self.reconciler.UnsafeInput, "symlink"):
                            self.reconciler.discover_results(self.results)
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

    def test_unreadable_download_directory_is_unsafe_input(self):
        self.make_run()
        unreadable = self.results / "unreadable artifact"
        unreadable.mkdir()
        (unreadable / "cancelled.json").write_text('{"result":"cancelled"}')
        original_mode = unreadable.stat().st_mode
        try:
            unreadable.chmod(0)
            try:
                list(unreadable.iterdir())
            except PermissionError:
                pass
            else:
                self.skipTest("current user can read mode-000 directories")
            process = self.cli()
            self.assertEqual(process.returncode, 2, process.stderr)
            self.assertIn("cannot traverse", process.stderr)
            self.assertIn("unreadable artifact", process.stderr)
            with self.assertRaises(self.reconciler.UnsafeInput):
                self.reconciler.discover_results(self.results)
        finally:
            unreadable.chmod(original_mode)

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
