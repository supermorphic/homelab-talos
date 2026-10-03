"""Fixed restore programs keep scratch targets and Git-owned backup programs."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[3]
POSTGRES = ROOT / "kubernetes/apps/automation-data/postgresql/app"
N8N = ROOT / "kubernetes/apps/automation/n8n/app"


class RestoreFixtureTests(unittest.TestCase):
    @staticmethod
    def render_restore_request_jobs():
        jobs = []
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "source-registry.json").write_text('{"items":[]}')
            for path, prefix in (
                ("automation-data-restore-drill.sh", "ad"),
                ("nocodb-restore-drill.sh", "nc"),
            ):
                source = (ROOT / "scripts/test/scenarios" / path).read_text()
                start = source.index("request_job_manifest() {")
                function = source[start : source.index("\n}\n", start) + 3]
                script = (
                    f"""set -euo pipefail
source scripts/test/lib/nocodb-restore-command.sh
run_hash=0123456789ab
request_job={prefix}-restore-$run_hash-request
n8n_app=ad-restore-$run_hash-n8n
app_service=nc-restore-$run_hash-nocodb
temp_dir="$1"
"""
                    + function
                    + "\nrequest_job_manifest\n"
                )
                result = subprocess.run(
                    ["bash", "-c", script, "test", directory],
                    cwd=ROOT,
                    text=True,
                    capture_output=True,
                    check=True,
                )
                jobs.append(yaml.safe_load(result.stdout))
        return jobs

    def test_restore_request_jobs_execute_only_immutable_helpers(self):
        for job, command, helper in zip(
            self.render_restore_request_jobs(),
            (
                "/helpers/automation-data-restore-request.mjs",
                "/helpers/nocodb-restore-request.mjs",
            ),
            ("n8n-test-request-helpers-v1", "nocodb-test-helpers-v1"),
            strict=True,
        ):
            pod = job["spec"]["template"]["spec"]
            container = pod["containers"][0]
            with self.subTest(job=job["metadata"]["name"]):
                self.assertEqual(container["command"], ["node", command])
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

    def test_fixed_recovery_request_requires_the_original_runtime_identity_and_response_shape(
        self,
    ):
        helper = (
            ROOT
            / "kubernetes/apps/monitoring/gatus/app/test-helpers/automation-data-restore-request.mjs"
        )
        body = {
            "database": "automation_data_canary",
            "executionId": "synthetic-execution",
            "role": "automation_data_canary_runtime",
            "status": "ok",
        }
        cases = [
            (200, body),
            (503, body),
            (200, {**body, "database": "other"}),
            (200, {**body, "role": "other"}),
            (200, {**body, "executionId": ""}),
            (200, {**body, "unexpected": "field"}),
        ]
        for index, (status, response) in enumerate(cases):
            shim = """globalThis.fetch = async (url, options) => {
  if (url !== 'http://ad-restore-0123456789ab-n8n.automation.svc.cluster.local:5678/webhook/automation-data-canary') throw new Error('endpoint_mismatch');
  if (options.method !== 'POST' || options.body !== '{}' || options.headers['X-Platform-Canary'] !== 'SYNTHETIC_TOKEN_NOT_FOR_OUTPUT') throw new Error('request_mismatch');
  return new Response(process.argv[2], {status: Number(process.argv[3])});
};
await import(process.argv[1]);
"""
            result = subprocess.run(
                [
                    "node",
                    "--input-type=module",
                    "--eval",
                    shim,
                    helper.as_uri(),
                    json.dumps(response),
                    str(status),
                ],
                capture_output=True,
                text=True,
                check=False,
                env={
                    **os.environ,
                    "APP_NAME": "ad-restore-0123456789ab-n8n",
                    "CANARY_TOKEN": "SYNTHETIC_TOKEN_NOT_FOR_OUTPUT",
                },
            )
            with self.subTest(case=index):
                self.assertEqual(result.returncode == 0, index == 0, result.stderr)
                if index == 0:
                    self.assertEqual(
                        result.stdout.strip(), "restored_runtime_credential=authenticated"
                    )
                self.assertNotIn("SYNTHETIC_TOKEN_NOT_FOR_OUTPUT", result.stdout + result.stderr)

    def test_request_helpers_are_packaged_from_their_canonical_sources(self):
        for directory, name, files in (
            (
                "kubernetes/apps/monitoring/gatus/app",
                "n8n-test-request-helpers-v1",
                {"n8n-restore-request.mjs", "automation-data-restore-request.mjs"},
            ),
            (
                "kubernetes/apps/automation-data/nocodb/app",
                "nocodb-test-helpers-v1",
                {"nocodb-restore-request.mjs"},
            ),
        ):
            rendered = subprocess.run(
                ["kustomize", "build", str(ROOT / directory)],
                capture_output=True,
                text=True,
                check=True,
            )
            helpers = [
                d
                for d in yaml.safe_load_all(rendered.stdout)
                if d["kind"] == "ConfigMap" and d["metadata"]["name"] == name
            ]
            self.assertEqual(len(helpers), 1)
            self.assertTrue(helpers[0]["immutable"])
            self.assertEqual(set(helpers[0]["data"]), files)
            for file in files:
                self.assertEqual(
                    helpers[0]["data"][file],
                    (ROOT / directory / "test-helpers" / file).read_text(),
                )

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
            "nocodb-application-probe.sh",
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
