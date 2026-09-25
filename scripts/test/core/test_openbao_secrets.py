"""Synthetic encryption only; no operator identity is loaded."""

import errno
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.openbao import secrets
from scripts.openbao.configuration import SafeError


class SecretTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name).resolve()
        key = subprocess.run(["age-keygen"], capture_output=True, check=True).stdout
        self.identity = key
        self.recipient = (
            subprocess.run(["age-keygen", "-y"], input=key, capture_output=True, check=True)
            .stdout.decode()
            .strip()
        )

    def test_ciphertext_is_exclusive_private_and_plaintext_never_retained(self):
        result = secrets.write_recovery(self.directory, self.recipient, b"synthetic-recovery")
        self.assertTrue(result.read_bytes().startswith(b"age-encryption.org/v1"))
        self.assertNotIn(b"synthetic-recovery", result.read_bytes())
        decrypted = subprocess.run(
            ["age", "--decrypt", "-i", "/dev/stdin", str(result)],
            input=self.identity,
            capture_output=True,
            check=True,
        ).stdout
        self.assertEqual(decrypted, b"synthetic-recovery")
        self.assertEqual(result.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(SafeError):
            secrets.write_recovery(self.directory, self.recipient, b"synthetic-other")
        self.assertEqual(len(list(self.directory.iterdir())), 1)

    def test_symlink_permissions_repository_and_invalid_recipient_refused(self):
        link = self.directory / "link"
        link.symlink_to(self.directory, target_is_directory=True)
        for target in (link, Path.cwd(), self.directory / ".." / self.directory.name):
            with self.subTest(target=target), self.assertRaises(SafeError):
                secrets.write_recovery(target, self.recipient, b"synthetic")
        self.directory.chmod(0o755)
        with self.assertRaises(SafeError):
            secrets.write_recovery(self.directory, self.recipient, b"synthetic")
        self.directory.chmod(0o700)
        with self.assertRaises(SafeError):
            secrets.write_recovery(self.directory, "invalid", b"synthetic")

    def test_disk_failure_leaves_no_committed_bundle(self):
        with patch(
            "scripts.openbao.secrets.os.fsync", side_effect=OSError(errno.ENOSPC, "synthetic")
        ), self.assertRaises(SafeError):
            secrets.write_recovery(self.directory, self.recipient, b"synthetic")
        self.assertEqual(list(self.directory.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
