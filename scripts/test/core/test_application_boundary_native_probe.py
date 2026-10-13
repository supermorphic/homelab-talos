"""Independent storage ownership and network failure oracles for the fixed probe."""

import importlib.util
import socket
import tempfile
import unittest
from pathlib import Path

from scripts.test.core.test_application_boundary import PLATFORM


class NativeProbeTests(unittest.TestCase):
    def setUp(self):
        path = PLATFORM / "native-probe.py"
        self.assertTrue(path.is_file(), "the fixed native probe is missing")
        spec = importlib.util.spec_from_file_location("native_probe", path)
        self.probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.probe)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.roots = {
            name: Path(self.temp.name) / name for name in ["releases", "requests", "artifacts"]
        }
        for root in self.roots.values():
            root.mkdir()
        self.run = "0123456789abcdef0123456789abcdef"

    def test_seed_persists_synthetic_payload_and_rejects_reuse(self):
        self.probe.seed(self.roots, self.run)
        bundle = self.roots["releases"] / "published" / self.run / "boundary-synthetic-bundle"
        self.assertEqual(bundle.read_bytes(), b"homelab-application-boundary/synthetic/v1\n")
        with self.assertRaises(FileExistsError):
            self.probe.seed(self.roots, self.run)
        self.assertEqual(bundle.read_bytes(), b"homelab-application-boundary/synthetic/v1\n")

    def test_cleanup_does_not_remove_a_directory_with_changed_ownership(self):
        self.probe.seed(self.roots, self.run)
        directory = self.roots["releases"] / "published" / self.run
        (directory / "owner").write_text("different-run")
        with self.assertRaises(ValueError):
            self.probe.cleanup(self.roots, self.run)
        self.assertTrue((directory / "boundary-synthetic-bundle").is_file())

    def test_cleanup_removes_only_the_owned_run_and_rejects_path_escape(self):
        other = self.roots["artifacts"] / "unrelated"
        other.mkdir()
        (other / "keep").write_text("untouched")
        self.probe.seed(self.roots, self.run)
        self.probe.cleanup(self.roots, self.run)
        self.assertEqual((other / "keep").read_text(), "untouched")
        self.assertFalse((self.roots["requests"] / "requests" / self.run).exists())
        with self.assertRaises(ValueError):
            self.probe.cleanup(self.roots, "../unrelated")

    def test_reachable_network_does_not_count_as_policy_denial(self):
        with socket.socket() as endpoint:
            endpoint.bind(("127.0.0.1", 0))
            endpoint.listen()
            port = endpoint.getsockname()[1]
            self.probe.tcp([("127.0.0.1", port)], allowed=True)
            with self.assertRaises(ValueError):
                self.probe.tcp([("127.0.0.1", port)], allowed=False)

    def test_network_phase_attempts_only_its_selected_target(self):
        self.assertTrue(hasattr(self.probe, "network_probe"))
        calls = []
        self.probe.tcp = lambda targets, allowed: calls.append(("tcp", targets, allowed))
        self.probe.dns = lambda address, allowed: calls.append(("dns", address, allowed))
        addresses = ["192.0.2.1", "192.0.2.2", "192.0.2.3"]
        expected = {
            "api": ("tcp", [(addresses[0], 443)], False),
            "database": ("tcp", [(addresses[1], 5432)], False),
            "dns-tcp": ("tcp", [(addresses[2], 53)], False),
            "dns-udp": ("dns", addresses[2], False),
        }
        for stage in ["write", "read"]:
            for target, wanted in expected.items():
                calls.clear()
                self.probe.network_probe("network-" + stage + "-" + target, addresses)
                self.assertEqual(calls, [wanted])
        with self.assertRaises(ValueError):
            self.probe.network_probe("network-write-unknown", addresses)


if __name__ == "__main__":
    unittest.main()
