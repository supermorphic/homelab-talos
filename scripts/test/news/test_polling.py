"""Disabled polling must return before touching runtime state or fetching feeds."""

import os
import subprocess
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[3] / "kubernetes/apps/news/freshrss/app/scripts"


class NewsPollingTests(unittest.TestCase):
    def execute(self, script, value):
        return subprocess.run(
            ["sh", str(SCRIPTS / script)],
            env=dict(os.environ, NEWS_POLLING_ENABLED=value),
            capture_output=True,
            timeout=5,
            check=False,
        )

    def test_disabled_manual_refresh_needs_no_runtime_or_credentials(self):
        result = self.execute("refresh.sh", "false")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, b"")

    def test_invalid_polling_intent_is_rejected_before_startup_or_refresh(self):
        for script in ("start.sh", "refresh.sh"):
            for value in ("", "False", "yes", "0"):
                with self.subTest(script=script, value=value):
                    result = self.execute(script, value)
                    self.assertEqual(result.returncode, 2, result.stderr)
                    self.assertIn(b"NEWS_POLLING_ENABLED", result.stderr)
