"""Fixed restore programs keep scratch targets and Git-owned backup programs."""

import os
import subprocess
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
POSTGRES = ROOT / "kubernetes/apps/automation-data/postgresql/app"
N8N = ROOT / "kubernetes/apps/automation/n8n/app"


class RestoreFixtureTests(unittest.TestCase):
    @staticmethod
    def render_restore_jobs():
        def function(path, name):
            source = (ROOT / path).read_text()
            start = source.index(name + "() {")
            return source[start : source.index("\n}\n", start) + 3]

        prelude = """set -euo pipefail
source scripts/test/lib/automation-data-restore-command.sh
source scripts/test/lib/n8n-restore-command.sh
source scripts/test/lib/nocodb-restore-command.sh
run_hash=0123456789ab
backup_configmap=automation-data-postgresql-backup-synthetic
selected_bundle=automation-data-20260825T003000Z
ad_namespace=automation-data
n8n_namespace=automation
ad_service=ad-restore-$run_hash-db
n8n_service=ad-restore-$run_hash-n8n-db
ad_restore_job=ad-restore-$run_hash-ad-load
n8n_restore_job=ad-restore-$run_hash-n8n-load
database_service=nc-restore-$run_hash-db
restore_job=nc-restore-$run_hash-load
"""
        scripts = (
            function(
                "scripts/test/scenarios/automation-data-restore-drill.sh", "restore_job_manifest"
            )
            + "restore_job_manifest automation-data\n",
            function(
                "scripts/test/scenarios/automation-data-restore-drill.sh", "restore_job_manifest"
            )
            + "restore_job_manifest n8n\n",
            function("scripts/test/scenarios/nocodb-restore-drill.sh", "restore_job_manifest")
            + "restore_job_manifest\n",
            "nocodb_restore_preflight_manifest nc-restore-$run_hash-preflight $run_hash\n",
        )
        documents = []
        for script in scripts:
            rendered = subprocess.run(
                ["bash", "-c", prelude + script],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=True,
            )
            documents.append(yaml.safe_load(rendered.stdout))
        return documents

    def test_restore_jobs_execute_only_immutable_canonical_helpers(self):
        jobs = self.render_restore_jobs()
        self.assertEqual(len(jobs), 4)
        for job, command, helper in zip(
            jobs,
            (
                "/helpers/automation-data-restore.sh",
                "/helpers/n8n-restore-isolated.sh",
                "/helpers/nocodb-restore.sh",
                "/helpers/nocodb-restore-preflight.sh",
            ),
            (
                "automation-data-test-helpers-v1",
                "n8n-test-helpers-v1",
                "automation-data-test-helpers-v1",
                "automation-data-test-helpers-v1",
            ),
            strict=True,
        ):
            pod = job["spec"]["template"]["spec"]
            container = pod["containers"][0]
            with self.subTest(job=job["metadata"]["name"]):
                self.assertEqual(container["command"], ["/bin/sh", "-eu", command])
                self.assertNotIn("args", container)
                self.assertTrue(
                    any(v.get("configMap", {}).get("name") == helper for v in pod["volumes"])
                )
                self.assertTrue(
                    any(
                        v["mountPath"] == "/helpers" and v.get("readOnly")
                        for v in container["volumeMounts"]
                    )
                )

    def test_fixed_postgres_helpers_are_immutable_and_use_canonical_backup_sources(self):
        rendered = subprocess.run(
            ["kustomize", "build", str(POSTGRES)], text=True, capture_output=True, check=True
        )
        helpers = next(
            (
                doc
                for doc in yaml.safe_load_all(rendered.stdout)
                if doc["kind"] == "ConfigMap"
                and doc["metadata"]["name"] == "automation-data-test-helpers-v1"
            ),
            None,
        )
        self.assertIsNotNone(helpers)
        self.assertTrue(helpers["immutable"])
        for name in ("backup.sh", "update-backup-status.sql"):
            self.assertEqual(helpers["data"][name], (POSTGRES / "scripts" / name).read_text())
        for name in (
            "restore-validation.sh",
            "restore-permissions.sh",
            "restore-selection.sh",
            "restore-body.sh",
            "automation-data-restore.sh",
            "nocodb-restore-preflight.sh",
            "nocodb-restore.sh",
            "nocodb-restore-assertions.sh",
        ):
            self.assertEqual(helpers["data"][name], (POSTGRES / "test-helpers" / name).read_text())

    def test_restore_wrappers_reject_production_or_unbound_hosts_before_reading_helpers(self):
        for path in (
            POSTGRES / "test-helpers/automation-data-restore.sh",
            POSTGRES / "test-helpers/nocodb-restore.sh",
            N8N / "test-helpers/n8n-restore-isolated.sh",
        ):
            self.assertTrue(path.is_file())
            for host in (
                "automation-data-postgresql",
                "n8n-postgresql",
                "localhost",
                "ad-restore-other-db",
                "192.0.2.1",
                "ad-restore-abc12345def6-db.other",
            ):
                result = subprocess.run(
                    ["/bin/sh", "-eu", str(path)],
                    text=True,
                    capture_output=True,
                    check=False,
                    env={**os.environ, "PGHOST": host},
                )
                with self.subTest(path=path.name, host=host):
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("scratch database host", result.stderr)
                    self.assertNotIn("cannot open", result.stderr)

    def test_n8n_isolated_restore_is_packaged_with_its_common_program(self):
        rendered = subprocess.run(
            ["kustomize", "build", str(N8N)], text=True, capture_output=True, check=True
        )
        helpers = next(
            doc
            for doc in yaml.safe_load_all(rendered.stdout)
            if doc["kind"] == "ConfigMap" and doc["metadata"]["name"] == "n8n-test-helpers-v1"
        )
        self.assertTrue(helpers["immutable"])
        self.assertEqual(
            helpers["data"]["n8n-restore-isolated.sh"],
            (N8N / "test-helpers/n8n-restore-isolated.sh").read_text(),
        )
