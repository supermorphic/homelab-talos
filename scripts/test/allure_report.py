"""Safe staging, latest-run selection, and summaries for Allure 3 reports."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import shutil
import sys
from pathlib import Path, PurePosixPath
from typing import Any

RUN_ID_PATTERN = re.compile(
    r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{12}-(?:agent|github-actions|operator)-[0-9a-f]{8}$"
)
RESULTS = {"passed", "failed", "broken", "skipped"}


class ReportError(RuntimeError):
    """A report input is incomplete, invalid, or unsafe."""


def validate_run_id(run_id: str) -> None:
    if not RUN_ID_PATTERN.fullmatch(run_id):
        raise ReportError(f"invalid canonical run ID: {run_id}")


def load_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ReportError(f"could not read valid JSON: {path.name}") from error
    if not isinstance(value, dict):
        raise ReportError(f"JSON root must be an object: {path.name}")
    return value


def parse_finished_at(value: Any) -> dt.datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ReportError("summary end must be RFC3339 UTC")
    try:
        parsed = dt.datetime.fromisoformat(value)
    except ValueError as error:
        raise ReportError("summary end must be RFC3339 UTC") from error
    if parsed.tzinfo != dt.UTC:
        raise ReportError("summary end must use UTC")
    return parsed


def resolve_run(results_root: Path, run_id: str) -> Path:
    validate_run_id(run_id)
    run_dir = results_root / run_id
    if run_dir.is_symlink() or not run_dir.is_dir():
        raise ReportError(f"canonical run does not exist: {run_id}")
    summary = load_object(run_dir / "summary.json")
    if summary.get("run_id") != run_id or summary.get("result") not in RESULTS:
        raise ReportError(f"canonical run is not finalized: {run_id}")
    parse_finished_at(summary.get("end"))
    return run_dir


def select_latest_run(results_root: Path) -> Path:
    if not results_root.is_dir():
        raise ReportError(f"results root does not exist: {results_root}")
    candidates: list[tuple[dt.datetime, str, Path]] = []
    for path in results_root.iterdir():
        if path.is_symlink() or not path.is_dir() or not RUN_ID_PATTERN.fullmatch(path.name):
            continue
        try:
            summary = load_object(path / "summary.json")
            if summary.get("run_id") != path.name or summary.get("result") not in RESULTS:
                continue
            finished_at = parse_finished_at(summary.get("end"))
        except ReportError:
            continue
        candidates.append((finished_at, path.name, path))
    if not candidates:
        raise ReportError(f"no finalized canonical runs found below {results_root}")
    return max(candidates)[2]


def _safe_artifact(run_dir: Path, relative: Any) -> tuple[PurePosixPath, Path]:
    if not isinstance(relative, str):
        raise ReportError("evidence path must be a string")
    pure = PurePosixPath(relative)
    if (
        pure.is_absolute()
        or ".." in pure.parts
        or len(pure.parts) < 2
        or pure.parts[0] not in {"logs", "diagnostics"}
    ):
        raise ReportError(f"unsafe evidence path: {relative}")
    source = run_dir.joinpath(*pure.parts)
    current = source
    while current != run_dir:
        if current.is_symlink():
            raise ReportError(f"evidence path traverses a symlink: {relative}")
        current = current.parent
    if not source.is_file():
        raise ReportError(f"evidence path is not a regular file: {relative}")
    return pure, source


def stage_run(run_dir: Path, workspace: Path) -> None:
    if workspace.exists() and any(workspace.iterdir()):
        raise ReportError("Allure staging workspace must be empty")
    workspace.mkdir(parents=True, exist_ok=True)
    results = workspace / "allure-results"
    attachments = workspace / "attachments"
    metadata = attachments / "metadata"
    results.mkdir()
    metadata.mkdir(parents=True)

    junit = run_dir / "junit.xml"
    if junit.is_symlink() or not junit.is_file():
        raise ReportError("canonical JUnit is missing or unsafe")
    shutil.copy2(junit, results / "junit.xml")

    for name in ("summary.json", "environment.json", "evidence.json"):
        source = run_dir / name
        if source.is_symlink() or not source.is_file():
            raise ReportError(f"canonical metadata is missing or unsafe: {name}")
        shutil.copy2(source, metadata / name)

    evidence = load_object(run_dir / "evidence.json")
    artifacts = evidence.get("artifacts")
    if not isinstance(artifacts, list):
        raise ReportError("evidence artifacts must be an array")
    seen: set[str] = set()
    for artifact in artifacts:
        if not isinstance(artifact, dict):
            raise ReportError("evidence artifact must be an object")
        relative = artifact.get("path")
        pure, source = _safe_artifact(run_dir, relative)
        normalized = str(pure)
        if normalized in seen:
            raise ReportError(f"duplicate evidence path: {normalized}")
        seen.add(normalized)
        destination = attachments.joinpath(*pure.parts)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)


def markdown_summary(summary: dict[str, Any], report_generated: bool) -> str:
    run_id = str(summary.get("run_id", "unknown"))
    result = str(summary.get("result", "unknown"))
    marker = {"passed": "✅", "failed": "❌", "broken": "⚠️", "skipped": "⏭️"}.get(result, "❔")
    junit = summary.get("junit", {})
    lines = [
        "## Test results",
        "",
        f"{marker} **{result.upper()}** — `{run_id}`",
        "",
        "| Cases | Passed | Failed | Broken | Skipped | Duration |",
        "|---:|---:|---:|---:|---:|---:|",
        (
            f"| {junit.get('tests', 0)} | {junit.get('passed', 0)} | "
            f"{junit.get('failures', 0)} | {junit.get('errors', 0)} | "
            f"{junit.get('skipped', 0)} | {summary.get('duration_seconds', 0)}s |"
        ),
        "",
        "| Suite | Result | Tests | Failures | Errors | Skipped |",
        "|---|---|---:|---:|---:|---:|",
    ]
    suites = summary.get("suites", [])
    if isinstance(suites, list):
        for suite in suites:
            if not isinstance(suite, dict):
                continue
            suite_id = str(suite.get("id", "unknown")).replace("|", r"\|")
            suite_result = str(suite.get("result", "unknown"))
            lines.append(
                f"| `{suite_id}` | {suite_result} | {suite.get('tests', 0)} | "
                f"{suite.get('failures', 0)} | {suite.get('errors', 0)} | "
                f"{suite.get('skipped', 0)} |"
            )
    lines.extend(
        [
            "",
            (
                "The static Allure Awesome report is available in the workflow artifact."
                if report_generated
                else "The Allure report could not be generated; canonical results remain available."
            ),
        ]
    )
    return "\n".join(lines) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    latest = subparsers.add_parser("latest")
    latest.add_argument("--results-root", type=Path, required=True)

    stage = subparsers.add_parser("stage")
    stage.add_argument("--results-root", type=Path, required=True)
    stage.add_argument("--run-id", required=True)
    stage.add_argument("--workspace", type=Path, required=True)

    summary = subparsers.add_parser("markdown")
    summary.add_argument("--results-root", type=Path, required=True)
    summary.add_argument("--run-id", default="latest")
    summary.add_argument(
        "--report-generated",
        choices=("true", "false"),
        default="true",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.command == "latest":
            print(select_latest_run(args.results_root).name)
            return 0
        if args.command == "stage":
            run_dir = resolve_run(args.results_root, args.run_id)
            stage_run(run_dir, args.workspace)
            return 0
        if args.command == "markdown":
            run_dir = (
                select_latest_run(args.results_root)
                if args.run_id == "latest"
                else resolve_run(args.results_root, args.run_id)
            )
            print(
                markdown_summary(
                    load_object(run_dir / "summary.json"),
                    args.report_generated == "true",
                ),
                end="",
            )
            return 0
    except ReportError as error:
        print(f"Allure report error: {error}", file=sys.stderr)
        return 2
    raise AssertionError(f"unhandled command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
