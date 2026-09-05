"""Public-route uniqueness must be enforced by always-run foundation validation."""

import copy
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class PublicWebhookRouteTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
        self.apps = self.root / "kubernetes/apps"
        self.apps.mkdir(parents=True)
        self.route = {
            "apiVersion": "gateway.networking.k8s.io/v1",
            "kind": "HTTPRoute",
            "metadata": {"name": "n8n-platform-canary", "namespace": "networking-public"},
            "spec": {
                "parentRefs": [
                    {
                        "group": "gateway.networking.k8s.io",
                        "kind": "Gateway",
                        "name": "public-webhooks",
                        "namespace": "networking-public",
                        "sectionName": "https",
                    }
                ],
                "rules": [
                    {
                        "backendRefs": [
                            {
                                "group": "",
                                "kind": "Service",
                                "name": "n8n",
                                "namespace": "automation",
                                "port": 5678,
                            }
                        ],
                        "matches": [
                            {"path": {"type": "Exact", "value": "/webhook/platform-canary"}}
                        ],
                    }
                ],
            },
        }
        self.write("approved.json", self.route)

    def write(self, name, payload):
        (self.apps / name).write_text(json.dumps(payload))

    def run_validator(self, script="public-webhook-routes.sh"):
        return subprocess.run(
            ["bash", str(ROOT / "scripts/validate" / script)],
            cwd=self.root,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_exact_route_and_unrelated_internal_route_pass(self):
        internal = copy.deepcopy(self.route)
        internal["spec"]["parentRefs"][0]["name"] = "internal"
        self.write("internal.yaml", internal)
        process = self.run_validator()
        self.assertEqual(process.returncode, 0, process.stderr)

    def test_foundation_rejects_extra_public_route_in_another_domain(self):
        extra = copy.deepcopy(self.route)
        extra["metadata"]["name"] = "unexpected"
        self.write("extra.yml", extra)
        process = self.run_validator("foundation.sh")
        self.assertEqual(process.returncode, 1, process.stderr)
        self.assertIn("exactly one complete Platform Canary HTTPRoute contract", process.stderr)

    def test_missing_route_and_changed_contract_fail(self):
        (self.apps / "approved.json").unlink()
        process = self.run_validator()
        self.assertEqual(process.returncode, 1, process.stderr)
        changed = copy.deepcopy(self.route)
        changed["spec"]["rules"][0]["matches"][0]["path"]["type"] = "PathPrefix"
        self.write("changed.yaml", changed)
        process = self.run_validator()
        self.assertEqual(process.returncode, 1, process.stderr)
        self.assertIn("exactly one complete Platform Canary HTTPRoute contract", process.stderr)


if __name__ == "__main__":
    unittest.main()
