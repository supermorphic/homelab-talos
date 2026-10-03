"""The real Chainsaw coordinator owns scoped credentials through finalization."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
SUITE = "chainsaw.smoke.cluster.flux-ready"


class ChainsawRoutingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        binary_dir = self.root / "bin"
        binary_dir.mkdir()
        shutil.copy2(ROOT / "tests/fixtures/test-access/fake-uv.sh", binary_dir / "uv")
        (binary_dir / "kubectl").write_text("#!/usr/bin/env bash\nexit 0\n")
        (binary_dir / "chainsaw").write_text(
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == version ]]; then echo 'Version: synthetic'; exit 0; fi
[[ "$TEST_KUBECONFIG" == "$TEST_FIXTURE_ACCESS_ROOT/private/"* &&
   "$TEST_KUBECONFIG" == "$KUBECONFIG" &&
   "$TEST_KUBECONFIG" == "$TEST_ACCESS_CONFIG" && -f "$TEST_KUBECONFIG" ]]
printf '%s\\n' "$TEST_KUBECONFIG" >"$TEST_FIXTURE_ACCESS_ROOT/backend-config"
report=''
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == --report-path ]]; then report="$2"; shift; fi
  shift
done
[[ -n "$report" ]]
printf '%s\\n' '<testsuite name="native" tests="1" failures="0" errors="0" skipped="0"><testcase name="assertion"/></testsuite>' >"$report/junit.xml"
if [[ "${TEST_FIXTURE_CHAINSAW_SIGNAL:-}" == true ]]; then
  trap '[[ -f "$TEST_KUBECONFIG" ]]; touch "$TEST_FIXTURE_ACCESS_ROOT/backend-cleaned"; exit 0' INT TERM
  kill -TERM "$PPID"
  sleep 1
fi
"""
        )
        for name in ("chainsaw", "kubectl"):
            (binary_dir / name).chmod(0o755)
        self.environment = {
            **os.environ,
            "PATH": f"{binary_dir}:{os.environ['PATH']}",
            "TEST_FIXTURE_REAL_UV": shutil.which("uv"),
            "TEST_FIXTURE_ACCESS_TRACE": str(self.root / "trace"),
            "TEST_FIXTURE_ACCESS_ROOT": str(self.root),
            "TEST_FIXTURE_ACCESS_FINALIZATION_ROOT": str(self.root / "results"),
            "TEST_RESULTS_ROOT": str(self.root / "results"),
            "TEST_KUBECONFIG": "",
            "TEST_ACCESS_CONFIG": "",
            "TEST_EXECUTION_ORIGIN": "agent",
            "KUBECONFIG": "/synthetic/ambient/admin",
        }
        self.environment.pop("TEST_CATALOG_PATH", None)

    def execute(self, arguments=None, **environment):
        return subprocess.run(
            ["scripts/test/run-chainsaw.sh", *(arguments or ["smoke", "cluster", "flux-ready"])],
            cwd=ROOT,
            env={**self.environment, **environment},
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )

    def summary(self):
        paths = list((self.root / "results").glob("*/summary.json"))
        self.assertEqual(len(paths), 1)
        return json.loads(paths[0].read_text())

    def test_direct_run_replaces_ambient_access_and_finalizes_before_config_deletion(self):
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        config = Path((self.root / "backend-config").read_text().strip())
        self.assertFalse(config.exists())
        self.assertEqual(self.summary()["result"], "passed")
        trace = (self.root / "trace").read_text().splitlines()
        self.assertEqual(sum(line.startswith("prepare ") for line in trace), 1)
        self.assertEqual(sum(line.startswith("remove ") for line in trace), 1)

    def test_unbound_and_fixture_catalog_inputs_are_rejected_before_backend(self):
        config = self.root / "unbound"
        config.touch()
        catalog = self.root / "catalog.yaml"
        shutil.copy2(ROOT / "tests/catalog.yaml", catalog)
        for environment in ({"TEST_KUBECONFIG": str(config)}, {"TEST_CATALOG_PATH": str(catalog)}):
            with self.subTest(environment=environment):
                result = self.execute(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "backend-config").exists())
                trace = self.root / "trace"
                if trace.exists():
                    self.assertNotIn("prepare ", trace.read_text())

    def test_inherited_parent_config_is_retained_without_enrollment(self):
        config = self.root / "private" / "parent" / "config"
        config.parent.mkdir(parents=True)
        config.touch()
        (config.parent / "binding.json").write_text(json.dumps({"suite_id": SUITE}))
        result = self.execute(TEST_KUBECONFIG=str(config), TEST_ACCESS_CONFIG=str(config))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(config.exists())
        self.assertEqual((self.root / "backend-config").read_text().strip(), str(config))
        trace = (self.root / "trace").read_text()
        self.assertNotIn("prepare ", trace)
        self.assertNotIn("remove ", trace)

    def test_private_config_cleanup_failure_preserves_primary_assertion(self):
        result = self.execute(TEST_FIXTURE_ACCESS_REMOVE_FAIL="true")
        self.assertNotEqual(result.returncode, 0)
        summary = self.summary()
        self.assertEqual(summary["result"], "broken")
        self.assertEqual(summary["phases"]["primary"]["exit_code"], 0)
        self.assertEqual(summary["phases"]["assertion"]["status"], "passed")
        self.assertEqual(summary["phases"]["cleanup"]["status"], "failed")

    def test_rejected_refresh_finalizes_and_removes_config_without_backend(self):
        result = self.execute(TEST_FIXTURE_ACCESS_CHECK_FAIL="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "backend-config").exists())
        self.assertEqual(self.summary()["result"], "broken")
        self.assertEqual(list((self.root / "private").glob("*/config")), [])

    def test_setup_failure_also_records_private_config_cleanup_failure(self):
        result = self.execute(
            TEST_FIXTURE_ACCESS_CHECK_FAIL="true", TEST_FIXTURE_ACCESS_REMOVE_FAIL="true"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "backend-config").exists())
        summary = self.summary()
        self.assertEqual(summary["result"], "broken")
        self.assertEqual(summary["phases"]["assertion"]["status"], "not-classified")
        self.assertEqual(summary["phases"]["cleanup"]["status"], "failed")

    def test_diagnostics_dispatch_finalizes_before_removing_its_config(self):
        result = self.execute(arguments=["diagnostics", "cluster"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.summary()["result"], "passed")
        self.assertEqual(list((self.root / "private").glob("*/config")), [])

    def test_catalog_setup_failure_also_records_private_config_cleanup_failure(self):
        result = subprocess.run(
            ["scripts/test/run-catalog-suite.sh", "verification.metrics-server", "--", "true"],
            cwd=ROOT,
            env={
                **self.environment,
                "TEST_FIXTURE_ACCESS_CHECK_FAIL": "true",
                "TEST_FIXTURE_ACCESS_REMOVE_FAIL": "true",
            },
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        summary = self.summary()
        self.assertEqual(summary["result"], "broken")
        self.assertEqual(summary["phases"]["assertion"]["status"], "not-classified")
        self.assertEqual(summary["phases"]["cleanup"]["status"], "failed")

    def test_conformance_rejects_unbound_config_before_issuance(self):
        config = self.root / "unbound"
        config.touch()
        result = subprocess.run(
            ["scripts/test/run-conformance.sh", str(config)],
            cwd=ROOT,
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / "trace").exists())

    def test_signal_waits_for_backend_cleanup_before_removing_config(self):
        result = self.execute(TEST_FIXTURE_CHAINSAW_SIGNAL="true")
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertTrue((self.root / "backend-cleaned").exists())
        self.assertEqual(list((self.root / "private").glob("*/config")), [])
        summary = self.summary()
        self.assertEqual(summary["result"], "broken")
        self.assertEqual(summary["phases"]["assertion"]["status"], "not-classified")


if __name__ == "__main__":
    unittest.main()
