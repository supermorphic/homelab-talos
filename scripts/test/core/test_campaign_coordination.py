"""Campaign failures retain child evidence and close purpose-specific authority."""

import json
import shutil
import subprocess
import time
import unittest

import yaml

from scripts.test.core import test_coordination_routing as fixtures

ROOT = fixtures.ROOT


class CampaignCoordinationTests(unittest.TestCase):
    def setUp(self):
        fixtures.CoordinationRoutingTests.setUp(self)
        self.environment.pop("TEST_FIXTURE_ACCESS_FINALIZATION_ROOT", None)
        catalog = yaml.safe_load((ROOT / "tests/catalog.yaml").read_text())
        for entry in catalog["suites"]:
            if entry["metadata"]["id"] == "test.cilium-connectivity":
                entry["runner"]["command"] = "mise exec -- just fixture mutating-pass"
            elif entry["metadata"]["id"] == "verification.metrics-server":
                entry["runner"]["command"] = "mise exec -- just fixture pass"
        catalog["campaigns"]["scoped-verification"]["members"] = [
            "test.cilium-connectivity",
            "verification.metrics-server",
        ]
        catalog_path = self.root / "catalog.yaml"
        catalog_path.write_text(yaml.safe_dump(catalog))
        shutil.copy2(ROOT / "tests/fixtures/campaign/fake-mise.sh", self.root / "bin/mise")
        sha = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
        self.environment.update(
            {
                "TEST_CATALOG_PATH": str(catalog_path),
                "TEST_CAMPAIGNS_ROOT": str(self.root / "campaigns"),
                "TEST_CAMPAIGN_TEST_MODE": "true",
                "TEST_RECORD_LINKED_WORKTREE": "true",
                "TEST_CAMPAIGN_SOURCE_CHECK_BIN": str(
                    ROOT / "tests/fixtures/campaign/source-check.sh"
                ),
                "TEST_CAMPAIGN_PUBLISH_BIN": str(
                    ROOT / "tests/fixtures/campaign/fake-publisher.sh"
                ),
                "TEST_SCOPED_PREFLIGHT_BIN": str(
                    ROOT / "tests/fixtures/campaign/pass-scoped-preflight.sh"
                ),
                "TEST_CAMPAIGN_PUBLISH_ATTEMPTS": "1",
                "CAMPAIGN_TEST_REPO_ROOT": str(ROOT),
                "CAMPAIGN_TEST_SOURCE_SHA": sha,
                "CAMPAIGN_TEST_SOURCE_STATE": str(self.root / "source-state"),
                "CAMPAIGN_TEST_COMMAND_CALLS": str(self.root / "commands"),
                "CAMPAIGN_TEST_PUBLISH_CALLS": str(self.root / "publishes"),
            }
        )

    def execute(self, selection="test.cilium-connectivity", **environment):
        return subprocess.run(
            ["scripts/test/run-campaign.sh", "record", selection],
            cwd=ROOT,
            env={**self.environment, **environment},
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    def manifest(self):
        paths = list((self.root / "campaigns").glob("*/campaign.json"))
        self.assertEqual(len(paths), 1)
        return json.loads(paths[0].read_text())

    def test_missing_lease_records_broken_without_running_or_publishing(self):
        self.lease.unlink()
        result = self.execute()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.manifest()["status"], "broken")
        self.assertFalse((self.root / "commands").exists())
        self.assertFalse((self.root / "publishes").exists())
        self.assertEqual(list((self.root / "private").glob("*/config")), [])
        self.assertNotIn(" create ", (self.root / "lease-calls").read_text())

    def test_suite_without_talos_prerequisite_ignores_ambient_talos_access(self):
        result = self.execute(
            "verification.metrics-server", TALOSCONFIG="/synthetic/ambient/talos-operator"
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.manifest()["runs"][0]["result"], "passed")

    def test_suite_with_reader_prerequisite_ignores_ambient_operator_access(self):
        result = self.execute(TALOSCONFIG="/synthetic/ambient/talos-operator")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.manifest()["runs"][0]["result"], "passed")

    def test_failed_release_reports_cleanup_failure_and_retains_passed_child(self):
        driver = self.root / "fail-release"
        driver.write_text("""#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  if [[ "$argument" == replace ]]; then
    input="$(cat)"
    [[ -n "$(yq -r '.spec.holderIdentity // ""' - <<<"$input")" ]] || exit 1
    printf '%s\\n' "$input" | "$TEST_FIXTURE_LEASE_DELEGATE" "$@"
    exit "$?"
  fi
done
exec "$TEST_FIXTURE_LEASE_DELEGATE" "$@"
""")
        driver.chmod(0o755)
        result = self.execute(
            TEST_LEASE_KUBECTL=str(driver),
            TEST_FIXTURE_LEASE_DELEGATE=self.environment["TEST_LEASE_KUBECTL"],
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = self.manifest()
        self.assertEqual(manifest["status"], "broken")
        self.assertEqual(manifest["cleanup_status"], "failed")
        self.assertEqual(manifest["runs"][0]["result"], "passed")
        self.assertEqual(manifest["runs"][0]["publish_status"], "published")
        self.assertEqual(list((self.root / "private").glob("*/config")), [])

    def test_failed_observer_config_removal_is_reported_separately(self):
        uv_driver = self.root / "bin/uv"
        uv_driver.write_text("""#!/usr/bin/env bash
set -euo pipefail
arguments=("$@")
while [[ "$#" -gt 0 && "$1" != scripts.test.access ]]; do shift; done
if [[ "$#" -ge 3 && "$2" == remove && "$3" == *-campaign-access-*-campaign-observer/config ]]; then
  exit 7
fi
exec "$TEST_FIXTURE_UV_DELEGATE" "${arguments[@]}"
""")
        result = self.execute(
            TEST_FIXTURE_UV_DELEGATE=str(ROOT / "tests/fixtures/test-access/fake-uv.sh")
        )
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        manifest = self.manifest()
        self.assertEqual(manifest["status"], "broken")
        self.assertEqual(manifest["cleanup_status"], "failed")
        self.assertEqual(manifest["runs"][0]["result"], "passed")
        self.assertEqual(manifest["runs"][0]["publish_status"], "published")
        remaining = list((self.root / "private").glob("*/config"))
        self.assertEqual(len(remaining), 1)
        self.assertTrue(remaining[0].parent.name.endswith("-campaign-observer"))

    def test_lost_holder_stops_next_suite_and_does_not_release_another_campaign(self):
        publisher = self.root / "steal-after-publish"
        publisher.write_text("""#!/usr/bin/env bash
set -euo pipefail
"$CAMPAIGN_TEST_REPO_ROOT/tests/fixtures/campaign/fake-publisher.sh" "$@"
yq -i '.spec.holderIdentity = "campaign:other"' "$CAMPAIGN_TEST_LEASE_STATE"
""")
        publisher.chmod(0o755)
        result = self.execute(
            selection="scoped-verification", TEST_CAMPAIGN_PUBLISH_BIN=str(publisher)
        )
        self.assertNotEqual(result.returncode, 0)
        manifest = self.manifest()
        self.assertEqual(manifest["status"], "broken")
        self.assertEqual(len(manifest["runs"]), 1)
        self.assertEqual((self.root / "commands").read_text().strip(), "mutating-pass")
        self.assertEqual(
            json.loads(self.lease.read_text())["spec"]["holderIdentity"], "campaign:other"
        )
        writes = [
            line
            for line in (self.root / "lease-calls").read_text().splitlines()
            if " replace " in line
        ]
        self.assertEqual(len(writes), 1)
        self.assertIn("-campaign-coordinator/config", writes[0])
        self.assertEqual(list((self.root / "private").glob("*/config")), [])

    def test_interrupt_finalizes_campaign_and_removes_owned_authority(self):
        publisher = self.root / "interrupt-after-publish"
        publisher.write_text("""#!/usr/bin/env bash
set -euo pipefail
"$CAMPAIGN_TEST_REPO_ROOT/tests/fixtures/campaign/fake-publisher.sh" "$@"
kill -TERM "$PPID"
""")
        publisher.chmod(0o755)
        result = self.execute(TEST_CAMPAIGN_PUBLISH_BIN=str(publisher))
        self.assertEqual(result.returncode, 143, result.stdout + result.stderr)
        manifest = self.manifest()
        self.assertEqual(manifest["status"], "broken")
        self.assertEqual(manifest["stop_reason"], "interrupted-TERM")
        self.assertEqual(manifest["runs"][0]["result"], "passed")
        self.assertFalse(json.loads(self.lease.read_text())["spec"]["holderIdentity"])
        self.assertEqual(list((self.root / "private").glob("*/config")), [])

    def test_parallel_campaign_cannot_run_while_another_holds_lease(self):
        mise_driver = self.root / "bin/mise"
        mise_driver.write_text("""#!/usr/bin/env bash
set -euo pipefail
touch "$TEST_FIXTURE_ACCESS_ROOT/held"
while [[ ! -e "$TEST_FIXTURE_ACCESS_ROOT/release" ]]; do sleep 0.05; done
exec "$CAMPAIGN_TEST_REPO_ROOT/tests/fixtures/campaign/fake-mise.sh" "$@"
""")
        contender = self.root / "contender"
        (contender / "bin").mkdir(parents=True)
        shutil.copy2(ROOT / "tests/fixtures/campaign/fake-mise.sh", contender / "bin/mise")
        contender_environment = {
            "PATH": f"{contender / 'bin'}:{self.environment['PATH']}",
            "TEST_FIXTURE_ACCESS_ROOT": str(contender),
            "TEST_FIXTURE_ACCESS_TRACE": str(contender / "trace"),
            "TEST_RESULTS_ROOT": str(contender / "results"),
            "TEST_CAMPAIGNS_ROOT": str(contender / "campaigns"),
            "CAMPAIGN_TEST_COMMAND_CALLS": str(contender / "commands"),
            "CAMPAIGN_TEST_PUBLISH_CALLS": str(contender / "publishes"),
            "CAMPAIGN_TEST_SOURCE_STATE": str(contender / "source-state"),
        }
        with (self.root / "first.log").open("w") as output:
            first = subprocess.Popen(
                ["scripts/test/run-campaign.sh", "record", "test.cilium-connectivity"],
                cwd=ROOT,
                env=self.environment,
                stdout=output,
                stderr=subprocess.STDOUT,
            )
            try:
                deadline = time.monotonic() + 10
                while not (self.root / "held").exists() and time.monotonic() < deadline:
                    self.assertIsNone(first.poll())
                    time.sleep(0.05)
                self.assertTrue((self.root / "held").exists())
                result = self.execute(**contender_environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((contender / "commands").exists())
                self.assertFalse((contender / "publishes").exists())
                self.assertEqual(list((contender / "private").glob("*/config")), [])
            finally:
                (self.root / "release").touch()
                first.wait(timeout=30)
        self.assertEqual(first.returncode, 0, (self.root / "first.log").read_text())
        self.assertFalse(json.loads(self.lease.read_text())["spec"]["holderIdentity"])
        self.assertEqual(list((self.root / "private").glob("*/config")), [])

    def test_rejected_coordinator_access_stops_new_actions_without_fallback(self):
        publisher = self.root / "reject-after-publish"
        publisher.write_text("""#!/usr/bin/env bash
set -euo pipefail
"$CAMPAIGN_TEST_REPO_ROOT/tests/fixtures/campaign/fake-publisher.sh" "$@"
touch "$TEST_FIXTURE_ACCESS_ROOT/reject-coordinator"
""")
        publisher.chmod(0o755)
        lease_driver = self.root / "lease-driver"
        lease_driver.write_text("""#!/usr/bin/env bash
set -euo pipefail
if [[ -e "$TEST_FIXTURE_ACCESS_ROOT/reject-coordinator" ]]; then
  [[ "$2" == *-campaign-coordinator/config ]]
  echo 'Synthetic coordinator access rejected.' >&2
  exit 1
fi
exec "$TEST_FIXTURE_LEASE_DELEGATE" "$@"
""")
        lease_driver.chmod(0o755)
        result = self.execute(
            selection="scoped-verification",
            TEST_CAMPAIGN_PUBLISH_BIN=str(publisher),
            TEST_LEASE_KUBECTL=str(lease_driver),
            TEST_FIXTURE_LEASE_DELEGATE=self.environment["TEST_LEASE_KUBECTL"],
        )
        self.assertNotEqual(result.returncode, 0)
        manifest = self.manifest()
        self.assertEqual(manifest["status"], "broken")
        self.assertEqual(len(manifest["runs"]), 1)
        self.assertEqual(manifest["runs"][0]["result"], "passed")
        self.assertEqual((self.root / "commands").read_text().strip(), "mutating-pass")
        self.assertEqual(len((self.root / "publishes").read_text().splitlines()), 1)
        self.assertEqual(list((self.root / "private").glob("*/config")), [])


if __name__ == "__main__":
    unittest.main()
