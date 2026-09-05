#!/usr/bin/env python3
"""Fail-closed planning contracts with independent fixtures and real Git histories."""

from __future__ import annotations

import dataclasses
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path, PurePosixPath

import yaml

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/test/ci_plan.py"
SPEC = importlib.util.spec_from_file_location("ci_plan", SCRIPT)
assert SPEC and SPEC.loader
planner = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = planner
SPEC.loader.exec_module(planner)
Change = planner.Change
Plan = planner.Plan
ImpactConfig = planner.ImpactConfig
load_impact = planner.load_impact
classify = planner.classify
make_plan = planner.make_plan
FULL = ("core", "observability", "automation", "ci-framework")
IMPACT = ROOT / "tests/impact.yaml"
CATALOG = ROOT / "tests/catalog.yaml"


class ClassificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.impact = load_impact(IMPACT, CATALOG)

    def test_named_change_fixtures(self):
        fixtures = yaml.safe_load((ROOT / "tests/fixtures/ci-impact/changes.yaml").read_text())
        for name, case in fixtures["cases"].items():
            with self.subTest(name=name):
                changes = [Change(**change) for change in case["changes"]]
                self.assertEqual(classify(changes, self.impact, full=False), tuple(case["groups"]))
                self.assertEqual(classify(changes, self.impact, full=True), FULL)

    def test_foundational_inputs_select_full(self):
        for path in (
            ".github/workflows/ci.yml",
            "tests/impact.yaml",
            "tests/catalog.yaml",
            "talos/patches/global/machine.yaml",
            "kubernetes/flux/cluster/ks.yaml",
            "kubernetes/apps/flux-system/flux/app/helmrelease.yaml",
            "kubernetes/apps/kube-system/cilium/app/helmrelease.yaml",
            "kubernetes/apps/kustomization.yaml",
            "scripts/test/ci_plan.py",
            "scripts/test/test_ci_plan.py",
            "scripts/test/lib/results.sh",
        ):
            with self.subTest(path=path):
                self.assertEqual(
                    classify([Change("M", None, path)], self.impact, full=False), FULL
                )

    def test_rename_and_copy_select_both_owners(self):
        for status in ("R", "R100", "C", "C075"):
            with self.subTest(status=status):
                self.assertEqual(
                    classify(
                        [
                            Change(
                                status,
                                "kubernetes/apps/monitoring/old.yaml",
                                "kubernetes/apps/automation/new.yaml",
                            )
                        ],
                        self.impact,
                        full=False,
                    ),
                    ("core", "observability", "automation"),
                )

    def test_unmapped_inputs_fail_broad(self):
        for path in ("unknown/new.yaml", "scripts/test/new-shared-tool.sh"):
            self.assertEqual(classify([Change("A", None, path)], self.impact, full=False), FULL)

    def test_empty_diff_still_requires_core(self):
        self.assertEqual(classify([], self.impact, full=False), ("core",))

    def test_shared_alert_validator_selects_observability(self):
        self.assertEqual(
            classify([Change("M", None, "scripts/validate/alerts.sh")], self.impact, full=False),
            ("core", "observability"),
        )

    def test_observability_implementations_select_owned_tests(self):
        cases = {
            "scripts/diagnose/flux-alerts.sh": ("core", "observability"),
            "scripts/verify/logging.sh": ("core", "observability"),
            "scripts/verify/alertmanager-ntfy.sh": ("core", "observability"),
            "kubernetes/mod.just": ("core", "observability", "automation", "ci-framework"),
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertEqual(
                    classify([Change("M", None, path)], self.impact, full=False), expected
                )

    def test_cross_domain_automation_inputs_select_owned_tests(self):
        cases = {
            "kubernetes/apps/monitoring/kube-prometheus-stack/config/dashboards/n8n-postgresql.json": (
                "core",
                "observability",
                "automation",
            ),
            "kubernetes/apps/monitoring/kube-prometheus-stack/config/dashboards/automation-data-postgresql.json": (
                "core",
                "observability",
                "automation",
            ),
            "kubernetes/apps/networking/public-webhook-gateway/route/httproute.yaml": (
                "core",
                "automation",
            ),
            "scripts/verify/n8n.sh": ("core", "automation"),
            "scripts/verify/automation-data.sh": ("core", "automation"),
        }
        for path, expected in cases.items():
            with self.subTest(path=path):
                self.assertEqual(
                    classify([Change("M", None, path)], self.impact, full=False), expected
                )

    def test_external_framework_implementations_select_full(self):
        for path in (
            "kubernetes/apps/monitoring/test-reports/app/install-report.sh",
            "kubernetes/apps/monitoring/test-reports/app/bootstrap-storage.sh",
            "scripts/repository/github_protection.py",
        ):
            with self.subTest(path=path):
                self.assertEqual(
                    classify([Change("M", None, path)], self.impact, full=False),
                    ("core", "observability", "automation", "ci-framework"),
                )

    def test_merge_gate_implementation_and_tests_select_explicit_full(self):
        for path in ("scripts/test/ci_reconcile.py", "scripts/test/test_ci_reconcile.py"):
            with self.subTest(path=path):
                groups, reasons = planner.select(
                    [Change("M", None, path)], self.impact, full=False
                )
                self.assertEqual(groups, ("core", "observability", "automation", "ci-framework"))
                self.assertEqual(reasons[0]["reason"], "full")

    def test_status_and_path_contract_rejects_ambiguous_inputs(self):
        for change in (
            Change("T", None, "docs/a"),
            Change("U", None, "docs/a"),
            Change("R101", "docs/a", "docs/b"),
            Change("M", None, None),
            Change("D", None, "docs/a"),
            Change("A", "docs/a", "docs/b"),
            Change("R", None, "docs/a"),
            Change("M", None, "../docs/a"),
            Change("M", None, "/docs/a"),
        ):
            with self.subTest(change=change), self.assertRaises(ValueError):
                classify([change], self.impact, full=False)

    def test_tracked_paths_have_explicit_ownership(self):
        output = subprocess.run(
            ["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True
        ).stdout
        unmatched = []
        explicit_full = []
        for raw_path in output.split(b"\0"):
            if not raw_path:
                continue
            path = os.fsdecode(raw_path)
            groups, reasons = planner.select([Change("M", None, path)], self.impact, full=False)
            if any(reason["reason"] == "unmatched" for reason in reasons):
                unmatched.append(path)
            if any(
                PurePosixPath(path).full_match(pattern) for pattern in self.impact.full_patterns
            ):
                explicit_full.append(path)
                self.assertEqual(groups, FULL, path)
        self.assertEqual(unmatched, [], "Tracked paths need deliberate ownership")
        self.assertTrue(explicit_full, "Coverage must retain explicitly foundational paths")


class GitPlanTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ci-plan-test-")
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.git("init", "--quiet")
        self.git("config", "user.name", "CI planner tests")
        self.git("config", "user.email", "ci-planner@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", "/dev/null")
        self.write("docs/README.md", "initial\n")
        self.base = self.commit()
        self.write("docs/README.md", "updated\n")
        self.head = self.commit()
        self.output = self.repo / "plan.json"

    def git(self, *args):
        return subprocess.run(
            ["git", *args], cwd=self.repo, check=True, capture_output=True, text=True
        ).stdout.strip()

    def write(self, path, content):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)

    def commit(self):
        self.git("add", "--all")
        self.git("commit", "--quiet", "-m", "fixture")
        return self.git("rev-parse", "HEAD")

    def cli(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            cwd=self.repo,
            capture_output=True,
            text=True,
            check=False,
        )

    def plan_cli(self, *args):
        return self.cli(
            "plan",
            "--base",
            self.base,
            "--head",
            self.head,
            "--impact",
            str(IMPACT),
            "--catalog",
            str(CATALOG),
            "--output",
            str(self.output),
            *args,
        )

    def assert_error(self, result):
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(len(result.stderr.strip().splitlines()), 1, result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_plan_is_frozen_deterministic_and_digest_bound(self):
        plan = make_plan(self.repo, self.base, self.head, IMPACT, CATALOG)
        self.assertIsInstance(plan, Plan)
        self.assertEqual(plan.groups, ("core",))
        self.assertEqual(plan.mode, "selective")
        self.assertEqual((plan.base_sha, plan.head_sha), (self.base, self.head))
        payload = dataclasses.asdict(plan)
        digest = payload.pop("plan_id")
        canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        self.assertEqual(digest, hashlib.sha256(canonical.encode()).hexdigest())
        self.assertEqual(plan, make_plan(self.repo, self.base, self.head, IMPACT, CATALOG))
        with self.assertRaises(dataclasses.FrozenInstanceError):
            plan.mode = "full"

    def test_real_git_add_delete_modify_and_rename(self):
        self.write("kubernetes/apps/monitoring/old file\nname.yaml", "monitoring content\n" * 10)
        self.write("kubernetes/apps/automation-data/deleted.yaml", "deleted content\n")
        base = self.commit()
        self.git("mv", "kubernetes/apps/monitoring/old file\nname.yaml", "docs/renamed.yaml")
        (self.repo / "kubernetes/apps/automation-data/deleted.yaml").unlink()
        self.write("docs/added.yaml", "new content\n")
        self.write("docs/README.md", "modified again\n")
        head = self.commit()
        plan = make_plan(self.repo, base, head, IMPACT, CATALOG)
        self.assertEqual(plan.groups, ("core", "observability", "automation"))
        paths = {reason.get("path") for reason in plan.reasons}
        self.assertTrue(
            {
                "kubernetes/apps/monitoring/old file\nname.yaml",
                "docs/renamed.yaml",
                "kubernetes/apps/automation-data/deleted.yaml",
                "docs/added.yaml",
                "docs/README.md",
            }.issubset(paths)
        )

    def test_real_git_copy_parses_both_paths(self):
        self.write("kubernetes/apps/monitoring/source.yaml", "copy source\n" * 100)
        base = self.commit()
        self.write("docs/copied.yaml", "copy source\n" * 100)
        self.write("kubernetes/apps/monitoring/source.yaml", "copy source\n" * 100 + "edit\n")
        head = self.commit()
        plan = make_plan(self.repo, base, head, IMPACT, CATALOG)
        self.assertEqual(plan.groups, ("core", "observability"))
        self.assertIn("docs/copied.yaml", {reason.get("path") for reason in plan.reasons})

    def test_cli_round_trip_and_explicit_full(self):
        result = self.plan_cli()
        self.assertEqual(result.returncode, 0, result.stderr)
        first = self.output.read_bytes()
        self.assertEqual(self.plan_cli().returncode, 0)
        self.assertEqual(self.output.read_bytes(), first)
        groups = self.cli("groups", "--plan", str(self.output))
        self.assertEqual((groups.returncode, groups.stdout), (0, '["core"]\n'))
        self.assertEqual(
            self.cli("validate", "--plan", str(self.output), "--head", self.head).returncode, 0
        )
        self.assert_error(self.cli("validate", "--plan", str(self.output), "--head", self.base))
        self.assertEqual(self.plan_cli("--full").returncode, 0)
        payload = json.loads(self.output.read_text())
        self.assertEqual(tuple(payload["groups"]), FULL)
        self.assertEqual(payload["mode"], "full")
        self.assertNotEqual(payload["plan_id"], json.loads(first)["plan_id"])
        self.assertEqual(list(self.repo.glob(".plan.json.*")), [])

    def test_full_fallback_records_unmatched_reason(self):
        self.write("unknown/new.txt", "unowned\n")
        self.head = self.commit()
        plan = make_plan(self.repo, self.base, self.head, IMPACT, CATALOG)
        self.assertEqual((plan.mode, plan.groups), ("full", FULL))
        self.assertIn("unmatched", {reason["reason"] for reason in plan.reasons})

    def test_bad_sha_noncommit_and_nonancestor_exit_two(self):
        for sha in ("HEAD", "a" * 39, "z" * 40, "0" * 40, self.git("rev-parse", "HEAD^{tree}")):
            with self.subTest(sha=sha):
                self.assert_error(self.plan_cli("--base", sha))
                self.assert_error(self.plan_cli("--head", sha))
        self.assert_error(self.plan_cli("--base", self.head, "--head", self.base))
        self.git("checkout", "--quiet", "--detach", self.base)
        self.write("docs/branch.md", "divergent\n")
        other = self.commit()
        self.assert_error(self.plan_cli("--base", other))
        self.assertFalse(self.output.exists())

    def test_unsupported_git_type_change_exits_two(self):
        (self.repo / "docs/README.md").unlink()
        (self.repo / "docs/README.md").symlink_to("somewhere")
        self.head = self.commit()
        self.assert_error(self.plan_cli())

    def test_malformed_impact_exits_two_without_replacing_plan(self):
        self.assertEqual(self.plan_cli().returncode, 0)
        previous = self.output.read_bytes()
        original = IMPACT.read_text()
        cases = [
            original.replace("  automation: {execution: ci-automation, always: false}\n", ""),
            original.replace(
                "full_groups: [core, observability, automation, ci-framework]",
                "full_groups: [core, observability, automation, automation]",
            ),
            original.replace(
                "core: {execution: ci-core, always: true}",
                "core: {execution: nonexistent, always: true}",
            ),
            original.replace("always: true", "always: false"),
            original.replace("full_paths:\n", "full_paths:\n  - 12\n"),
            original + "\ngroups: {}\n",
            "schema_version: 1\ngroups: [\n",
        ]
        for index, content in enumerate(cases):
            with self.subTest(index=index):
                path = self.repo / "bad-impact.yaml"
                path.write_text(content)
                self.assert_error(self.plan_cli("--impact", str(path)))
                self.assertEqual(self.output.read_bytes(), previous)

    def test_catalog_missing_execution_exits_two(self):
        catalog = yaml.safe_load(CATALOG.read_text())
        del catalog["executions"]["ci-automation"]
        path = self.repo / "catalog.yaml"
        path.write_text(yaml.safe_dump(catalog))
        self.assert_error(self.plan_cli("--catalog", str(path)))

    def test_plan_readers_reject_corrupt_and_invalid_contracts(self):
        self.assertEqual(self.plan_cli().returncode, 0)
        original = json.loads(self.output.read_text())
        variants = [
            {**original, "groups": []},
            {**original, "groups": ["core", "core"]},
            {**original, "groups": ["core", "bogus"]},
            {**original, "groups": ["automation", "core"]},
            {**original, "groups": ["core", "ci-framework"]},
            {**original, "mode": "full"},
            {**original, "schema_version": True},
            {**original, "base_sha": "HEAD"},
            {**original, "reasons": ["unknown"]},
            {**original, "extra": "field"},
        ]
        for index, payload in enumerate(variants):
            # Rehash malformed payloads to prove validation does more than check a digest.
            unsigned = {key: value for key, value in payload.items() if key != "plan_id"}
            payload["plan_id"] = hashlib.sha256(
                json.dumps(unsigned, sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest()
            with self.subTest(index=index):
                self.output.write_text(json.dumps(payload))
                self.assert_error(self.cli("groups", "--plan", str(self.output)))
        for content in (
            "{",
            json.dumps({**original, "plan_id": "0" * 64}),
            json.dumps(original)[:-1] + ',"groups":["core"]}',
        ):
            self.output.write_text(content)
            self.assert_error(self.cli("groups", "--plan", str(self.output)))


if __name__ == "__main__":
    unittest.main()
