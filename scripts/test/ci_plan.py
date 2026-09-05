#!/usr/bin/env python3
"""Deterministic, fail-closed CI impact planning for exact ancestor/head commits."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from collections.abc import Mapping
from dataclasses import asdict, dataclass
from pathlib import Path, PurePosixPath
from types import MappingProxyType

import yaml

GROUPS = ("core", "observability", "automation", "ci-framework")
EXECUTIONS = dict(zip(GROUPS, ("ci-core", "ci-observability", "ci-automation", "ci-framework")))


@dataclass(frozen=True)
class Change:
    status: str
    old_path: str | None
    new_path: str | None


@dataclass(frozen=True)
class ImpactConfig:
    group_order: tuple[str, ...]
    executions: Mapping[str, str]
    full_patterns: tuple[str, ...]
    conditional_patterns: Mapping[str, tuple[str, ...]]
    core_patterns: tuple[str, ...]


@dataclass(frozen=True)
class Plan:
    schema_version: int
    base_sha: str
    head_sha: str
    plan_id: str
    mode: str
    groups: tuple[str, ...]
    reasons: tuple[dict[str, object], ...]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def read_yaml(path: Path) -> dict:
    text = path.read_text()
    # safe_load accepts duplicate keys. Reject them before constructing any config.
    root = yaml.compose(text, Loader=yaml.SafeLoader)
    visited = set()

    def check(node):
        if id(node) in visited:
            return
        visited.add(id(node))
        if isinstance(node, yaml.MappingNode):
            keys = set()
            for key, value in node.value:
                require(isinstance(key, yaml.ScalarNode), "YAML keys must be scalars")
                require(key.value not in keys, f"duplicate YAML key: {key.value}")
                keys.add(key.value)
                check(value)
        elif isinstance(node, yaml.SequenceNode):
            for value in node.value:
                check(value)

    check(root)
    document = yaml.safe_load(text)
    require(isinstance(document, dict), f"{path.name} must contain a mapping")
    return document


def patterns(value: object, name: str) -> tuple[str, ...]:
    require(isinstance(value, list), f"{name} must be a list of globs")
    for pattern in value:
        require(
            isinstance(pattern, str) and bool(pattern), f"{name} globs must be nonempty strings"
        )
        require(
            not pattern.startswith("/") and ".." not in pattern.split("/") and "\0" not in pattern,
            f"{name} globs must be repository-relative",
        )
        PurePosixPath("probe").full_match(pattern)
    return tuple(value)


def load_impact(path: Path, catalog_path: Path) -> ImpactConfig:
    config = read_yaml(path)
    require(
        set(config)
        == {
            "schema_version",
            "groups",
            "full_groups",
            "full_paths",
            "conditional_paths",
            "core_paths",
        },
        "impact fields are invalid",
    )
    require(
        type(config["schema_version"]) is int and config["schema_version"] == 1,
        "impact schema_version must be 1",
    )
    groups = config["groups"]
    require(
        isinstance(groups, dict) and set(groups) == set(GROUPS),
        "impact groups must contain core, observability, automation, ci-framework exactly once",
    )
    require(
        config["full_groups"] == list(GROUPS),
        "full_groups must list all groups in canonical order",
    )
    catalog = read_yaml(catalog_path)
    executions = catalog.get("executions")
    require(
        isinstance(executions, dict) and set(executions) == {"ci", *EXECUTIONS.values()},
        "catalog executions must contain the closed CI execution set",
    )
    for group in GROUPS:
        entry = groups[group]
        require(
            isinstance(entry, dict) and set(entry) == {"execution", "always"},
            f"invalid impact group definition: {group}",
        )
        require(
            entry["execution"] == EXECUTIONS[group],
            f"invalid catalog execution for group: {group}",
        )
        require(entry["always"] is (group == "core"), f"only core must always run: {group}")
        require(
            isinstance(executions[EXECUTIONS[group]], list)
            and bool(executions[EXECUTIONS[group]]),
            f"catalog execution is empty: {group}",
        )
    conditional = config["conditional_paths"]
    require(
        isinstance(conditional, dict) and set(conditional) == {"observability", "automation"},
        "conditional_paths must map observability and automation",
    )
    return ImpactConfig(
        GROUPS,
        MappingProxyType(EXECUTIONS.copy()),
        patterns(config["full_paths"], "full_paths"),
        MappingProxyType(
            {
                group: patterns(conditional[group], group)
                for group in ("observability", "automation")
            }
        ),
        patterns(config["core_paths"], "core_paths"),
    )


def change_paths(change: Change) -> tuple[str, ...]:
    status = change.status
    require(isinstance(status, str), "change status must be a string")
    if status in ("A", "M"):
        require(
            change.old_path is None and change.new_path is not None,
            f"{status} requires only a new path",
        )
        paths = (change.new_path,)
    elif status == "D":
        require(
            change.old_path is not None and change.new_path is None, "D requires only an old path"
        )
        paths = (change.old_path,)
    elif re.fullmatch(r"[RC](?:[0-9]{1,3})?", status):
        require(len(status) == 1 or int(status[1:]) <= 100, "rename/copy similarity exceeds 100")
        require(
            change.old_path is not None and change.new_path is not None,
            "rename/copy requires old and new paths",
        )
        paths = (change.old_path, change.new_path)
    else:
        raise ValueError(f"unsupported change status: {status}")
    for path in paths:
        require(
            isinstance(path, str)
            and bool(path)
            and not path.startswith("/")
            and ".." not in path.split("/")
            and "\0" not in path,
            "change paths must be nonempty repository-relative paths",
        )
    return paths


def select(
    changes: list[Change], impact: ImpactConfig, *, full: bool
) -> tuple[tuple[str, ...], tuple[dict[str, object], ...]]:
    selected = {"core"}
    reasons = []
    for change in changes:
        for path in change_paths(change):
            candidate = PurePosixPath(path)
            if any(candidate.full_match(pattern) for pattern in impact.full_patterns):
                reason, groups = "full", impact.group_order
            else:
                conditional = tuple(
                    group
                    for group, globs in impact.conditional_patterns.items()
                    if any(candidate.full_match(pattern) for pattern in globs)
                )
                if conditional:
                    reason, groups = "conditional", ("core", *conditional)
                elif any(candidate.full_match(pattern) for pattern in impact.core_patterns):
                    reason, groups = "core", ("core",)
                else:
                    reason, groups = "unmatched", impact.group_order
            selected.update(groups)
            reasons.append({"path": path, "reason": reason, "groups": list(groups)})
    if full:
        selected.update(impact.group_order)
        reasons.append({"reason": "requested-full", "groups": list(impact.group_order)})
    return tuple(group for group in impact.group_order if group in selected), tuple(reasons)


def classify(changes: list[Change], impact: ImpactConfig, *, full: bool) -> tuple[str, ...]:
    return select(changes, impact, full=full)[0]


def check_sha(value: object) -> None:
    require(
        isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value) is not None,
        "revision must be a full 40-character lowercase commit SHA",
    )


def git(repo: Path, *args: str) -> bytes:
    result = subprocess.run(["git", *args], cwd=repo, capture_output=True, check=False)
    require(result.returncode == 0, f"git {args[0]} failed for the requested commits")
    return result.stdout


def parse_changes(data: bytes) -> list[Change]:
    require(not data or data.endswith(b"\0"), "Git diff must be NUL terminated")
    fields = [os.fsdecode(field) for field in data.split(b"\0")[:-1]]
    changes = []
    index = 0
    while index < len(fields):
        status = fields[index]
        index += 1
        count = 2 if status.startswith(("R", "C")) else 1
        require(index + count <= len(fields), "Git diff has an incomplete change")
        paths = fields[index : index + count]
        index += count
        if count == 2:
            change = Change(status, paths[0], paths[1])
        elif status == "D":
            change = Change(status, paths[0], None)
        else:
            change = Change(status, None, paths[0])
        change_paths(change)
        changes.append(change)
    return changes


def canonical(payload: object) -> str:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


def plan_digest(payload: dict) -> str:
    return hashlib.sha256(
        canonical({key: value for key, value in payload.items() if key != "plan_id"}).encode()
    ).hexdigest()


def make_plan(
    repo: Path, base: str, head: str, impact_path: Path, catalog_path: Path, *, full: bool = False
) -> Plan:
    check_sha(base)
    check_sha(head)
    impact = load_impact(impact_path, catalog_path)
    for sha in (base, head):
        require(
            git(repo, "cat-file", "-t", sha).strip() == b"commit", "revision must name a commit"
        )
    ancestry = subprocess.run(
        ["git", "merge-base", "--is-ancestor", base, head],
        cwd=repo,
        capture_output=True,
        check=False,
    )
    require(ancestry.returncode == 0, "base must be an ancestor of head")
    changes = parse_changes(
        git(repo, "diff", "--name-status", "-z", "--find-renames", "--find-copies", base, head)
    )
    groups, reasons = select(changes, impact, full=full)
    payload = {
        "schema_version": 1,
        "base_sha": base,
        "head_sha": head,
        "mode": "full" if groups == GROUPS else "selective",
        "groups": groups,
        "reasons": reasons,
    }
    return Plan(**payload, plan_id=plan_digest(payload))


def unique_json_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON field: {key}")
        result[key] = value
    return result


def read_plan(path: Path) -> Plan:
    payload = json.loads(path.read_text(), object_pairs_hook=unique_json_object)
    require(
        isinstance(payload, dict) and set(payload) == set(Plan.__dataclass_fields__),
        "plan fields are invalid",
    )
    require(
        type(payload["schema_version"]) is int and payload["schema_version"] == 1,
        "plan schema_version must be 1",
    )
    check_sha(payload["base_sha"])
    check_sha(payload["head_sha"])
    groups = payload["groups"]
    require(
        isinstance(groups, list) and all(isinstance(group, str) for group in groups),
        "plan groups must be a list of group names",
    )
    require(
        "core" in groups and groups == [group for group in GROUPS if group in groups],
        "plan groups must include core and be unique, known, and canonically ordered",
    )
    require(
        "ci-framework" not in groups or groups == list(GROUPS), "ci-framework requires full groups"
    )
    require(
        payload["mode"] == ("full" if groups == list(GROUPS) else "selective"),
        "plan mode does not match selected groups",
    )
    reasons = payload["reasons"]
    require(isinstance(reasons, list), "plan reasons must be a list")
    for reason in reasons:
        require(isinstance(reason, dict), "plan reason must be an object")
        kind = reason.get("reason")
        require(
            kind in ("core", "conditional", "full", "unmatched", "requested-full"),
            "plan selection reason is invalid",
        )
        require(
            set(reason)
            == (
                {"reason", "groups"} if kind == "requested-full" else {"path", "reason", "groups"}
            ),
            "plan reason fields are invalid",
        )
        if kind != "requested-full":
            change_paths(Change("M", None, reason["path"]))
        wanted = reason["groups"]
        require(
            isinstance(wanted, list)
            and "core" in wanted
            and wanted == [group for group in GROUPS if group in wanted]
            and all(group in groups for group in wanted),
            "plan reason groups are invalid",
        )
        if kind in ("full", "unmatched", "requested-full"):
            require(wanted == list(GROUPS), "full reason requires every group")
        elif kind == "core":
            require(wanted == ["core"], "core reason must select only core")
        else:
            require(
                len(wanted) > 1 and "ci-framework" not in wanted,
                "conditional reason must select conditional groups",
            )
    require(
        payload["plan_id"] == plan_digest(payload), "plan_id does not match the canonical payload"
    )
    return Plan(**{**payload, "groups": tuple(groups), "reasons": tuple(reasons)})


def write_plan(path: Path, plan: Plan) -> None:
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False
        ) as stream:
            temporary = Path(stream.name)
            stream.write(canonical(asdict(plan)) + "\n")
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError(message)


def main() -> int:
    try:
        parser = ArgumentParser(description=__doc__)
        commands = parser.add_subparsers(dest="command", required=True)
        plan = commands.add_parser("plan")
        for name in ("base", "head", "impact", "catalog", "output"):
            plan.add_argument(f"--{name}", required=True)
        plan.add_argument("--full", action="store_true")
        for command in ("groups", "validate"):
            reader = commands.add_parser(command)
            reader.add_argument("--plan", required=True, type=Path)
            if command == "validate":
                reader.add_argument("--head", required=True)
        args = parser.parse_args()
        if args.command == "plan":
            result = make_plan(
                Path.cwd(),
                args.base,
                args.head,
                Path(args.impact),
                Path(args.catalog),
                full=args.full,
            )
            write_plan(Path(args.output), result)
        else:
            result = read_plan(args.plan)
            if args.command == "groups":
                print(canonical(result.groups))
            else:
                check_sha(args.head)
                require(
                    result.head_sha == args.head, "plan head does not match the requested head"
                )
        return 0
    except (ValueError, OSError, yaml.YAMLError, RecursionError) as error:
        print("ci-plan: " + " ".join(str(error).splitlines()), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
