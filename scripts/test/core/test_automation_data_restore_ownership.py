"""Exercise full-chain restored consumer and creation-owned cleanup."""

import base64
import hashlib
import json
import os
import subprocess
import unittest
from collections import Counter

from scripts.test.core.test_n8n_restore_ownership import ROOT, RestoreBackendFixture


class AutomationDataRestoreOwnershipTests(RestoreBackendFixture, unittest.TestCase):
    def execute(self, **environment):
        return subprocess.run(
            ["scripts/test/scenarios/automation-data-restore-drill.sh", str(self.root / "config")],
            cwd=ROOT,
            env={
                **os.environ,
                "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}",
                "RESTORE_TEST_ROOT": str(self.root),
                "RESTORE_TEST_FAMILY": "full-chain",
                "AUTOMATION_DATA_RESTORE_CONFIRM": "restore:automation-data:full-chain",
                "HOMELAB_TEST_RUN_DIR": str(self.root / "fixture-run"),
                "TEST_LEASE_KUBECTL": str(self.root / "bin/kubectl"),
                "TEST_CAMPAIGN_LEASE_HOLDER": "fixture-run",
                **environment,
            },
            text=True,
            capture_output=True,
            timeout=40,
            check=False,
        )

    def test_existing_job_is_never_deleted_on_preflight_refusal(self):
        result = self.execute(RESTORE_TEST_FOREIGN="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to adopt", result.stderr)
        self.assertEqual([call for call in self.calls() if call["op"] in {"create", "delete"}], [])

    def test_full_chain_checks_restored_authentication_and_removes_only_created_uids(self):
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        run = self.root / "fixture-run"
        evidence = json.loads(
            (run / "diagnostics/automation-data-restore-evidence.json").read_text()
        )
        self.assertTrue(evidence["restoredRuntimeCredentialAuthenticated"])
        self.assertTrue(evidence["restoredPermissionSeparationValidated"])
        self.assertNotEqual(
            evidence["selectedAutomationDataBundle"], evidence["postRecoveryBundle"]
        )
        deletes = [call for call in self.calls() if call["op"] == "delete"]
        self.assertEqual(len(deletes), 14)
        self.assertTrue(all("--raw" in call["args"] for call in deletes))
        self.assertEqual(json.loads((self.root / "state.json").read_text()), {})
        self.assertEqual(json.loads((run / "assertion.json").read_text())["status"], "passed")
        self.assertEqual(json.loads((run / "cleanup.json").read_text())["status"], "passed")
        records = [
            json.loads(line)
            for line in (run / "diagnostics/automation-data-restore-owned.jsonl")
            .read_text()
            .splitlines()
        ]
        self.assertEqual(
            Counter(record["kind"] for record in records),
            {
                "Job": 3,
                "StatefulSet": 2,
                "Service": 3,
                "PersistentVolumeClaim": 2,
                "CiliumNetworkPolicy": 3,
                "Deployment": 1,
            },
        )
        self.assertTrue(
            all(set(record) == {"apiVersion", "kind", "metadata"} for record in records)
        )

    PROBE_SQL = "SELECT jsonb_build_object('synthetic_probe', true);\n"
    VARIANT = "test.automation-data-restore-drill-application-probe"

    def probe_environment(self, result=None, suite=None, **overrides):
        probe = self.root / "probe.sql"
        probe.write_text(self.PROBE_SQL)
        uv = self.root / "bin/uv"
        uv.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            '[[ "$*" == "run --locked python -m scripts.test.access validate '
            + str(self.root / "config")
            + '" ]] || exit 64\n'
            + f"printf '%s\\n' '{json.dumps({'suite_id': suite or self.VARIANT})}'\n"
        )
        uv.chmod(0o755)
        if result is None:
            result = {"assertions": {"synthetic_rows_present": True}, "evidence": {"rows": 3}}
        return {
            "AUTOMATION_DATA_RESTORE_PROBE_CONFIRM": "restore:automation-data:application-probe",
            "AUTOMATION_DATA_RESTORE_PROBE_FILE": str(probe),
            "AUTOMATION_DATA_RESTORE_PROBE_SHA256": hashlib.sha256(
                self.PROBE_SQL.encode()
            ).hexdigest(),
            "AUTOMATION_DATA_RESTORE_PROBE_DATABASE": "domain_one",
            "RESTORE_TEST_PROBE_RESULT": base64.b64encode(
                (json.dumps(result) + "\n").encode()
            ).decode(),
            **overrides,
        }

    def created(self):
        path = self.root / "created.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines()]

    def test_probe_variant_delivers_pinned_input_and_removes_it_by_creation_uid(self):
        result = self.execute(**self.probe_environment())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        run = self.root / "fixture-run"
        configmaps = [obj for obj in self.created() if obj["kind"] == "ConfigMap"]
        self.assertEqual(len(configmaps), 1)
        configmap = configmaps[0]
        self.assertEqual(configmap["data"], {"probe.sql": self.PROBE_SQL})
        self.assertTrue(configmap["immutable"])
        job = next(
            obj
            for obj in self.created()
            if obj["kind"] == "Job" and obj["metadata"]["name"].endswith("-ad-load")
        )
        pod = job["spec"]["template"]["spec"]
        self.assertIn(
            {"name": "probe", "configMap": {"name": configmap["metadata"]["name"]}},
            pod["volumes"],
        )
        self.assertEqual(json.loads((self.root / "state.json").read_text()), {})
        deletes = [call for call in self.calls() if call["op"] == "delete"]
        self.assertEqual(len(deletes), 15)
        records = [
            json.loads(line)
            for line in (run / "diagnostics/automation-data-restore-owned.jsonl")
            .read_text()
            .splitlines()
        ]
        self.assertEqual(Counter(r["kind"] for r in records)["ConfigMap"], 1)
        evidence = json.loads(
            (run / "diagnostics/automation-data-restore-application-probe.json").read_text()
        )
        self.assertEqual(
            evidence,
            {
                "probeSha256": hashlib.sha256(self.PROBE_SQL.encode()).hexdigest(),
                "database": "domain_one",
                "selectedAutomationDataBundle": "automation-data-20260101T000000Z",
                "result": {
                    "assertions": {"synthetic_rows_present": True},
                    "evidence": {"rows": 3},
                },
            },
        )
        self.assertNotIn(
            "synthetic_probe",
            (run / "diagnostics")
            .joinpath("automation-data-restore-application-probe.json")
            .read_text(),
        )
        self.assertEqual(json.loads((run / "assertion.json").read_text())["status"], "passed")
        self.assertEqual(json.loads((run / "cleanup.json").read_text())["status"], "passed")

    def test_false_probe_assertion_fails_with_named_keys_and_still_cleans_up(self):
        environment = self.probe_environment(
            {"assertions": {"rows_match": True, "digest_match": False, "count_match": False}}
        )
        result = self.execute(**environment)
        self.assertNotEqual(result.returncode, 0)
        run = self.root / "fixture-run"
        assertion = json.loads((run / "assertion.json").read_text())
        self.assertEqual(assertion["status"], "failed")
        self.assertIn("count_match,digest_match", assertion["reason"])
        self.assertTrue(
            (run / "diagnostics/automation-data-restore-application-probe.json").exists()
        )
        self.assertEqual(json.loads((run / "cleanup.json").read_text())["status"], "passed")
        self.assertEqual(json.loads((self.root / "state.json").read_text()), {})

    def test_out_of_contract_probe_result_fails_the_assertion(self):
        result = self.execute(**self.probe_environment({"assertions": {}, "extra": 1}))
        self.assertNotEqual(result.returncode, 0)
        run = self.root / "fixture-run"
        self.assertEqual(json.loads((run / "assertion.json").read_text())["status"], "failed")
        self.assertEqual(json.loads((self.root / "state.json").read_text()), {})

    def test_probe_inputs_are_refused_before_any_kubernetes_request(self):
        cases = (
            ("digest", {"AUTOMATION_DATA_RESTORE_PROBE_SHA256": "0" * 64}, None, None),
            ("database", {"AUTOMATION_DATA_RESTORE_PROBE_DATABASE": "Bad"}, None, None),
            (
                "confirmation",
                {"AUTOMATION_DATA_RESTORE_PROBE_CONFIRM": "restore:automation-data:other"},
                None,
                None,
            ),
            ("binding", {}, "test.automation-data-restore-drill", None),
            ("unconfirmed-inputs", {}, None, "AUTOMATION_DATA_RESTORE_PROBE_CONFIRM"),
        )
        for name, overrides, suite, removed in cases:
            # The fake binding is rewritten per case, so build each environment in turn.
            environment = self.probe_environment(suite=suite, **overrides)
            environment.pop(removed, None)
            with self.subTest(case=name):
                (self.root / "calls.jsonl").unlink(missing_ok=True)
                ledger = self.root / "fixture-run/diagnostics/automation-data-restore-owned.jsonl"
                ledger.unlink(missing_ok=True)
                result = self.execute(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "calls.jsonl").exists(), name)


if __name__ == "__main__":
    unittest.main()
