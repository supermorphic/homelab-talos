"""The real Chainsaw coordinator owns scoped credentials through finalization."""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
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
        shutil.copy2(ROOT / "tests/fixtures/test-access/fake-mise.sh", binary_dir / "mise")
        shutil.copy2(ROOT / "tests/fixtures/test-access/fake-talosctl.sh", binary_dir / "talosctl")
        (binary_dir / "kubectl").write_text("#!/usr/bin/env bash\nexit 0\n")
        (binary_dir / "chainsaw").write_text(
            """#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == version ]]; then echo 'Version: synthetic'; exit 0; fi
[[ "$TEST_KUBECONFIG" == "$TEST_FIXTURE_ACCESS_ROOT/private/"* &&
   "$TEST_KUBECONFIG" == "$KUBECONFIG" &&
   "$TEST_KUBECONFIG" == "$TEST_ACCESS_CONFIG" && -f "$TEST_KUBECONFIG" ]]
printf '%s\\n' "$TEST_KUBECONFIG" >"$TEST_FIXTURE_ACCESS_ROOT/backend-config"
printf '%s' "${TEST_ACCESS_ACCEPTANCE_CONFIRM:-}" >"$TEST_FIXTURE_ACCESS_ROOT/backend-intent"
report=''
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == --report-path ]]; then report="$2"; shift; fi
  shift
done
[[ -n "$report" ]]
printf '%s\\n' '<testsuite name="native" tests="1" failures="0" errors="0" skipped="0"><testcase name="assertion"/></testsuite>' >"$report/junit.xml"
if [[ "${TEST_FIXTURE_CHAINSAW_FAIL:-}" == true ]]; then
  printf '%s\\n' '<testsuite name="native" tests="1" failures="1" errors="0" skipped="0"><testcase name="assertion"><failure/></testcase></testsuite>' >"$report/junit.xml"
  exit 7
fi
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
            "TEST_FIXTURE_TALOS_ROOT": str(ROOT),
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

    def test_missing_reader_prerequisite_is_fully_synthetic_and_still_rejects_operator_role(self):
        prerequisite_root = self.root / "prerequisite-root"
        prerequisite_root.mkdir()
        git = self.root / "bin/git"
        git.write_text(
            '#!/usr/bin/env bash\nset -euo pipefail\n'
            '[[ "$*" == "rev-parse --show-toplevel" ]] || exit 2\n'
            'printf "%s\\n" "$TEST_FIXTURE_TALOS_ROOT"\n'
        )
        git.chmod(0o755)
        for role, expected in (("os:reader", 0), ("os:operator", 1)):
            with self.subTest(role=role):
                result = subprocess.run(
                    ["bash", "-c", ('set -euo pipefail; source scripts/test/lib/access.sh; '
                     'test_access_prerequisites \'{"prerequisites":["talos-reader"]}\'; '
                     '[[ "$TALOSCONFIG" == "$TEST_FIXTURE_TALOS_ROOT/.talos/config" ]]')],
                    cwd=ROOT,
                    env={**self.environment, "TEST_FIXTURE_TALOS_ROOT": str(prerequisite_root),
                         "TEST_FIXTURE_TALOS_ROLE": role, "TALOSCONFIG": "/synthetic/operator"},
                    capture_output=True, text=True, timeout=10, check=False,
                )
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertFalse((prerequisite_root / ".talos/config").exists())
        self.assertEqual((self.root / "trace").read_text().splitlines(),
                         ["talos-reader-bootstrap", "talos-reader-bootstrap"])

    def test_campaign_missing_reader_prerequisite_is_fully_synthetic(self):
        shutil.copy2(ROOT / "tests/fixtures/campaign/fake-mise.sh", self.root / "bin/mise")
        self.environment["CAMPAIGN_TEST_REPO_ROOT"] = str(ROOT)
        self.test_missing_reader_prerequisite_is_fully_synthetic_and_still_rejects_operator_role()

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

    def test_scoped_acceptance_keeps_native_result_and_selected_config(self):
        result = self.execute(
            TEST_ACCESS_ACCEPTANCE_CONFIRM="verify:scoped-access:ttl-and-denials"
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"acceptance {SUITE}", (self.root / "trace").read_text())
        self.assertEqual((self.root / "backend-intent").read_text(), "")
        run_dir = next((self.root / "results").iterdir())
        junit = ET.parse(run_dir / "junit.xml").getroot()
        names = {case.get("name") for case in junit.iter("testcase")}
        self.assertIn("assertion", names)
        self.assertIn("scoped-client-refresh-and-boundary", names)
        native = ET.parse(run_dir / "diagnostics/chainsaw-junit.xml").getroot()
        self.assertEqual([case.get("name") for case in native.iter("testcase")], ["assertion"])
        self.assertEqual(self.summary()["result"], "passed")
        self.assertEqual(list((self.root / "private").glob("*/config")), [])

    def test_scoped_acceptance_failure_preserves_native_success(self):
        result = self.execute(
            TEST_ACCESS_ACCEPTANCE_CONFIRM="verify:scoped-access:ttl-and-denials",
            TEST_FIXTURE_ACCEPTANCE_FAIL="true",
        )
        self.assertNotEqual(result.returncode, 0)
        summary = self.summary()
        self.assertEqual(summary["result"], "failed")
        self.assertEqual(summary["phases"]["primary"]["exit_code"], 0)
        self.assertEqual(summary["phases"]["assertion"]["status"], "passed")
        run_dir = next((self.root / "results").iterdir())
        junit = ET.parse(run_dir / "junit.xml").getroot()
        case = junit.find(".//testcase[@name='scoped-client-refresh-and-boundary']")
        self.assertIsNotNone(case)
        self.assertIsNotNone(case.find("failure"))
        self.assertEqual(list((self.root / "private").glob("*/config")), [])

    def test_failed_native_backend_skips_scoped_acceptance(self):
        result = self.execute(
            TEST_ACCESS_ACCEPTANCE_CONFIRM="verify:scoped-access:ttl-and-denials",
            TEST_FIXTURE_CHAINSAW_FAIL="true",
        )
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertNotIn("acceptance ", (self.root / "trace").read_text())
        self.assertEqual((self.root / "backend-intent").read_text(), "")
        self.assertEqual(self.summary()["phases"]["primary"]["exit_code"], 7)

    def test_scoped_acceptance_rejects_wrong_intent_and_diagnostics_before_issuance(self):
        for arguments, intent in (
            (["smoke", "cluster", "flux-ready"], "yes"),
            (["diagnostics", "cluster"], "verify:scoped-access:ttl-and-denials"),
        ):
            with self.subTest(arguments=arguments):
                result = self.execute(arguments=arguments, TEST_ACCESS_ACCEPTANCE_CONFIRM=intent)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertFalse((self.root / "backend-config").exists())
                self.assertEqual(list((self.root / "private").glob("*/config")), [])

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
