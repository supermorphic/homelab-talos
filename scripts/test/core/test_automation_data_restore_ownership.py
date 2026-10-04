"""Exercise full-chain restored consumer and creation-owned cleanup."""

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


if __name__ == "__main__":
    unittest.main()
