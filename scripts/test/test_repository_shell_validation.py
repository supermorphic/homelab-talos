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
        (root / ".mise.toml").write_text('[tools]\nshellcheck = "fake-1.0"\n')
        (root / "scripts/test/ok.sh").write_text("#!/usr/bin/env bash\necho ok\n")
        subprocess.run(["git", "add", ".mise.toml", "scripts/test/ok.sh"], cwd=root, check=True)
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
                f"printf '%s\\n' \"$*\" >> {shellcheck_sentinel}",
                'if [ "$1" = "--version" ]; then',
                "  printf '%s\\n' 'ShellCheck fake 1.0'",
                "  exit 0",
                "fi",
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
            self.assertFalse(
                shellcheck_sentinel.exists(), "Bash failure must not execute ShellCheck"
            )
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

    def test_discovery_excludes_a_tracked_shell_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repository(root)
            (root / "scripts/test/symlinked.sh").symlink_to("ok.sh")
            subprocess.run(["git", "add", "scripts/test/symlinked.sh"], cwd=root, check=True)
            self.assertNotIn(
                Path("scripts/test/symlinked.sh"),
                repository_shell_validation.discover_shell_sources(root),
            )

    def test_produce_keeps_existing_artifact_when_junit_adapter_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repository(root)
            tools, _ = self.fake_tools(root)
            artifact = root / "artifact.json"
            artifact.write_text('{"previous":"artifact"}\n', encoding="utf-8")
            environment = {**os.environ, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}"}
            with (
                mock.patch.dict(os.environ, environment, clear=True),
                mock.patch.object(
                    repository_shell_validation.junit_report,
                    "repository_shell_report",
                    return_value=2,
                ),
            ):
                self.assertEqual(
                    repository_shell_validation.produce(
                        root=root,
                        suite="validation.repo-validate",
                        run_id="run-1",
                        artifact_path=artifact,
                        junit_path=root / "result.xml",
                    ),
                    2,
                )
            self.assertEqual(artifact.read_text(encoding="utf-8"), '{"previous":"artifact"}\n')

    def test_consume_missing_artifact_stops_at_bash_before_shellcheck(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repository(root)
            (root / "scripts/test/bad.sh").write_text("#!/usr/bin/env bash\n")
            subprocess.run(["git", "add", "scripts/test/bad.sh"], cwd=root, check=True)
            subprocess.run(["git", "commit", "--quiet", "-m", "bad"], cwd=root, check=True)
            tools, shellcheck_sentinel = self.fake_tools(root, bash_failure=True)
            environment = {**os.environ, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}"}
            with mock.patch.dict(os.environ, environment, clear=True):
                self.assertEqual(
                    repository_shell_validation.consume(
                        root=root,
                        suite="validation.test-harness",
                        artifact_path=root / "missing.json",
                        run_id="run-1",
                        junit_path=None,
                    ),
                    2,
                )
            self.assertFalse(shellcheck_sentinel.exists())

    def test_consume_recomputes_when_run_id_does_not_match(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_repository(root)
            tools, shellcheck_sentinel = self.fake_tools(root)
            artifact = root / "artifact.json"
            environment = {**os.environ, "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}"}
            with mock.patch.dict(os.environ, environment, clear=True):
                (tools / "shellcheck").write_text(
                    "#!/bin/sh\n"
                    f"printf '%s\\n' \"$*\" >> {shellcheck_sentinel}\n"
                    "printf '[]\\n'\nexit 0\n"
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
                        run_id="other-run",
                        junit_path=None,
                    ),
                    0,
                )
            self.assertEqual(
                shellcheck_sentinel.read_text(encoding="utf-8"),
                "--external-sources --format=json scripts/test/ok.sh\n",
            )

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
                baseline = artifact.read_text(encoding="utf-8")

                def mutate_artifact(transform: object) -> None:
                    document = json.loads(baseline)
                    assert callable(transform)
                    transform(document)
                    artifact.write_text(json.dumps(document), encoding="utf-8")

                def failed(document: dict[str, object]) -> None:
                    document["result"] = {
                        "bash_status": 2,
                        "bash_first_failure": {"file": "scripts/test/ok.sh", "stderr": "bad"},
                        "shellcheck_status": None,
                        "sorted_files": ["scripts/test/ok.sh"],
                        "completed_at": document["result"]["completed_at"],
                    }
                    document["findings"] = []

                def status_inconsistent(document: dict[str, object]) -> None:
                    document["findings"] = [
                        {
                            "file": "scripts/test/ok.sh",
                            "line": 1,
                            "column": 1,
                            "level": "warning",
                            "code": 2086,
                            "message": "unexpected with success",
                        }
                    ]

                cases = (
                    ("missing", None),
                    ("truncated", "{"),
                    ("failed", failed),
                    (
                        "stale digest",
                        lambda document: document.__setitem__("source_set_sha256", "0" * 64),
                    ),
                    ("stale HEAD", lambda document: document.__setitem__("head_sha", "0" * 40)),
                    (
                        "tool mismatch",
                        lambda document: document.__setitem__("bash_version", "other"),
                    ),
                    (
                        "ShellCheck tool mismatch",
                        lambda document: document.__setitem__("shellcheck_version", "other"),
                    ),
                    (
                        "argv mismatch",
                        lambda document: document.__setitem__("bash_argv", ["bash", "-x"]),
                    ),
                    ("status inconsistent", status_inconsistent),
                    (
                        "tampered sorted files",
                        lambda document: document["result"].__setitem__(
                            "sorted_files", ["scripts/test/ok.sh", "scripts/test/ok.sh"]
                        ),
                    ),
                    ("corrupt", "["),
                )
                for name, mutation in cases:
                    with self.subTest(name=name):
                        artifact.write_text(baseline, encoding="utf-8")
                        if mutation is None:
                            artifact.unlink()
                        elif isinstance(mutation, str):
                            artifact.write_text(mutation, encoding="utf-8")
                        else:
                            mutate_artifact(mutation)
                        shellcheck_sentinel.unlink(missing_ok=True)
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


if __name__ == "__main__":
    unittest.main()
