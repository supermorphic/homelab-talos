"""Fresh local publication evidence using the repository's CI plan and groups."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from ci_plan import make_plan, write_plan
from ci_reconcile import atomic_write, check_path

ROOT = Path(__file__).resolve().parents[2]


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", *args], cwd=repo, capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError(
            f"Git {args[0]} failed; resolve repository/remote state before publication"
        )
    return result.stdout.strip()


def snapshot(repo: Path) -> tuple[str, str]:
    branch = git(repo, "symbolic-ref", "--quiet", "--short", "HEAD")
    if branch == "main":
        raise ValueError("Publication validation requires a feature branch")
    if git(repo, "status", "--porcelain=v1", "--untracked-files=all"):
        raise ValueError("Publication validation requires a clean committed worktree")
    return branch, git(repo, "rev-parse", "HEAD")


def require_candidate(repo: Path, expected: tuple[str, str]) -> None:
    if snapshot(repo) != expected:
        raise ValueError("Publication candidate changed; rerun validation for the new candidate")


def refresh_base(repo: Path) -> str:
    git(repo, "fetch", "--no-tags", "origin", "refs/heads/main:refs/remotes/origin/main")
    return git(repo, "rev-parse", "refs/remotes/origin/main^{commit}")


def execution_environment(results: Path) -> dict[str, str]:
    env = {key: value for key, value in os.environ.items() if not key.startswith("TEST_")}
    env["TEST_RESULTS_ROOT"] = str(results)
    return env


def execute(repo: Path, args: list[str], results: Path) -> int:
    return subprocess.run(
        ["mise", "exec", "--", "just", "test", *args],
        cwd=repo,
        env=execution_environment(results),
        check=False,
    ).returncode


def publish(repo: Path, *, full: bool = False) -> Path:
    candidate = snapshot(repo)
    base = refresh_base(repo)
    require_candidate(repo, candidate)
    plan = make_plan(
        repo,
        base,
        candidate[1],
        repo / "tests/impact.yaml",
        repo / "tests/catalog.yaml",
        full=full,
    )
    evidence_root = repo / ".tmp/ci-publication"
    check_path(evidence_root)
    evidence_root.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="run-", dir=evidence_root))
    plan_path = evidence / "ci-plan.json"
    results = evidence / "results"
    results.mkdir()
    write_plan(plan_path, plan)
    print(f"Publication candidate: {candidate[1]}; base: {base}", flush=True)
    print(f"Required groups: {', '.join(plan.groups)}; evidence: {evidence}", flush=True)
    failed = False
    for group in plan.groups:
        require_candidate(repo, candidate)
        if execute(repo, ["ci-group", group, str(plan_path)], results / group):
            failed = True
            break
    # Missing/unstarted groups remain visible to the ordinary reconciler after failure.
    reconciled = execute(
        repo, ["ci-reconcile", str(plan_path), str(results), str(evidence / "gate")], results
    )
    if failed or reconciled:
        raise ValueError(f"Publication validation failed; inspect {evidence}")
    require_candidate(repo, candidate)
    if refresh_base(repo) != base:
        raise ValueError("origin/main advanced during validation; rebase and rerun")
    require_candidate(repo, candidate)
    receipt = {
        "schema_version": 1,
        "result": "passed",
        "branch": candidate[0],
        "head_sha": candidate[1],
        "base_sha": base,
        "plan_id": plan.plan_id,
        "groups": list(plan.groups),
    }
    atomic_write(evidence / "publication.json", json.dumps(receipt, indent=2) + "\n")
    print(f"Publication validation passed: {evidence / 'publication.json'}", flush=True)
    return evidence


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--full", action="store_true", help="escalate to all validation groups")
    args = parser.parse_args()
    try:
        publish(ROOT, full=args.full)
        return 0
    except (OSError, ValueError) as error:
        print(f"ci-publish: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("ci-publish: cancelled; no publication success", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
