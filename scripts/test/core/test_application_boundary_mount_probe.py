"""Independent local invariants for the unenrolled synthetic mount fixture."""

import errno
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.test.core.test_application_boundary import ROOT

PROBE = ROOT / "tests/fixtures/application-boundary/mount-probe.py"


class SyntheticMountProbeTests(unittest.TestCase):
    def run_probe(self, mode, root):
        return subprocess.run(
            [sys.executable, str(PROBE), mode, str(root)],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_exclusive_publication_survives_restart_and_rejects_duplicate_creation(self):
        with tempfile.TemporaryDirectory() as root:
            first = self.run_probe("publish", root)
            self.assertEqual(first.returncode, 0, first.stderr)
            bundle = Path(root) / "boundary-synthetic-bundle"
            original = bundle.read_bytes()
            second = self.run_probe("publish", root)
            self.assertEqual(second.returncode, 1)
            self.assertEqual(json.loads(second.stderr)["errno"], errno.EEXIST)
            self.assertEqual(bundle.read_bytes(), original)
            reader = self.run_probe("read", root)
            self.assertEqual(reader.returncode, 0, reader.stderr)
            self.assertEqual(json.loads(reader.stdout)["result"], "verified-synthetic-bundle")

    def test_reader_rejects_missing_and_corrupt_data(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(self.run_probe("read", root).returncode, 1)
            (Path(root) / "boundary-synthetic-bundle").write_bytes(b"corrupt")
            self.assertEqual(self.run_probe("read", root).returncode, 1)

    def test_writable_mount_does_not_pass_read_only_assertion_or_leave_probe_file(self):
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(self.run_probe("read-only", root).returncode, 1)
            self.assertEqual(list(Path(root).iterdir()), [])

    def test_permission_error_is_not_evidence_of_a_read_only_mount(self):
        spec = importlib.util.spec_from_file_location("mount_probe", PROBE)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with (
            patch.object(module.os, "open", side_effect=OSError(errno.EACCES, "denied")),
            self.assertRaises(OSError),
        ):
            module.assert_read_only(Path("/fixture"))
        with patch.object(module.os, "open", side_effect=OSError(errno.EROFS, "read-only")):
            module.assert_read_only(Path("/fixture"))


if __name__ == "__main__":
    unittest.main()
