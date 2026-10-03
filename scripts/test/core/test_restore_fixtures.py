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
        ):
            self.assertEqual(helpers["data"][name], (POSTGRES / "test-helpers" / name).read_text())

    def test_restore_wrappers_reject_production_or_unbound_hosts_before_reading_helpers(self):
        for path in (
            POSTGRES / "test-helpers/automation-data-restore.sh",
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
