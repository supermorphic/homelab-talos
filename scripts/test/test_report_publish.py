"""Offline tests for persistent report publication state and safety."""

from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("report_publish.py")
SPEC = importlib.util.spec_from_file_location("report_publish", MODULE_PATH)
assert SPEC and SPEC.loader
report_publish = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(report_publish)

RUN_ID = "20260727T120000Z-aaaaaaaaaaaa-operator-00000001"
MAIN_SHA = "a" * 40


class ReportPublishTests(unittest.TestCase):
    def make_inputs(
        self,
        root: Path,
        *,
        git_sha: str = MAIN_SHA,
        dirty: bool = False,
        run_id: str = RUN_ID,
        now: str = "2026-07-27T12:01:00Z",
        cluster_name: str | None = "homelab",
    ) -> argparse.Namespace:
        run = root / "results" / run_id
        (run / "logs").mkdir(parents=True)
        (run / "diagnostics").mkdir()
        (run / "logs" / "runner.log").write_text("sanitized\n", encoding="utf-8")
        summary = {
            "schema_version": 1,
            "run_id": run_id,
            "source": "chainsaw",
            "framework": "chainsaw",
            "suite": "platform",
            "tier": "smoke",
            "target": "cilium",
            "scenario": "health",
            "scope": "network",
            "intent": "acceptance",
            "execution_origin": "operator",
            "start": "2026-07-27T11:59:50Z",
            "end": "2026-07-27T12:00:00Z",
            "duration_seconds": 10,
            "result": "passed",
            "git_sha": git_sha,
            "junit": {
                "tests": 2,
                "passed": 2,
                "failures": 0,
                "errors": 0,
                "skipped": 0,
            },
        }
        environment = {
            "schema_version": 1,
            "run_id": run_id,
            "git": {"sha": git_sha, "dirty": dirty},
            "cluster": {"name": cluster_name},
        }
        evidence = {
            "schema_version": 1,
            "run_id": run_id,
            "artifacts": [{"path": "logs/runner.log"}],
        }
        (run / "summary.json").write_text(json.dumps(summary), encoding="utf-8")
        (run / "environment.json").write_text(json.dumps(environment), encoding="utf-8")
        (run / "evidence.json").write_text(json.dumps(evidence), encoding="utf-8")
        (run / "junit.xml").write_text(
            '<testsuite tests="2"><testcase name="one"/><testcase name="two"/></testsuite>\n',
            encoding="utf-8",
        )
        report = root / "reports" / run_id / "awesome"
        report.mkdir(parents=True)
        (report / "index.html").write_text("<html>fixture</html>\n", encoding="utf-8")
        remote_catalog = root / "remote-catalog.json"
        remote_state = root / "remote-state.json"
        history = root / "history.jsonl"
        remote_catalog.write_text(
            '{"schema_version":1,"generated_at":null,"runs":[]}\n', encoding="utf-8"
        )
        remote_state.write_text(
            '{"schema_version":1,"generation":"bootstrap","seen_runs":{},'
            '"runs_total":{},"cases_total":{},"last_success":{}}\n',
            encoding="utf-8",
        )
        history.write_text('{"fixture":"history"}\n', encoding="utf-8")
        return argparse.Namespace(
            run_dir=run,
            report_dir=report.parent,
            remote_catalog=remote_catalog,
            remote_state=remote_state,
            history=history,
            origin_main_sha=MAIN_SHA,
            flux_main_sha=MAIN_SHA,
            output_dir=root / "bundle",
            now=now,
        )

    def test_prepares_authoritative_report_metrics_redirect_and_artifact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args = self.make_inputs(root)
            result = report_publish.prepare(args)
            self.assertEqual(result["status"], "prepared")
            self.assertTrue(result["authoritative"])
            generation = args.output_dir / "generation" / result["generation"]
            catalog = json.loads((generation / "catalog.json").read_text())
            self.assertTrue(catalog["runs"][0]["authoritative"])
            self.assertTrue(
                (generation / "latest" / "smoke" / "cilium" / "health" / "index.html").is_file()
            )
            self.assertTrue((generation / "latest" / "overall" / "index.html").is_file())
            homepage = json.loads((generation / "api" / "homepage.json").read_text())
            self.assertEqual(
                homepage,
                {
                    "items": [
                        {
                            "name": "✓ Latest Overall",
                            "end": "2026-07-27T12:00:00Z",
                            "result": "passed",
                            "path": "/latest/overall/",
                        }
                    ]
                },
            )
            metrics = (generation / "api" / "metrics.prom").read_text()
            self.assertIn("homelab_test_last_run_status", metrics)
            self.assertNotIn(RUN_ID, metrics)
            self.assertNotIn(MAIN_SHA, metrics)
            self.assertTrue((args.output_dir / "artifact" / f"{RUN_ID}.tar.gz").is_file())
            self.assertTrue((args.output_dir / "manifest.sha256").is_file())

    def test_stale_or_dirty_run_is_candidate_and_has_no_latest_redirect(self):
        for git_sha, dirty in (("b" * 40, False), (MAIN_SHA, True)):
            with (
                self.subTest(git_sha=git_sha, dirty=dirty),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                args = self.make_inputs(root, git_sha=git_sha, dirty=dirty)
                result = report_publish.prepare(args)
                self.assertFalse(result["authoritative"])
                generation = args.output_dir / "generation" / result["generation"]
                self.assertFalse((generation / "latest").exists())
                homepage = json.loads((generation / "api" / "homepage.json").read_text())
                self.assertEqual(homepage, {"items": []})

    def test_offline_run_uses_bounded_unavailable_cluster_label(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args = self.make_inputs(root, cluster_name=None)
            result = report_publish.prepare(args)
            generation = args.output_dir / "generation" / result["generation"]
            catalog = json.loads((generation / "catalog.json").read_text())
            self.assertEqual(catalog["runs"][0]["cluster"], "unavailable")

    def test_idempotent_republish_does_not_build_or_increment(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args = self.make_inputs(root)
            files = report_publish.canonical_files(args.run_dir)
            digest = report_publish.tree_digest(args.run_dir, files)
            args.remote_state.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "generation": "old",
                        "seen_runs": {RUN_ID: digest},
                        "runs_total": {},
                        "cases_total": {},
                        "last_success": {},
                    }
                ),
                encoding="utf-8",
            )
            result = report_publish.prepare(args)
            self.assertEqual(result["status"], "idempotent")
            self.assertFalse(args.output_dir.exists())

    def test_same_run_id_with_different_content_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args = self.make_inputs(root)
            args.remote_state.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "generation": "old",
                        "seen_runs": {RUN_ID: "0" * 64},
                        "runs_total": {},
                        "cases_total": {},
                        "last_success": {},
                    }
                ),
                encoding="utf-8",
            )
            with self.assertRaises(report_publish.PublishError):
                report_publish.prepare(args)

    def test_unindexed_file_is_not_archived_and_report_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args = self.make_inputs(root)
            (args.run_dir / "diagnostics" / "not-indexed.secret").write_text(
                "must not persist\n", encoding="utf-8"
            )
            result = report_publish.prepare(args)
            artifact = args.output_dir / "artifact" / f"{RUN_ID}.tar.gz"
            import tarfile

            with tarfile.open(artifact) as archive:
                self.assertNotIn("diagnostics/not-indexed.secret", archive.getnames())
            self.assertEqual(result["status"], "prepared")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            args = self.make_inputs(root)
            (args.report_dir / "unsafe").symlink_to(args.run_dir / "summary.json")
            with self.assertRaises(report_publish.PublishError):
                report_publish.prepare(args)

    def test_retention_preserves_latest_per_key_beyond_age_and_count_limits(self):
        now = dt.datetime(2026, 7, 27, tzinfo=dt.UTC)
        entries = []
        for index in range(205):
            end = now - dt.timedelta(days=100 + index)
            entries.append(
                {
                    "run_id": (f"{end.strftime('%Y%m%dT%H%M%SZ')}-aaaaaaaaaaaa-agent-{index:08x}"),
                    "source": "validation",
                    "tier": "offline",
                    "target": "repository",
                    "scenario": "lint",
                    "end": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
                }
            )
        entries[-1]["target"] = "protected-old-key"
        kept, pruned = report_publish.retain_runs(entries, now)
        kept_ids = {entry["run_id"] for entry in kept}
        self.assertIn(entries[0]["run_id"], kept_ids)
        self.assertIn(entries[-1]["run_id"], kept_ids)
        self.assertGreater(len(pruned), 0)

    def test_lifetime_counters_survive_catalog_pruning(self):
        entry = {
            "source": "chainsaw",
            "tier": "smoke",
            "target": "cilium",
            "scenario": "health",
            "cluster": "homelab",
            "execution_origin": "operator",
            "result": "passed",
            "junit": {"passed": 2, "failures": 0, "errors": 0, "skipped": 0},
        }
        state = {"runs_total": {}, "cases_total": {}}
        report_publish.update_counters(state, entry)
        report_publish.update_counters(state, entry)
        self.assertEqual(sum(state["runs_total"].values()), 2)
        self.assertEqual(sum(state["cases_total"].values()), 4)
        self.assertIn("homelab_test_runs_total", report_publish.render_metrics([], state))

    def test_last_success_metric_survives_report_retention(self):
        entry = {
            "source": "chainsaw",
            "tier": "smoke",
            "target": "cilium",
            "scenario": "health",
            "cluster": "homelab",
            "execution_origin": "operator",
            "result": "passed",
            "authoritative": True,
            "end": "2026-07-27T12:00:00Z",
            "junit": {"passed": 1, "failures": 0, "errors": 0, "skipped": 0},
        }
        state = {"runs_total": {}, "cases_total": {}, "last_success": {}}
        report_publish.update_counters(state, entry)
        latest_failure = {
            **entry,
            "run_id": RUN_ID,
            "result": "failed",
            "end": "2026-07-28T12:00:00Z",
            "duration_seconds": 4,
            "junit": {
                "tests": 1,
                "passed": 0,
                "failures": 1,
                "errors": 0,
                "skipped": 0,
            },
        }
        metrics = report_publish.render_metrics([latest_failure], state)
        expected = str(int(dt.datetime(2026, 7, 27, 12, tzinfo=dt.UTC).timestamp()))
        self.assertIn("homelab_test_last_success_timestamp_seconds{", metrics)
        self.assertIn(f"}} {expected}", metrics)

    def test_homepage_rollups_select_latest_authoritative_runs(self):
        def entry(
            run_id: str,
            end: str,
            result: str,
            *,
            source: str = "chainsaw",
            tier: str = "smoke",
            target: str = "platform",
            authoritative: bool = True,
        ):
            return {
                "run_id": run_id,
                "end": end,
                "result": result,
                "source": source,
                "tier": tier,
                "target": target,
                "scenario": None,
                "authoritative": authoritative,
            }

        entries = [
            entry("validation-old", "2026-07-20T12:00:00Z", "passed", source="validation"),
            entry("validation-new", "2026-07-21T12:00:00Z", "failed", source="validation"),
            entry("platform", "2026-07-22T12:00:00Z", "broken"),
            entry("media", "2026-07-23T12:00:00Z", "skipped", target="media"),
            entry(
                "resilience",
                "2026-07-24T12:00:00Z",
                "passed",
                tier="resilience",
                target="plex-cross-node-reschedule",
            ),
            entry(
                "conformance",
                "2026-07-25T12:00:00Z",
                "passed",
                source="sonobuoy",
                tier="conformance",
                target="quick",
            ),
            entry(
                "candidate-newer",
                "2026-07-26T12:00:00Z",
                "failed",
                tier="resilience",
                target="qbittorrent-vpn-disconnect",
                authoritative=False,
            ),
        ]

        homepage = report_publish.render_homepage(entries)
        self.assertEqual(
            [(item["name"], item["path"]) for item in homepage["items"]],
            [
                ("✓ Latest Overall", "/latest/overall/"),
                ("✗ Validate", "/latest/validation/"),
                ("✗ Platform Smoke", "/latest/platform-smoke/"),
                ("! Media Smoke", "/latest/media-smoke/"),
                ("✓ Resilience", "/latest/resilience/"),
                ("✓ Conformance", "/latest/conformance/"),
            ],
        )
        self.assertEqual(homepage["items"][0]["end"], "2026-07-25T12:00:00Z")
        self.assertEqual(homepage["items"][1]["result"], "failed")


if __name__ == "__main__":
    unittest.main()
