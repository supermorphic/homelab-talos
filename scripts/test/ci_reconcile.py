"""Reconcile canonical CI group evidence against one exact validated plan."""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import stat
import subprocess
import sys
import tempfile
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

import yaml
from catalog_validator import validate_catalog
from ci_plan import EXECUTIONS, GROUPS, Plan, read_plan, read_yaml, unique_json_object

ROOT = Path(__file__).resolve().parents[2]
RUN_FILES = {"summary.json", "environment.json", "evidence.json", "junit.xml"}


@dataclass(frozen=True)
class GroupResult:
    group: str
    execution: str
    plan_id: str
    base_sha: str
    head_sha: str
    run_id: str
    result: str
    summary_path: Path


class UnsafeInput(ValueError):
    """An input or output cannot safely be accessed."""


class InvalidResults(ValueError):
    """Ordinary evidence failures, retaining independently validated runs."""

    def __init__(self, reasons: list[str], results: tuple[GroupResult, ...]):
        super().__init__("\n".join(reasons))
        self.reasons = reasons
        self.results = results


def check_path(path: Path) -> None:
    # Check ancestors as well as the leaf before any traversal or content read.
    for part in (*reversed(path.absolute().parents), path.absolute()):
        if part.is_symlink():
            raise UnsafeInput(f"symlink is not allowed: {part}")
        if part.exists() and not (part.is_dir() or part.is_file()):
            raise UnsafeInput(f"path must be a regular file or directory: {part}")


def scan_tree(root: Path) -> tuple[Path, ...]:
    check_path(root)
    if not root.is_dir():
        raise UnsafeInput(f"results root must be a directory: {root}")

    def traversal_error(error: OSError) -> None:
        raise UnsafeInput(f"cannot traverse results tree: {error}") from error

    directories = []
    for directory, children, files in os.walk(root, followlinks=False, onerror=traversal_error):
        path = Path(directory)
        directories.append(path)
        for name in children + files:
            child = path / name
            mode = child.lstat().st_mode
            if stat.S_ISLNK(mode):
                raise UnsafeInput(f"symlink is not allowed: {child}")
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                raise UnsafeInput(f"path must be a regular file or directory: {child}")
    return tuple(sorted(directories))


def load_json(path: Path) -> dict:
    check_path(path)
    payload = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_json_object)
    if not isinstance(payload, dict):
        raise TypeError(f"JSON document must be an object: {path}")
    return payload


def discover_results(root: Path) -> tuple[GroupResult, ...]:
    """Validate every downloaded child run; unsafe trees are rejected before reads."""
    directories = scan_tree(root)
    candidates = []
    results = []
    reasons = []
    for directory in directories:
        if any(parent in directory.parents for parent in candidates):
            continue
        if (
            RUN_FILES.intersection(child.name for child in directory.iterdir())
            or (directory / "diagnostics/ci-binding.json").exists()
            or (
                len(directory.name) > 15
                and directory.name[:8].isdigit()
                and directory.name[8] == "T"
            )
        ):
            candidates.append(directory)
        else:
            for child in sorted(directory.iterdir()):
                if child.is_file():
                    reasons.append(f"unexpected evidence file: {child.relative_to(root)}")
    for directory in candidates:
        validation = subprocess.run(
            [str(ROOT / "scripts/test/validate-run.sh"), str(directory.absolute())],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        if validation.returncode == 2:
            raise UnsafeInput(
                f"canonical validator configuration error: {validation.stderr.strip()}"
            )
        if validation.returncode:
            reasons.append(f"invalid canonical run {directory.name}: {validation.stderr.strip()}")
            continue
        try:
            # The shell validator accepts YAML as well. Evidence for this interface
            # must additionally be strict JSON without duplicate object fields.
            documents = {
                name: load_json(directory / name) for name in sorted(RUN_FILES - {"junit.xml"})
            }
            summary = documents["summary.json"]
            binding = load_json(directory / "diagnostics/ci-binding.json")
            results.append(
                GroupResult(
                    group=binding["group"],
                    execution=binding["execution"],
                    plan_id=binding["plan_id"],
                    base_sha=binding["base_sha"],
                    head_sha=binding["head_sha"],
                    run_id=summary["run_id"],
                    result=summary["result"],
                    summary_path=directory / "summary.json",
                )
            )
        except UnsafeInput:
            raise
        except (OSError, ValueError, KeyError, TypeError) as error:
            reasons.append(f"invalid run JSON {directory.name}: {error}")
    discovered = tuple(results)
    if reasons:
        raise InvalidResults(reasons, discovered)
    return discovered


def candidate_executions(plan: Plan, repo: Path) -> dict[str, list[str]]:
    """Resolve the catalog bytes bound by the plan's immutable candidate commit."""
    check_path(repo)
    try:
        kind = subprocess.run(
            ["git", "-C", str(repo), "cat-file", "-t", plan.head_sha],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        if kind != "commit":
            raise ValueError("candidate revision must name a commit")
        content = subprocess.run(
            ["git", "-C", str(repo), "show", f"{plan.head_sha}:tests/catalog.yaml"],
            capture_output=True,
            check=True,
        ).stdout
        with tempfile.TemporaryDirectory(prefix="ci-candidate-catalog-") as directory:
            path = Path(directory) / "catalog.yaml"
            path.write_bytes(content)
            catalog = read_yaml(path)
            diagnostics = io.StringIO()
            with contextlib.redirect_stdout(diagnostics), contextlib.redirect_stderr(diagnostics):
                status = validate_catalog(str(path))
            if status:
                raise ValueError(diagnostics.getvalue().strip())
        return catalog["executions"]
    except (
        OSError,
        subprocess.CalledProcessError,
        ValueError,
        TypeError,
        KeyError,
        AttributeError,
        yaml.YAMLError,
    ) as error:
        raise UnsafeInput(f"invalid candidate catalog at {plan.head_sha}: {error}") from error


def evaluate(
    plan_path: Path, results_root: Path, *, repo: Path = ROOT
) -> tuple[dict, list[str], list[tuple]]:
    check_path(plan_path)
    try:
        plan: Plan = read_plan(plan_path)
    except (OSError, ValueError, TypeError) as error:
        raise UnsafeInput(f"invalid plan: {error}") from error
    executions = candidate_executions(plan, repo)
    return evaluate_results(plan, results_root, executions)


def evaluate_results(
    plan: Plan, results_root: Path, executions: dict[str, list[str]]
) -> tuple[dict, list[str], list[tuple]]:
    """Check canonical runs against an already validated plan and candidate catalog."""
    reasons = []
    try:
        results = discover_results(results_root)
    except InvalidResults as error:
        results, reasons = error.results, error.reasons
    by_group = defaultdict(list)
    for result in results:
        by_group[result.group].append(result)
    groups = []
    rows = []
    order = [group for group in GROUPS if group in plan.groups or group in by_group]
    for group in order:
        runs = by_group[group]
        required = group in plan.groups
        if not required:
            reasons.append(f"unexpected group: {group}")
        if not runs:
            reasons.append(f"missing required group: {group}")
            groups.append({"id": group, "run_id": None, "result": "missing"})
            rows.append((group, "yes", "—", "missing", "—", "—"))
        if len(runs) > 1:
            reasons.append(f"duplicate group: {group} ({len(runs)} runs)")
        for run in runs:
            result = run.result
            for field, expected in (
                ("plan_id", plan.plan_id),
                ("base_sha", plan.base_sha),
                ("head_sha", plan.head_sha),
                ("execution", EXECUTIONS[group]),
            ):
                if getattr(run, field) != expected:
                    reasons.append(
                        f"group {group} {field} mismatch: expected {expected}, "
                        f"got {getattr(run, field)}"
                    )
                    result = "failed"
            summary = load_json(run.summary_path)
            expected_suites = executions[EXECUTIONS[group]]
            actual_suites = {suite["id"] for suite in summary["suites"]}
            for suite_id in expected_suites:
                if suite_id not in actual_suites:
                    reasons.append(f"group {group} missing expected suite: {suite_id}")
                    result = "failed"
            for suite in summary["suites"]:
                if suite["id"] not in expected_suites:
                    reasons.append(f"group {group} unexpected suite: {suite['id']}")
                    result = "failed"
                if suite["result"] != "passed":
                    reasons.append(
                        f"group {group} suite {suite['id']} result is {suite['result']}"
                    )
                    result = "failed"
            if run.result != "passed":
                reasons.append(f"group {group} result is {run.result}")
            if summary["junit"]["failures"] or summary["junit"]["errors"]:
                reasons.append(f"group {group} has JUnit failures or errors")
                result = "failed"
            if not required or len(runs) > 1:
                result = "failed"
            groups.append({"id": group, "run_id": run.run_id, "result": result})
            rows.append(
                (
                    group,
                    "yes" if required else "no",
                    run.run_id,
                    result,
                    len(summary["suites"]),
                    summary["junit"]["tests"],
                )
            )
    payload = {
        "schema_version": 1,
        "plan_id": plan.plan_id,
        "base_sha": plan.base_sha,
        "head_sha": plan.head_sha,
        "result": "failed" if reasons else "passed",
        "groups": groups,
    }
    return payload, reasons, rows


def reconcile(plan_path: Path, results_root: Path) -> dict[str, object]:
    return evaluate(plan_path, results_root)[0]


def atomic_write(path: Path, content: str) -> None:
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=path.parent,
            prefix=f".{path.name}.",
            delete=False,
        ) as stream:
            temporary = Path(stream.name)
            stream.write(content)
        check_path(path)
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def markdown_cell(value: object) -> str:
    return (
        str(value)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("|", "&#124;")
        .replace("\n", "<br>")
        .replace("\r", "")
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ("plan", "results", "output"):
        parser.add_argument(f"--{argument}", required=True, type=Path)
    parser.add_argument("--repo", type=Path, default=ROOT)
    args = parser.parse_args()
    try:
        check_path(args.output)
        for name in ("merge-gate.json", "merge-gate.md"):
            check_path(args.output / name)
        payload, reasons, rows = evaluate(args.plan, args.results, repo=args.repo)
        args.output.mkdir(parents=True, exist_ok=True)
        markdown = [
            f"Merge gate: {payload['result']}",
            "",
            "| Group | Required | Run ID | Result | Suites | Tests |",
            "| --- | --- | --- | --- | --- | --- |",
        ]
        markdown.extend("| " + " | ".join(map(markdown_cell, row)) + " |" for row in rows)
        if reasons:
            markdown.extend(["", *[f"- {markdown_cell(reason)}" for reason in reasons]])
        atomic_write(args.output / "merge-gate.json", json.dumps(payload, indent=2) + "\n")
        atomic_write(args.output / "merge-gate.md", "\n".join(markdown) + "\n")
        for reason in reasons:
            print(reason, file=sys.stderr)
        return int(payload["result"] != "passed")
    except (OSError, ValueError) as error:
        print(f"merge-gate configuration/unsafe-input error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
