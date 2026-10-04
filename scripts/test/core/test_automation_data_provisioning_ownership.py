"""Provisioning refusal does not grant authority over existing Job names."""

import os
import subprocess
import unittest

from scripts.test.core.test_n8n_restore_ownership import ROOT, RestoreBackendFixture


class AutomationDataProvisioningOwnershipTests(RestoreBackendFixture, unittest.TestCase):
    def test_rejected_application_request_never_deletes_uncreated_jobs(self):
        curl = self.root / "bin/curl"
        curl.write_text("#!/bin/sh\nexit 22\n")
        curl.chmod(0o755)
        result = subprocess.run(
            ["scripts/test/scenarios/automation-data-provisioning.sh", str(self.root / "config")],
            cwd=ROOT,
            env={
                **os.environ,
                "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}",
                "RESTORE_TEST_ROOT": str(self.root),
                "AUTOMATION_DATA_PROVISIONING_CONFIRM": "test:automation-data:provisioning",
                "AUTOMATION_DATA_PROVISIONING_URL": "https://n8n.lab.supermorphic.com/webhook/automation-data-provision",
                "AUTOMATION_DATA_PROVISIONING_TOKEN": "synthetic_application_token_fixture_0123456789",
                "HOMELAB_TEST_RUN_DIR": str(self.root / "fixture-run"),
                "TEST_LEASE_KUBECTL": str(self.root / "bin/kubectl"),
                "TEST_CAMPAIGN_LEASE_HOLDER": "fixture-run",
            },
            text=True,
            capture_output=True,
            timeout=30,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("workflow rejected the provision request", result.stderr)
        self.assertEqual([call for call in self.calls() if call["op"] in {"create", "delete"}], [])
        self.assertNotIn("synthetic_application_token", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
