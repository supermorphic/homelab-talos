#!/usr/bin/env python3
"""Exercise canonical secret scanning with real Git refs and pinned tools."""

from __future__ import annotations

import os
import random
import shutil
import string
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]


class RepositorySecretScanTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="repository-secret-scan-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        # Inherit mise's pinned PATH, but never adopt a caller's Git worktree/index.
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)
        self.git("init", "--quiet", "--initial-branch=candidate")
        self.git("config", "user.name", "Secret Scan Tests")
        self.git("config", "user.email", "tests@example.invalid")
        self.git("config", "core.hooksPath", os.devnull)
        (self.root / ".just").mkdir()
        shutil.copyfile(REPO_ROOT / ".just/repository.just", self.root / ".just/repository.just")
        (self.root / ".justfile").write_text('mod repo ".just/repository.just"\n')
        (self.root / "tracked.txt").write_text("clean fixture\n")
        self.commit("clean candidate")
        # Build a deliberately synthetic detector fixture only in the temporary repo.
        suffix = "".join(random.Random(0).choices(string.ascii_letters + string.digits, k=36))
        self.secret = "token = " + "gh" + "p_" + suffix + "\n"
        baseline = self.scan()
        self.assertEqual(baseline.returncode, 0, baseline.stdout)

    def git(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *args], cwd=self.root, env=self.env, text=True, capture_output=True, check=True
        )

    def commit(self, message: str) -> None:
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", message)

    def scan(self) -> subprocess.CompletedProcess[str]:
        # The parent workflow enters through mise exec; this is the actual recipe,
        # copied unchanged so its working directory is the isolated fixture repo.
        return subprocess.run(
            ["just", "repo", "secret-scan"],
            cwd=self.root,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
            check=False,
        )

    def assert_finding(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("leaks found: 1", result.stdout)

    def test_unrelated_ref_does_not_reject_clean_candidate(self) -> None:
        self.git("switch", "--quiet", "-c", "unrelated")
        (self.root / "unrelated.txt").write_text(self.secret)
        self.commit("synthetic finding on unrelated branch")
        # Prove the scanner detects this fixture before isolating it from HEAD.
        self.assert_finding(self.scan())
        self.git("switch", "--quiet", "candidate")
        self.assertFalse((self.root / "unrelated.txt").exists())
        self.assertEqual(self.git("status", "--porcelain").stdout, "")

        result = self.scan()

        self.assertEqual(result.returncode, 0, result.stdout)

    def test_candidate_ancestry_finding_fails_after_file_is_deleted(self) -> None:
        (self.root / "historical.txt").write_text(self.secret)
        self.commit("synthetic finding in candidate history")
        (self.root / "historical.txt").unlink()
        self.commit("delete historical fixture")

        self.assert_finding(self.scan())

    def test_tracked_working_tree_finding_fails(self) -> None:
        (self.root / "tracked.txt").write_text(self.secret)

        self.assert_finding(self.scan())

    def test_untracked_file_finding_fails(self) -> None:
        (self.root / "untracked.txt").write_text(self.secret)

        self.assert_finding(self.scan())


if __name__ == "__main__":
    unittest.main()
