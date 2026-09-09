"""Local publication guards with real Git histories and remote movement."""

from __future__ import annotations

import contextlib
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci_publish


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.remote = self.root / "remote.git"
        self.repo = self.root / "work"
        subprocess.run(
            ["git", "init", "--bare", str(self.remote)], check=True, capture_output=True
        )
        self.repo.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Fixture")
        (self.repo / ".gitignore").write_text(".tmp/\n")
        (self.repo / "document").write_text("base\n")
        (self.repo / "tests").mkdir()
        for name in ("impact.yaml", "catalog.yaml"):
            (self.repo / "tests" / name).write_bytes(
                (ci_publish.ROOT / "tests" / name).read_bytes()
            )
        self.git("add", ".")
        self.git("commit", "-m", "base")
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "origin", "main")
        self.git("switch", "-c", "feature")
        self.head = self.git("rev-parse", "HEAD")

    def git(self, *args):
        return (
            subprocess.check_output(["git", *args], cwd=self.repo, stderr=subprocess.DEVNULL)
            .decode()
            .strip()
        )

    def test_clean_feature_and_remote_base_are_bound(self):
        self.assertEqual(ci_publish.snapshot(self.repo), ("feature", self.head))
        self.assertEqual(ci_publish.refresh_base(self.repo), self.head)

    def test_dirty_staged_and_untracked_inputs_rejected(self):
        for kind in ("unstaged", "staged", "untracked"):
            with self.subTest(kind=kind):
                name = "new-input" if kind == "untracked" else "document"
                (self.repo / name).write_text(f"{kind}\n")
                if kind == "staged":
                    self.git("add", name)
                with self.assertRaisesRegex(ValueError, "clean"):
                    ci_publish.snapshot(self.repo)
                self.git("add", ".")
                self.git("commit", "--allow-empty", "-m", kind)

    def test_main_and_detached_candidates_rejected(self):
        self.git("switch", "main")
        with self.assertRaisesRegex(ValueError, "feature branch"):
            ci_publish.snapshot(self.repo)
        self.git("checkout", "--detach")
        with self.assertRaises(ValueError):
            ci_publish.snapshot(self.repo)

    def test_changed_head_or_branch_rejected(self):
        initial = ci_publish.snapshot(self.repo)
        self.git("commit", "--allow-empty", "-m", "new candidate")
        with self.assertRaisesRegex(ValueError, "candidate changed"):
            ci_publish.require_candidate(self.repo, initial)

    def test_branch_switch_at_same_head_rejected(self):
        initial = ci_publish.snapshot(self.repo)
        self.git("switch", "-c", "another-feature")
        with self.assertRaisesRegex(ValueError, "candidate changed"):
            ci_publish.require_candidate(self.repo, initial)

    def test_group_execution_uses_pinned_recipe_and_isolated_results(self):
        args = ["ci-group", "core", str(self.root / "plan with spaces.json")]
        with patch.object(subprocess, "run") as process:
            process.return_value.returncode = 7
            self.assertEqual(ci_publish.execute(self.repo, args, self.root / "results"), 7)
        command = process.call_args.args[0]
        self.assertEqual(command, ["mise", "exec", "--", "just", "test", *args])
        self.assertEqual(process.call_args.kwargs["cwd"], self.repo)
        self.assertEqual(
            process.call_args.kwargs["env"]["TEST_RESULTS_ROOT"], str(self.root / "results")
        )

    def test_remote_refresh_failure_does_not_use_stale_tracking_ref(self):
        ci_publish.refresh_base(self.repo)
        self.git("remote", "set-url", "origin", str(self.root / "missing"))
        with self.assertRaises(ValueError):
            ci_publish.refresh_base(self.repo)

    def test_environment_cannot_substitute_test_commands_or_catalog(self):
        with patch.dict(os.environ, {"TEST_JUST_BIN": "false", "TEST_CATALOG_PATH": "fake"}):
            env = ci_publish.execution_environment(self.root / "results")
        self.assertNotIn("TEST_JUST_BIN", env)
        self.assertNotIn("TEST_CATALOG_PATH", env)
        self.assertEqual(env["TEST_RESULTS_ROOT"], str(self.root / "results"))

    def test_plan_selects_only_core_and_each_invocation_gets_fresh_evidence(self):
        calls = []

        def successful_execution(repo, args, results):
            calls.append(args)
            return 0

        with patch.object(ci_publish, "execute", side_effect=successful_execution):
            first = ci_publish.publish(self.repo)
            second = ci_publish.publish(self.repo)
        self.assertNotEqual(first, second)
        for evidence in (first, second):
            receipt = json.loads((evidence / "publication.json").read_text())
            self.assertEqual(receipt["groups"], ["core"])
            self.assertEqual(receipt["head_sha"], self.head)
            self.assertEqual(receipt["base_sha"], self.head)
        self.assertEqual(
            [call[:2] for call in calls if call[0] == "ci-group"],
            [["ci-group", "core"], ["ci-group", "core"]],
        )

    def test_full_escalation_runs_all_groups_in_canonical_order(self):
        calls = []
        with patch.object(
            ci_publish, "execute", side_effect=lambda repo, args, results: calls.append(args) or 0
        ):
            evidence = ci_publish.publish(self.repo, full=True)
        self.assertEqual(
            [call[1] for call in calls if call[0] == "ci-group"],
            ["core", "observability", "automation", "ci-framework"],
        )
        self.assertEqual(
            json.loads((evidence / "publication.json").read_text())["result"], "passed"
        )

    def test_candidate_diff_selects_automation_in_addition_to_core(self):
        source = self.repo / "kubernetes/apps/automation/n8n/app/values.yaml"
        source.parent.mkdir(parents=True)
        source.write_text("example: true\n")
        self.git("add", ".")
        self.git("commit", "-m", "automation input")
        with patch.object(ci_publish, "execute", return_value=0):
            evidence = ci_publish.publish(self.repo)
        receipt = json.loads((evidence / "publication.json").read_text())
        self.assertEqual(receipt["groups"], ["core", "automation"])
        self.assertNotEqual(receipt["base_sha"], receipt["head_sha"])

    def test_failed_group_still_reconciles_but_never_writes_pass_receipt(self):
        calls = []

        def fail_group(repo, args, results):
            calls.append(args[0])
            return int(args[0] == "ci-group")

        with (
            patch.object(ci_publish, "execute", side_effect=fail_group),
            self.assertRaisesRegex(ValueError, "validation failed"),
        ):
            ci_publish.publish(self.repo, full=True)
        self.assertEqual(calls, ["ci-group", "ci-reconcile"])
        self.assertEqual(list(self.repo.glob(".tmp/**/publication.json")), [])

    def test_failed_reconciliation_cannot_publish(self):
        with (
            patch.object(
                ci_publish,
                "execute",
                side_effect=lambda repo, args, results: int(args[0] == "ci-reconcile"),
            ),
            self.assertRaisesRegex(ValueError, "validation failed"),
        ):
            ci_publish.publish(self.repo)
        self.assertEqual(list(self.repo.glob(".tmp/**/publication.json")), [])

    def test_remote_advance_during_execution_invalidates_success(self):
        def advance(repo, args, results):
            if args[0] == "ci-group":
                tree = self.git("rev-parse", "HEAD^{tree}")
                new = self.git("commit-tree", tree, "-p", self.head, "-m", "remote advance")
                self.git("push", "origin", new + ":refs/heads/main")
            return 0

        with (
            patch.object(ci_publish, "execute", side_effect=advance),
            self.assertRaisesRegex(ValueError, "main advanced"),
        ):
            ci_publish.publish(self.repo)
        self.assertEqual(list(self.repo.glob(".tmp/**/publication.json")), [])

    def test_candidate_edit_during_execution_invalidates_success(self):
        def edit(repo, args, results):
            (self.repo / "document").write_text("concurrent edit")
            return 0

        with (
            patch.object(ci_publish, "execute", side_effect=edit),
            self.assertRaisesRegex(ValueError, "clean"),
        ):
            ci_publish.publish(self.repo)
        self.assertEqual(list(self.repo.glob(".tmp/**/publication.json")), [])

    def test_behind_main_is_rejected_before_any_validation(self):
        self.git("switch", "main")
        self.git("commit", "--allow-empty", "-m", "main advance")
        self.git("push", "origin", "main")
        self.git("switch", "feature")
        with self.assertRaisesRegex(ValueError, "ancestor"):
            ci_publish.publish(self.repo)
        self.assertFalse((self.repo / ".tmp/ci-publication").exists())

    def test_final_fetch_failure_invalidates_passing_execution(self):
        def remove_remote(repo, args, results):
            self.git("remote", "set-url", "origin", str(self.root / "missing"))
            return 0

        with (
            patch.object(ci_publish, "execute", side_effect=remove_remote),
            self.assertRaises(ValueError),
        ):
            ci_publish.publish(self.repo)
        self.assertEqual(list(self.repo.glob(".tmp/**/publication.json")), [])

    def test_interrupted_execution_has_no_passing_receipt(self):
        with (
            patch.object(ci_publish, "execute", side_effect=KeyboardInterrupt),
            self.assertRaises(KeyboardInterrupt),
        ):
            ci_publish.publish(self.repo)
        self.assertEqual(list(self.repo.glob(".tmp/**/publication.json")), [])


if __name__ == "__main__":
    unittest.main()
