"""Decision-record lifecycle model and validation CLI.

An Accepted decision record is superseded, never revised. This module compares the
records on the current branch against their state at the merge base with a base ref,
and reports every transition that the accepted lifecycle does not permit.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

DECISIONS_DIR = "docs/decisions"

#: Records written before this CLI existed. Each uses the pre-enforcement status header
#: and is Accepted only while its body stays byte-identical. The only edit permitted is
#: replacement of that header by the canonical superseded status line. The legacy syntax
#: is invalid at every other path and in every newly added record.
LEGACY_ACCEPTED_PATHS = (
    "docs/decisions/2026-08-01-tautulli.md",
    "docs/decisions/2026-08-02-plex-relay-sonos-design.md",
    "docs/decisions/2026-08-03-agent-rules-runtime-contract-amendment.md",
)

RECORD_NAME = re.compile(r"^\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*\.md$")
CANONICAL_STATUS = re.compile(
    r"^-\s+\*\*Status:\s+(?:(?P<simple>Draft|Accepted)|Superseded by (?P<target>[^*]+?))\.\*\*"
)
LEGACY_STATUS = re.compile(r"^Status:\s+Accepted\s+\(\d{4}-\d{2}-\d{2}\)\s*$")


class RecordError(Exception):
    """A file under `docs/decisions/` is not a well-formed decision record."""


class BaseRefError(Exception):
    """The requested base ref is missing, so no comparison is possible."""


@dataclass(frozen=True)
class DecisionRecord:
    path: str
    status: str
    superseded_by: str | None
    lines: tuple[str, ...]
    status_line: int
    legacy: bool

    @property
    def frozen_body(self) -> str:
        """The record with its status line removed, for byte-exact body comparison."""
        remaining = list(self.lines)
        del remaining[self.status_line]
        return "\n".join(remaining)


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


def parse_record(path: Path, repo_relative: str) -> DecisionRecord:
    return parse_text(path.read_text(encoding="utf-8"), repo_relative)


def parse_text(text: str, repo_relative: str) -> DecisionRecord:
    lines = text.splitlines()
    found: list[tuple[int, str, str | None, bool]] = []
    for index, line in enumerate(lines):
        canonical = CANONICAL_STATUS.match(line)
        if canonical:
            target = canonical.group("target")
            status = canonical.group("simple") or "Superseded"
            found.append((index, status, target.strip() if target else None, False))
            continue
        if LEGACY_STATUS.match(line):
            if repo_relative not in LEGACY_ACCEPTED_PATHS:
                raise RecordError(
                    f"{repo_relative}: legacy status syntax is only valid in an imported "
                    "pre-enforcement record"
                )
            found.append((index, "Accepted", None, True))

    if not found:
        raise RecordError(f"{repo_relative}: no canonical status line found")
    if len(found) > 1:
        raise RecordError(f"{repo_relative}: expected exactly one status line")

    index, status, target, legacy = found[0]
    return DecisionRecord(
        path=repo_relative,
        status=status,
        superseded_by=target,
        lines=tuple(lines),
        status_line=index,
        legacy=legacy,
    )


def validate_transition(
    base: DecisionRecord | None,
    current: DecisionRecord | None,
    current_names: set[str],
) -> list[str]:
    if base is None:
        return []

    if current is None:
        if base.status == "Draft":
            return []
        return [f"{base.path}: an accepted record was deleted; supersede it instead"]

    if base.status == "Draft":
        return []

    if base.frozen_body != current.frozen_body:
        return [f"{base.path}: an accepted record was revised; supersede it instead"]

    if current.status == base.status and current.superseded_by == base.superseded_by:
        return []

    if base.status != "Accepted" or current.status != "Superseded":
        return [
            (
                f"{base.path}: {base.status} may not become {current.status}; "
                "the only permitted transition is Accepted to Superseded"
            )
        ]

    target = current.superseded_by or ""
    if target not in current_names:
        return [f"{base.path}: superseded by {target}, which is not a record in this branch"]
    return []


def _merge_base(repo: Path, base_ref: str) -> str:
    try:
        return _git(repo, "merge-base", base_ref, "HEAD").strip()
    except subprocess.CalledProcessError as error:
        raise BaseRefError(
            f"cannot resolve base ref {base_ref!r}: {error.stderr.strip()}"
        ) from error


def _is_record_path(repo_relative: str) -> bool:
    path = Path(repo_relative)
    return path.parent.as_posix() == DECISIONS_DIR and bool(RECORD_NAME.match(path.name))


def changed_records(repo: Path, base_ref: str) -> list[str]:
    base = _merge_base(repo, base_ref)
    output = _git(repo, "diff", "--name-status", "--no-renames", base, "--", DECISIONS_DIR)
    changed = []
    for line in output.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and _is_record_path(parts[1]):
            changed.append(parts[1])
    return sorted(set(changed))


def current_record_names(repo: Path) -> set[str]:
    directory = repo / DECISIONS_DIR
    if not directory.is_dir():
        return set()
    return {entry.name for entry in directory.iterdir() if RECORD_NAME.match(entry.name)}


def _base_record(repo: Path, base: str, repo_relative: str) -> DecisionRecord | None:
    try:
        text = _git(repo, "show", f"{base}:{repo_relative}")
    except subprocess.CalledProcessError:
        return None
    return parse_text(text, repo_relative)


def validate(repo: Path, base_ref: str) -> list[str]:
    base = _merge_base(repo, base_ref)
    names = current_record_names(repo)
    violations: list[str] = []

    for repo_relative in changed_records(repo, base_ref):
        try:
            base_record = _base_record(repo, base, repo_relative)
        except RecordError as error:
            violations.append(str(error))
            continue

        path = repo / repo_relative
        current_record: DecisionRecord | None = None
        if path.is_file():
            try:
                current_record = parse_record(path, repo_relative)
            except RecordError as error:
                violations.append(str(error))
                continue

        violations.extend(validate_transition(base_record, current_record, names))

    return violations


def parse_args(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("validate",))
    parser.add_argument("--base", default="origin/main")
    parser.add_argument("--repo", default=".")
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    options = parse_args(list(sys.argv[1:] if arguments is None else arguments))
    repo = Path(options.repo).resolve()

    try:
        violations = validate(repo, options.base)
    except BaseRefError as error:
        print(f"decision lifecycle: {error}", file=sys.stderr)
        return 2

    if violations:
        print("decision record lifecycle violations:", file=sys.stderr)
        for violation in violations:
            print(f"  {violation}", file=sys.stderr)
        return 1

    print("Decision record lifecycle checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
