"""Actual standalone coordination keeps suite, observer and Lease authority apart."""

import json
import subprocess
import unittest
from pathlib import Path

from scripts.test.core import test_chainsaw_routing as routing_fixtures

ROOT = Path(__file__).resolve().parents[3]


class CoordinationRoutingTests(unittest.TestCase):
    def setUp(self):
        routing_fixtures.ChainsawRoutingTests.setUp(self)
        self.lease = self.root / "lease.json"
        self.lease.write_text(
            json.dumps(
                {
                    "apiVersion": "coordination.k8s.io/v1",
                    "kind": "Lease",
                    "metadata": {
                        "name": "homelab-test-run-lock",
                        "namespace": "flux-system",
                        "resourceVersion": "1",
                    },
                    "spec": {"holderIdentity": "", "leaseDurationSeconds": 90},
                }
            )
        )
        nodes = self.root / "nodes.json"
        nodes.write_text(
            json.dumps(
                {
                    "items": [
                        {
                            "metadata": {"name": "synthetic-node", "annotations": {}},
                            "spec": {"unschedulable": False},
                            "status": {"conditions": [{"type": "Ready", "status": "True"}]},
                        }
                    ]
                }
            )
        )
        self.environment.update(
            {
                "CILIUM_CONNECTIVITY_CONFIRM": "test:cilium-connectivity",
                "CAMPAIGN_TEST_LEASE_STATE": str(self.lease),
                "CAMPAIGN_TEST_LEASE_CALLS": str(self.root / "lease-calls"),
                "TEST_LEASE_KUBECTL": str(ROOT / "tests/fixtures/campaign/fake-lease-kubectl.sh"),
                "DISRUPTION_KUBECTL": str(
                    ROOT / "tests/fixtures/disruption-admission/fake-kubectl.sh"
                ),
                "DISRUPTION_TEST_NODES": str(nodes),
                "DISRUPTION_TEST_CALL_LOG": str(self.root / "node-calls"),
                # Authority routing is independent of timer behavior; the existing
                # Lease tests exercise renewal. Do not leave a sleep holding test pipes.
                "TEST_LEASE_SLEEP": "false",
                "TEST_ACCESS_PURPOSE_CONFIG": "/synthetic/ambient/purpose",
                "observer_kubeconfig": "/synthetic/ambient/observer",
                "coordinator_kubeconfig": "/synthetic/ambient/coordinator",
            }
        )
        with (self.root / "bin/chainsaw").open("a") as stream:
            stream.write(
                '\n[[ -z "${coordinator_kubeconfig+x}" && -z "${observer_kubeconfig+x}" ]]\n'
                'printf \'{"status":"passed"}\\n\' > "$HOMELAB_TEST_RUN_DIR/recovery.json"\n'
            )

    def execute(self):
        return subprocess.run(
            [
                "scripts/test/run-catalog-suite.sh",
                "test.cilium-connectivity",
                "--",
                "bash",
                "-c",
                (
                    'printf "%s\\n" "$TEST_KUBECONFIG" > "$TEST_FIXTURE_ACCESS_ROOT/backend-config"; '
                    '[[ "$KUBECONFIG" == "$TEST_KUBECONFIG" && -z "${TEST_ACCESS_PURPOSE_CONFIG+x}" && '
                    '-z "${observer_kubeconfig+x}" && -z "${coordinator_kubeconfig+x}" ]]'
                ),
            ],
            cwd=ROOT,
            env=self.environment,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )

    def test_standalone_suite_uses_separate_observer_and_coordinator(self):
        result = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        suite_path = (self.root / "backend-config").read_text().strip()
        writes = [
            line
            for line in (self.root / "lease-calls").read_text().splitlines()
            if " replace " in line
        ]
        self.assertGreaterEqual(len(writes), 2)
        for line in writes:
            self.assertIn("-campaign-coordinator/config", line)
            self.assertNotIn(suite_path, line)
        for line in (self.root / "node-calls").read_text().splitlines():
            self.assertIn("-campaign-observer/config", line)
            self.assertNotIn(suite_path, line)
        self.assertFalse(json.loads(self.lease.read_text())["spec"].get("holderIdentity"))
        self.assertEqual(list((self.root / "private").glob("*/config")), [])

    def test_missing_git_lease_is_never_created_and_backend_does_not_run(self):
        self.lease.unlink()
        result = self.execute()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.lease.exists())
        self.assertFalse((self.root / "backend-config").exists())
        self.assertNotIn(" create ", (self.root / "lease-calls").read_text())
        self.assertEqual(list((self.root / "private").glob("*/config")), [])

    def test_physical_boundary_keeps_explicit_operator_input_without_issuance(self):
        operator = self.root / "operator-config"
        operator.touch()
        result = subprocess.run(
            [
                "scripts/test/run-catalog-suite.sh",
                "test.resilience.node-abrupt-loss",
                "--",
                "true",
            ],
            cwd=ROOT,
            env={
                **self.environment,
                "NODE_OPERATOR_KUBECONFIG": str(operator),
                "CLUSTER_CHAOS_CONFIRM": "chaos:node-abrupt-loss",
            },
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(operator.exists())
        trace = (self.root / "trace").read_text()
        self.assertNotIn("prepare ", trace)
        self.assertNotIn("purpose ", trace)
        self.assertNotIn("remove ", trace)
        writes = [
            line
            for line in (self.root / "lease-calls").read_text().splitlines()
            if " replace " in line
        ]
        self.assertGreaterEqual(len(writes), 2)
        for line in writes:
            self.assertIn(str(operator), line)

    def test_chainsaw_mutator_separates_node_reads_and_lease_writes(self):
        result = self.run_chainsaw()
        self.assertEqual(result.returncode, 0, result.stderr)
        writes = [
            line
            for line in (self.root / "lease-calls").read_text().splitlines()
            if " replace " in line
        ]
        self.assertGreaterEqual(len(writes), 2)
        for line in writes:
            self.assertIn("-campaign-coordinator/config", line)
        nodes = (self.root / "node-calls").read_text().splitlines()
        self.assertGreater(len(nodes), 0)
        for line in nodes:
            self.assertIn("-campaign-observer/config", line)
        self.assertEqual(list((self.root / "private").glob("*/config")), [])

    def run_chainsaw(self, **environment):
        return subprocess.run(
            ["scripts/test/run-chainsaw.sh", "resilience", "qbittorrent-vpn-disconnect"],
            cwd=ROOT,
            env={
                **self.environment,
                "CLUSTER_CHAOS_CONFIRM": "chaos:qbittorrent-vpn-disconnect",
                **environment,
            },
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )

    def test_chainsaw_setup_failure_releases_with_coordinator_and_removes_configs(self):
        result = self.run_chainsaw(DISRUPTION_TEST_API_FAILURE="true")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "backend-config").exists())
        writes = [
            line
            for line in (self.root / "lease-calls").read_text().splitlines()
            if " replace " in line
        ]
        self.assertGreaterEqual(len(writes), 2)
        for line in writes:
            self.assertIn("-campaign-coordinator/config", line)
        self.assertEqual(list((self.root / "private").glob("*/config")), [])

    def test_chainsaw_failed_lease_release_preserves_primary_assertion(self):
        lease_driver = self.root / "fail-release"
        lease_driver.write_text("""#!/usr/bin/env bash
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
        lease_driver.chmod(0o755)
        result = self.run_chainsaw(
            TEST_LEASE_KUBECTL=str(lease_driver),
            TEST_FIXTURE_LEASE_DELEGATE=self.environment["TEST_LEASE_KUBECTL"],
        )
        self.assertNotEqual(result.returncode, 0)
        paths = list((self.root / "results").glob("*/summary.json"))
        self.assertEqual(len(paths), 1)
        summary = json.loads(paths[0].read_text())
        self.assertEqual(summary["result"], "broken")
        self.assertEqual(summary["phases"]["assertion"]["status"], "passed")
        self.assertEqual(summary["phases"]["cleanup"]["status"], "failed")


if __name__ == "__main__":
    unittest.main()
