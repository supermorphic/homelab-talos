"""Foundation owns internal-audience DNS uniqueness across Kubernetes domains."""

import copy
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
DIAGNOSTIC = "Only the exact public-webhook DNSEndpoint may carry the internal DNS audience."


class InternalDNSEndpointTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "scripts").symlink_to(ROOT / "scripts", target_is_directory=True)
        self.endpoint_path = self.root / (
            "kubernetes/apps/networking/public-webhook-gateway/app/internal-dns.yaml"
        )
        self.endpoint = {
            "apiVersion": "externaldns.k8s.io/v1alpha1",
            "kind": "DNSEndpoint",
            "metadata": {
                "name": "fixture-internal-endpoint",
                "namespace": "networking-public",
                "annotations": {"external-dns.k8s.io/audience": "internal"},
            },
            "spec": {
                "endpoints": [
                    {
                        "dnsName": "fixture.example.invalid",
                        "recordType": "A",
                        "targets": ["192.0.2.39"],
                    }
                ]
            },
        }
        self.write_endpoint(self.endpoint_path, self.endpoint)
        # This unrelated foundation precondition uses the real approved public route.
        shutil.copyfile(
            ROOT / "kubernetes/apps/networking/public-webhook-gateway/route/httproute.yaml",
            self.root / "kubernetes/apps/approved-route.yaml",
        )

    def write_endpoint(self, path, endpoint):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.safe_dump(endpoint, sort_keys=False))

    def run_validator(self, script="internal-dns-endpoints.sh"):
        return subprocess.run(
            ["bash", str(ROOT / "scripts/validate" / script)],
            cwd=self.root,
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_rejected(self, script="internal-dns-endpoints.sh"):
        process = self.run_validator(script)
        self.assertEqual(process.returncode, 1, process.stderr)
        self.assertIn(DIAGNOSTIC, process.stderr)

    def test_valid_global_contract_allows_an_unrelated_external_endpoint(self):
        external = copy.deepcopy(self.endpoint)
        external["metadata"]["annotations"]["external-dns.k8s.io/audience"] = "external"
        self.write_endpoint(self.root / "kubernetes/apps/media/external.yaml", external)
        process = self.run_validator()
        self.assertEqual(process.returncode, 0, process.stderr)

    def test_absent_endpoint_is_rejected(self):
        self.endpoint_path.unlink()
        self.assert_rejected()

    def test_changed_audience_is_rejected(self):
        self.endpoint["metadata"]["annotations"]["external-dns.k8s.io/audience"] = "external"
        self.write_endpoint(self.endpoint_path, self.endpoint)
        self.assert_rejected()

    def test_changed_source_location_is_rejected(self):
        self.endpoint_path.unlink()
        self.write_endpoint(self.root / "kubernetes/apps/media/endpoint.yaml", self.endpoint)
        self.assert_rejected()

    def test_duplicate_endpoint_outside_apps_is_rejected(self):
        self.write_endpoint(self.root / "kubernetes/fixture/endpoint.yaml", self.endpoint)
        self.assert_rejected()

    def test_foundation_rejects_absent_changed_and_duplicate_contracts(self):
        for case in ("absent", "changed", "duplicate"):
            with self.subTest(case=case):
                self.write_endpoint(self.endpoint_path, self.endpoint)
                if case == "absent":
                    self.endpoint_path.unlink()
                elif case == "changed":
                    changed = copy.deepcopy(self.endpoint)
                    changed["kind"] = "ConfigMap"
                    self.write_endpoint(self.endpoint_path, changed)
                else:
                    self.write_endpoint(
                        self.root / "kubernetes/apps/media/extra.yaml", self.endpoint
                    )
                self.assert_rejected("foundation.sh")


if __name__ == "__main__":
    unittest.main()
