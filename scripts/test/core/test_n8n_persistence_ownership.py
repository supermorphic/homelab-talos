"""Persistence sentinel helpers retain their own API creation identity."""

import json
import os
import subprocess
import unittest

from scripts.test.core.test_n8n_restore_ownership import ROOT, RestoreBackendFixture


class N8nPersistenceOwnershipTests(RestoreBackendFixture, unittest.TestCase):
    def test_cleanup_failure_preserves_primary_nonzero_and_signal_exit(self):
        source = (ROOT / "scripts/test/scenarios/n8n-persistence.sh").read_text()
        functions = "\n".join(
            name + "() {" + source.split(name + "() {", 1)[1].split("\n}\n", 1)[0] + "\n}"
            for name in ("write_phase", "cleanup")
        )
        for primary in (7, 143):
            with self.subTest(primary=primary):
                body = (
                    """set -euo pipefail
run_dir=$RESTORE_TEST_ROOT/fixture-run
ledger=$RESTORE_TEST_ROOT/ledger.jsonl
namespace=automation
writer_job=synthetic-write
reader_job=synthetic-reader
cleanup_job=synthetic-cleanup
sentinel_possible=false
disruption_started=false
tmp_dir=''
safe_rollout() { return 0; }
kc=(safe_rollout)
test_delete_owned() { return 1; }
job_absent() { return 0; }
"""
                    + functions
                    + f"\ntrap cleanup EXIT\nexit {primary}\n"
                )
                result = subprocess.run(
                    ["bash", "-c", body],
                    cwd=ROOT,
                    env={**os.environ, "RESTORE_TEST_ROOT": str(self.root)},
                    text=True,
                    capture_output=True,
                    timeout=10,
                    check=False,
                )
                self.assertEqual(result.returncode, primary, result.stdout + result.stderr)
                phase = json.loads((self.root / "fixture-run/cleanup.json").read_text())
                self.assertEqual(phase["status"], "failed")

    def test_real_sentinel_helper_uses_fixed_program_and_uid_cleanup(self):
        source = (ROOT / "scripts/test/scenarios/n8n-persistence.sh").read_text()
        functions = "\n".join(
            name + "() {" + source.split(name + "() {", 1)[1].split("\n}\n", 1)[0] + "\n}"
            for name in ("job_manifest", "run_sentinel_job")
        )
        body = (
            """set -euo pipefail
source scripts/test/lib/owned-resources.sh
source scripts/test/lib/job.sh
namespace=automation
run_hash=0123456789ab
sentinel=/data/.homelab-n8n-persistence-$run_hash
sentinel_value=homelab-n8n-persistence-$run_hash
ledger=$RESTORE_TEST_ROOT/ledger.jsonl
kc=(kubectl --kubeconfig "$RESTORE_TEST_ROOT/config" --namespace "$namespace")
verify_lease() { return 0; }
current_n8n_node() { echo synthetic-node; }
job_absent() { [[ -z "$("${kc[@]}" get job "$1" --ignore-not-found --output name)" ]]; }
"""
            + functions
            + "\nrun_sentinel_job n8n-persistence-0123456789ab-write synthetic-node write\n"
        )
        result = subprocess.run(
            ["bash", "-c", body],
            cwd=ROOT,
            env={
                **os.environ,
                "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}",
                "RESTORE_TEST_ROOT": str(self.root),
            },
            text=True,
            capture_output=True,
            timeout=20,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads((self.root / "state.json").read_text()), {})
        deletes = [call for call in self.calls() if call["op"] == "delete"]
        self.assertEqual(len(deletes), 1)
        self.assertIn("--raw", deletes[0]["args"])
        record = json.loads((self.root / "ledger.jsonl").read_text())
        self.assertEqual(record["metadata"]["uid"], "api-n8n-persistence-0123456789ab-write")
        self.assertEqual(set(record), {"apiVersion", "kind", "metadata"})


if __name__ == "__main__":
    unittest.main()
