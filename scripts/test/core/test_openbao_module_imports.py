"""Credential entry points must start without relying on test import order."""

import subprocess
import sys
import unittest
from pathlib import Path


class OpenBaoModuleImports(unittest.TestCase):
    def test_credentials_and_issuance_start_in_either_order(self):
        for first, second in (("credentials", "issuance"), ("issuance", "credentials")):
            with self.subTest(first=first):
                result = subprocess.run(
                    [sys.executable, "-c", f"from scripts.openbao import {first}, {second}"],
                    cwd=Path(__file__).resolve().parents[3],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
