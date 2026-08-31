#!/usr/bin/env python3
"""Produce and consume the same-run repository shell validation artifact."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

JUNIT_REPORT_PATH = Path(__file__).with_name("junit_report.py")
JUNIT_REPORT_SPEC = importlib.util.spec_from_file_location("junit_report", JUNIT_REPORT_PATH)
assert JUNIT_REPORT_SPEC and JUNIT_REPORT_SPEC.loader
junit_report = importlib.util.module_from_spec(JUNIT_REPORT_SPEC)
JUNIT_REPORT_SPEC.loader.exec_module(junit_report)

REPOSITORY_DIRS = (
    "scripts/hooks",
    "scripts/repository",
    "scripts/secrets",
    "scripts/validate",
    "scripts/verify",
    "scripts/test",
    "tests/probes",
)
PRODUCER_SUITE = "validation.repo-validate"
BASH_ARGV = ["bash", "-n"]
SHELLCHECK_ARGV = ["shellcheck", "--external-sources", "--format=json"]
SHA1 = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
RFC3339_UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def discover_shell_sources(root: Path) -> list[Path]:
    """Return sorted, repository-relative non-symlinked shell source paths."""
    completed = subprocess.run(
        ["git", "ls-files", "-co", "--exclude-standard", "-z", "--", *REPOSITORY_DIRS],
        cwd=root,
        check=True,
        capture_output=True,
    )
    discovered = []
    for raw in completed.stdout.split(b"\0"):
        if not raw or not raw.endswith(b".sh"):
            continue
        relative = Path(os.fsdecode(raw))
        candidate = root / relative
        if candidate.is_file() and not candidate.is_symlink():
            discovered.append(relative)
    return sorted(discovered)


def source_set_digest(root: Path, relative_paths: list[Path]) -> str:
    """Hash the ordered repository-relative source names and their bytes."""
    digest = hashlib.sha256()
    for relative in relative_paths:
        digest.update(
            relative.as_posix().encode("utf-8") + b"\0" + (root / relative).read_bytes() + b"\0"
        )
    return digest.hexdigest()


def command_version(command: str) -> str:
    completed = subprocess.run([command, "--version"], check=True, text=True, capture_output=True)
    version = completed.stdout.strip()
    if not version:
        raise ValueError(f"{command} --version returned no output")
    return version


def head_sha(root: Path) -> str:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=root, check=True, text=True, capture_output=True
    )
    sha = completed.stdout.strip()
    if not SHA1.fullmatch(sha):
        raise ValueError("git HEAD is not a lowercase SHA-1")
    return sha


def normalized_findings(shellcheck_output: str) -> list[dict[str, Any]]:
    raw_findings = json.loads(shellcheck_output or "[]")
    if not isinstance(raw_findings, list):
        raise TypeError("ShellCheck JSON must be an array")
    findings = []
    for raw in raw_findings:
        if not isinstance(raw, dict):
            raise TypeError("ShellCheck finding must be an object")
        findings.append(
            {
                "file": raw["file"],
                "line": raw["line"],
                "column": raw["column"],
                "level": raw["level"],
                "code": raw["code"],
                "message": raw["message"],
            }
        )
    return findings


def completed_at() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def exact_keys(document: dict[str, Any], expected: set[str], name: str) -> None:
    if set(document) != expected:
        raise ValueError(f"{name} has unexpected or missing fields")


def is_integer(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def validate_result_schema(document: object) -> None:
    """Validate the complete native result before publication or reuse."""
    if not isinstance(document, dict):
        raise TypeError("repository shell result must be an object")
    exact_keys(
        document,
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
        "repository shell result",
    )
    if document["schema_version"] != 1:
        raise ValueError("unsupported repository shell result schema")
    if not isinstance(document["run_id"], str) or not document["run_id"]:
        raise TypeError("run_id must be a non-empty string")
    if not isinstance(document["head_sha"], str) or not SHA1.fullmatch(document["head_sha"]):
        raise ValueError("head_sha must be a lowercase SHA-1")
    if not isinstance(document["source_set_sha256"], str) or not SHA256.fullmatch(
        document["source_set_sha256"]
    ):
        raise ValueError("source_set_sha256 must be a lowercase SHA-256")
    for field in ("bash_version", "shellcheck_version"):
        if not isinstance(document[field], str) or not document[field]:
            raise TypeError(f"{field} must be a non-empty string")
    if document["bash_argv"] != BASH_ARGV or document["shellcheck_argv"] != SHELLCHECK_ARGV:
        raise ValueError("repository shell command arguments do not match the schema")
    if document["producer_suite"] != PRODUCER_SUITE:
        raise ValueError("repository shell producer suite does not match the schema")

    result = document["result"]
    if not isinstance(result, dict):
        raise TypeError("result must be an object")
    exact_keys(
        result,
        {
            "bash_status",
            "bash_first_failure",
            "shellcheck_status",
            "sorted_files",
            "completed_at",
        },
        "result",
    )
    if not is_integer(result["bash_status"]) or result["bash_status"] < 0:
        raise TypeError("bash_status must be a non-negative integer")
    if not isinstance(result["sorted_files"], list) or any(
        not isinstance(path, str) or not path for path in result["sorted_files"]
    ):
        raise TypeError("sorted_files must contain non-empty strings")
    if result["sorted_files"] != sorted(result["sorted_files"]):
        raise ValueError("sorted_files must be sorted")
    if not isinstance(result["completed_at"], str) or not RFC3339_UTC.fullmatch(
        result["completed_at"]
    ):
        raise ValueError("completed_at must be RFC3339 UTC")

    findings = document["findings"]
    if not isinstance(findings, list):
        raise TypeError("findings must be an array")
    for finding in findings:
        if not isinstance(finding, dict):
            raise TypeError("ShellCheck finding must be an object")
        exact_keys(finding, {"file", "line", "column", "level", "code", "message"}, "finding")
        if not isinstance(finding["file"], str) or not finding["file"]:
            raise TypeError("ShellCheck file must be a non-empty string")
        if not is_integer(finding["line"]) or finding["line"] < 1:
            raise TypeError("ShellCheck line must be a positive integer")
        if not is_integer(finding["column"]) or finding["column"] < 1:
            raise TypeError("ShellCheck column must be a positive integer")
        if not is_integer(finding["code"]) or finding["code"] < 1:
            raise TypeError("ShellCheck code must be a positive integer")
        if not isinstance(finding["level"], str) or not finding["level"]:
            raise TypeError("ShellCheck level must be a non-empty string")
        if not isinstance(finding["message"], str):
            raise TypeError("ShellCheck message must be a string")

    if result["bash_status"] == 0:
        if result["bash_first_failure"] is not None:
            raise ValueError("passed Bash result must not have a first failure")
        if not is_integer(result["shellcheck_status"]) or result["shellcheck_status"] < 0:
            raise TypeError("passed Bash result must have a ShellCheck status")
    else:
        first_failure = result["bash_first_failure"]
        if not isinstance(first_failure, dict):
            raise TypeError("failed Bash result must have a first failure")
        exact_keys(first_failure, {"file", "stderr"}, "bash_first_failure")
        if not isinstance(first_failure["file"], str) or not first_failure["file"]:
            raise TypeError("Bash failure file must be a non-empty string")
        if not isinstance(first_failure["stderr"], str):
            raise TypeError("Bash failure stderr must be a string")
        if result["shellcheck_status"] is not None:
            raise ValueError("failed Bash result must not have a ShellCheck status")
        if findings:
            raise ValueError("failed Bash result must not have ShellCheck findings")


def load_exact_schema(artifact_path: Path) -> dict[str, Any]:
    document = json.loads(artifact_path.read_text(encoding="utf-8"))
    validate_result_schema(document)
    return document


def expected_identity(root: Path, suite: str, run_id: str | None) -> dict[str, Any]:
    """Return the mutable execution identity required for same-run reuse."""
    if not isinstance(suite, str) or not suite:
        raise ValueError("suite must be a non-empty string")
    sources = discover_shell_sources(root)
    return {
        "run_id": run_id,
        "head_sha": head_sha(root),
        "source_set_sha256": source_set_digest(root, sources),
        "bash_version": command_version("bash"),
        "shellcheck_version": command_version("shellcheck"),
        "bash_argv": BASH_ARGV,
        "shellcheck_argv": SHELLCHECK_ARGV,
        "producer_suite": PRODUCER_SUITE,
    }


def artifact_matches(artifact_path: Path, expected: dict[str, Any]) -> bool:
    """Return whether an artifact is a complete passed result for this execution."""
    if expected["run_id"] is None:
        return False
    try:
        document = load_exact_schema(artifact_path)
    except (json.JSONDecodeError, OSError, TypeError, ValueError):
        return False
    if any(document[field] != expected[field] for field in expected):
        return False
    result = document["result"]
    return (
        result["bash_status"] == 0
        and result["bash_first_failure"] is None
        and result["shellcheck_status"] == 0
        and document["findings"] == []
    )


def produce_document(root: Path, run_id: str) -> dict[str, Any]:
    """Run Bash first, then one batched ShellCheck command when Bash passes."""
    sorted_files = discover_shell_sources(root)
    serialized_files = [relative.as_posix() for relative in sorted_files]
    findings: list[dict[str, Any]] = []
    bash_status = 0
    bash_first_failure: dict[str, str] | None = None
    shellcheck_status: int | None = None
    for relative, relative_text in zip(sorted_files, serialized_files, strict=True):
        completed = subprocess.run(
            ["bash", "-n", relative_text],
            cwd=root,
            check=False,
            text=True,
            capture_output=True,
        )
        if completed.returncode:
            bash_status = completed.returncode
            bash_first_failure = {"file": relative_text, "stderr": completed.stderr}
            break
    if bash_status == 0:
        completed = subprocess.run(
            ["shellcheck", "--external-sources", "--format=json", *serialized_files],
            cwd=root,
            check=False,
            text=True,
            capture_output=True,
        )
        shellcheck_status = completed.returncode
        findings = normalized_findings(completed.stdout)
    return {
        "schema_version": 1,
        "run_id": run_id,
        "head_sha": head_sha(root),
        "source_set_sha256": source_set_digest(root, sorted_files),
        "bash_version": command_version("bash"),
        "shellcheck_version": command_version("shellcheck"),
        "bash_argv": BASH_ARGV,
        "shellcheck_argv": SHELLCHECK_ARGV,
        "producer_suite": PRODUCER_SUITE,
        "result": {
            "bash_status": bash_status,
            "bash_first_failure": bash_first_failure,
            "shellcheck_status": shellcheck_status,
            "sorted_files": serialized_files,
            "completed_at": completed_at(),
        },
        "findings": findings,
    }


def publish_junit_if_requested(result_path: Path, suite: str, junit_path: Path | None) -> int:
    if junit_path is None:
        return 0
    return junit_report.repository_shell_report(junit_path, suite, result_path)


def result_status(document: dict[str, Any]) -> int:
    result = document["result"]
    if result["bash_status"] != 0:
        return result["bash_status"]
    return result["shellcheck_status"]


def produce(
    root: Path,
    suite: str,
    run_id: str,
    artifact_path: Path,
    junit_path: Path | None,
) -> int:
    """Produce, validate, and atomically publish one native result document."""
    document = produce_document(root, run_id)
    artifact_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=artifact_path.parent, delete=False
        ) as temporary:
            temporary_path = Path(temporary.name)
            json.dump(document, temporary, sort_keys=True)
            temporary.write("\n")
            temporary.flush()
        with temporary_path.open("rb") as stream:
            os.fsync(stream.fileno())
        validate_result_schema(json.loads(temporary_path.read_text(encoding="utf-8")))
        junit_status = publish_junit_if_requested(temporary_path, suite, junit_path)
        if junit_status != 0:
            return junit_status
        os.replace(temporary_path, artifact_path)
        temporary_path = None
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
    return result_status(document)


def consume(
    root: Path,
    suite: str,
    artifact_path: Path | None,
    run_id: str | None,
    junit_path: Path | None,
) -> int:
    """Reuse a matching passed artifact or recompute in a private directory."""
    expected = expected_identity(root=root, suite=suite, run_id=run_id)
    if artifact_path is not None and artifact_matches(artifact_path, expected):
        return publish_junit_if_requested(artifact_path, suite, junit_path)
    with tempfile.TemporaryDirectory(prefix="repository-shell-consume-") as private:
        return produce(
            root=root,
            suite=suite,
            run_id=run_id or "standalone",
            artifact_path=Path(private) / "result.json",
            junit_path=junit_path,
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    produce_parser = subparsers.add_parser("produce")
    produce_parser.add_argument("--suite", required=True)
    produce_parser.add_argument("--artifact", required=True, type=Path)
    produce_parser.add_argument("--run-id", required=True)
    produce_parser.add_argument("--junit", type=Path)
    consume_parser = subparsers.add_parser("consume")
    consume_parser.add_argument("--suite", required=True)
    consume_parser.add_argument("--artifact", type=Path)
    consume_parser.add_argument("--run-id")
    consume_parser.add_argument("--junit", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path.cwd()
    try:
        if args.command == "produce":
            return produce(root, args.suite, args.run_id, args.artifact, args.junit)
        return consume(root, args.suite, args.artifact, args.run_id, args.junit)
    except (
        OSError,
        subprocess.CalledProcessError,
        TypeError,
        ValueError,
        json.JSONDecodeError,
    ) as error:
        print(f"repository shell validation error: {error}", file=os.sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
