#!/usr/bin/env python3
"""Behavior tests for the repository-wide Bash and ShellCheck artifact."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path as NativePath
from unittest import mock

Path = type(NativePath())
MODULE_PATH = Path(__file__).with_name("repository_shell_validation.py")
REPO_ROOT = MODULE_PATH.parents[2]
SPEC = importlib.util.spec_from_file_location("repository_shell_validation", MODULE_PATH)
assert SPEC and SPEC.loader
repository_shell_validation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(repository_shell_validation)

REPOSITORY_DIRS = (
    "scripts/hooks",
    "scripts/repository",
    "scripts/secrets",
    "scripts/validate",
    "scripts/verify",
    "scripts/test",
    "tests/probes",
)


def git_shell_oracle(root: Path) -> list[Path]:
    completed = subprocess.run(
        ["git", "ls-files", "-co", "--exclude-standard", "-z", "--", *REPOSITORY_DIRS],
        cwd=root,
        check=True,
        capture_output=True,
    )
    return sorted(
        Path(os.fsdecode(item))
        for item in completed.stdout.split(b"\0")
        if item
        and item.endswith(b".sh")
        and (root / os.fsdecode(item)).is_file()
        and not (root / os.fsdecode(item)).is_symlink()
    )


class RepositoryShellValidationTests(unittest.TestCase):
    def make_repository(self, root: Path) -> None:
        subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
        subprocess.run(
            ["git", "config", "user.email", "tests@example.invalid"], cwd=root, check=True
        )
        subprocess.run(
            ["git", "config", "user.name", "Repository Shell Tests"], cwd=root, check=True
        )
        (root / "scripts/test").mkdir(parents=True)
        (root / "scripts/test/ok.sh").write_text("#!/usr/bin/env bash\necho ok\n")
        subprocess.run(["git", "add", "scripts/test/ok.sh"], cwd=root, check=True)
        subprocess.run(["git", "commit", "--quiet", "-m", "fixture"], cwd=root, check=True)

    def fake_tools(self, root: Path, *, bash_failure: bool = False) -> tuple[Path, Path]:
        tools = root / "tools"
        tools.mkdir()
        shellcheck_sentinel = root / "shellcheck-called"
        bash_body = """#!/bin/sh
if [ \"$1\" = \"--version\" ]; then
  printf '%s\\n' 'GNU bash fake 1.0'
  exit 0
fi
if [ \"$2\" = \"scripts/test/bad.sh\" ]; then
  printf '%s' 'bad.sh: line 2: syntax error' >&2
  exit 2
fi
exit 0
"""
        if not bash_failure:
            bash_body = bash_body.replace(
                'if [ "$2" = "scripts/test/bad.sh" ]; then', "if false; then"
            )
        (tools / "bash").write_text(bash_body)
        shellcheck_body = "\n".join(
            [
                "#!/bin/sh",
                'if [ "$1" = "--version" ]; then',
                "  printf '%s\\n' 'ShellCheck fake 1.0'",
                "  exit 0",
                "fi",
                f"printf '%s\\n' \"$*\" >> {shellcheck_sentinel}",
                'printf \'%s\\n\' \'[{"file":"scripts/test/ok.sh","line":2,"column":1,"level":"warning","code":2086,"message":"quote this"}]\'',
                "exit 1",
                "",
            ]
        )
        (tools / "shellcheck").write_text(shellcheck_body)
        (tools / "bash").chmod(0o755)
        (tools / "shellcheck").chmod(0o755)
        return tools, shellcheck_sentinel

    def test_discovers_exact_current_git_shell_set_and_excludes_ignored_shell_files(self) -> None:
        expected = git_shell_oracle(REPO_ROOT)
        self.assertEqual(repository_shell_validation.discover_shell_sources(REPO_ROOT), expected)
        self.assertTrue(all(type(relative) is Path for relative in expected))

        ignored = REPO_ROOT / "scripts/test/ignored-plan-fixture.sh"
        ignore_file = REPO_ROOT / ".gitignore"
        original_ignore = ignore_file.read_text(encoding="utf-8")
        try:
            with ignore_file.open("a", encoding="utf-8") as stream:
                stream.write("scripts/test/ignored-plan-fixture.sh\n")
            ignored.write_text("#!/usr/bin/env bash\n", encoding="utf-8")
            self.assertNotIn(
                Path("scripts/test/ignored-plan-fixture.sh"),
                repository_shell_validation.discover_shell_sources(REPO_ROOT),
            )
        finally:
            ignored.unlink(missing_ok=True)
            ignore_file.write_text(original_ignore, encoding="utf-8")

    def test_source_set_digest_changes_for_added_removed_and_changed_sources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = Path("scripts/test/first.sh")
            second = Path("scripts/test/second.sh")
            (root / first).parent.mkdir(parents=True)
            (root / first).write_bytes(b"first\n")
            before = repository_shell_validation.source_set_digest(root, [first])
            (root / second).write_bytes(b"second\n")
            added = repository_shell_validation.source_set_digest(root, [first, second])
            (root / first).write_bytes(b"changed\n")
            changed = repository_shell_validation.source_set_digest(root, [first, second])
            removed = repository_shell_validation.source_set_digest(root, [second])
            self.assertNotEqual(before, added)
            self.assertNotEqual(added, changed)
            self.assertNotEqual(changed, removed)

    def test_produce_stops_before_shellcheck_on_first_bash_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repository(root)
            (root / "scripts/test/bad.sh").write_text("#!/usr/bin/env bash\n")
            subprocess.run(["git", "add", "scripts/test/bad.sh"], cwd=root, check=True)
            subprocess.run(["git", "commit", "--quiet", "-m", "bad"], cwd=root, check=True)
            tools, shellcheck_sentinel = self.fake_tools(root, bash_failure=True)
            artifact = root / "artifact.json"
            environment = {**os.environ, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}"}
            with mock.patch.dict(os.environ, environment, clear=True):
                self.assertEqual(
                    repository_shell_validation.produce(
                        root=root,
                        suite="validation.repo-validate",
                        run_id="run-1",
                        artifact_path=artifact,
                        junit_path=None,
                    ),
                    2,
                )
            result = json.loads(artifact.read_text(encoding="utf-8"))
            self.assertEqual(result["result"]["bash_first_failure"]["file"], "scripts/test/bad.sh")
            self.assertEqual(
                result["result"]["bash_first_failure"]["stderr"],
                "bad.sh: line 2: syntax error",
            )
            self.assertIsNone(result["result"]["shellcheck_status"])
            self.assertFalse(shellcheck_sentinel.exists())
            self.assertEqual(result["findings"], [])

    def test_produce_runs_shellcheck_once_after_bash_and_writes_exact_finding_fields(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repository(root)
            tools, shellcheck_sentinel = self.fake_tools(root)
            artifact = root / "artifact.json"
            junit = root / "result.xml"
            environment = {**os.environ, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}"}
            with mock.patch.dict(os.environ, environment, clear=True):
                self.assertEqual(
                    repository_shell_validation.produce(
                        root=root,
                        suite="validation.repo-validate",
                        run_id="run-1",
                        artifact_path=artifact,
                        junit_path=junit,
                    ),
                    1,
                )
            result = json.loads(artifact.read_text(encoding="utf-8"))
            self.assertEqual(
                set(result),
                {
                    "schema_version",
                    "run_id",
                    "head_sha",
                    "source_set_sha256",
                    "bash_version",
                    "shellcheck_version",
                    "bash_argv",
                    "shellcheck_argv",
                    "producer_suite",
                    "result",
                    "findings",
                },
            )
            self.assertEqual(
                set(result["result"]),
                {
                    "bash_status",
                    "bash_first_failure",
                    "shellcheck_status",
                    "sorted_files",
                    "completed_at",
                },
            )
            self.assertEqual(result["schema_version"], 1)
            self.assertEqual(result["producer_suite"], "validation.repo-validate")
            self.assertEqual(result["bash_argv"], ["bash", "-n"])
            self.assertEqual(
                result["shellcheck_argv"],
                ["shellcheck", "--external-sources", "--format=json"],
            )
            self.assertEqual(result["result"]["bash_status"], 0)
            self.assertIsNone(result["result"]["bash_first_failure"])
            self.assertEqual(result["result"]["shellcheck_status"], 1)
            self.assertEqual(
                result["findings"],
                [
                    {
                        "file": "scripts/test/ok.sh",
                        "line": 2,
                        "column": 1,
                        "level": "warning",
                        "code": 2086,
                        "message": "quote this",
                    }
                ],
            )
            self.assertEqual(
                shellcheck_sentinel.read_text(encoding="utf-8"),
                "--external-sources --format=json scripts/test/ok.sh\n",
            )
            self.assertTrue(junit.is_file())

    def test_consume_reuses_only_matching_passed_artifact_and_recomputes_otherwise(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repository(root)
            tools, shellcheck_sentinel = self.fake_tools(root)
            artifact = root / "artifact.json"
            environment = {**os.environ, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}"}
            with mock.patch.dict(os.environ, environment, clear=True):
                (tools / "shellcheck").write_text(
                    "#!/bin/sh\n"
                    "if [ \"$1\" = \"--version\" ]; then printf '%s\\n' 'ShellCheck fake 1.0'; exit 0; fi\n"
                    f": > {shellcheck_sentinel}\nprintf '[]\\n'\nexit 0\n"
                )
                (tools / "shellcheck").chmod(0o755)
                self.assertEqual(
                    repository_shell_validation.produce(
                        root=root,
                        suite="validation.repo-validate",
                        run_id="run-1",
                        artifact_path=artifact,
                        junit_path=None,
                    ),
                    0,
                )
                shellcheck_sentinel.unlink()
                self.assertEqual(
                    repository_shell_validation.consume(
                        root=root,
                        suite="validation.test-harness",
                        artifact_path=artifact,
                        run_id="run-1",
                        junit_path=root / "reused.xml",
                    ),
                    0,
                )
                self.assertFalse(shellcheck_sentinel.exists())
                result = json.loads(artifact.read_text(encoding="utf-8"))
                result["unexpected"] = True
                artifact.write_text(json.dumps(result), encoding="utf-8")
                self.assertEqual(
                    repository_shell_validation.consume(
                        root=root,
                        suite="validation.test-harness",
                        artifact_path=artifact,
                        run_id="run-1",
                        junit_path=None,
                    ),
                    0,
                )
                self.assertTrue(shellcheck_sentinel.exists())
                shellcheck_sentinel.unlink()
                self.assertEqual(
                    repository_shell_validation.consume(
                        root=root,
                        suite="validation.test-harness",
                        artifact_path=artifact,
                        run_id="other-run",
                        junit_path=None,
                    ),
                    0,
                )
            self.assertTrue(shellcheck_sentinel.exists())


if __name__ == "__main__":
    unittest.main()
