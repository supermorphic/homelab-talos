#!/usr/bin/env python3
"""Run the fixed web-research contract from the current n8n main Pod."""

from __future__ import annotations

import json
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path
from typing import NamedTuple

NAMESPACE = "automation"
DEPLOYMENT = "n8n"
CONTAINER = "n8n-main"
OBSERVER_CONTEXT = "homelab-observer"
DIAGNOSTIC_CONTEXT = "homelab-diagnostic"
MAX_RESULT_BYTES = 16 * 1024
PHASES = (
    "search",
    "static-crawl",
    "authorization-replacement",
    "route-exclusion",
    "javascript-crawl",
    "oversized-response",
    "slow-consumer-retention",
    "prohibited-loopback",
    "concurrency-burst",
    "recovery",
)
RESULT_FIELDS = {"phase", "result", "status", "size", "count", "duration"}


class ContractFailure(Exception):
    """A sanitized contract or preflight failure."""


class Target(NamedTuple):
    pod_name: str
    selector: str


class CommandResult(NamedTuple):
    returncode: int
    stdout: str


def _controller(document: dict, kind: str, uid: str) -> bool:
    return any(
        reference.get("apiVersion") == "apps/v1"
        and reference.get("kind") == kind
        and reference.get("uid") == uid
        and reference.get("controller") is True
        for reference in document.get("metadata", {}).get("ownerReferences", [])
    )


def _ready_container(document: dict) -> bool:
    statuses = document.get("status", {}).get("containerStatuses", [])
    matches = [status for status in statuses if status.get("name") == CONTAINER]
    return (
        document.get("status", {}).get("phase") == "Running"
        and document.get("metadata", {}).get("deletionTimestamp") is None
        and len(matches) == 1
        and matches[0].get("ready") is True
        and matches[0].get("started") is True
    )


def select_target(deployment: dict, replica_sets: dict, pods: dict) -> Target:
    metadata = deployment.get("metadata", {})
    spec = deployment.get("spec", {})
    status = deployment.get("status", {})
    desired = spec.get("replicas")
    generation = metadata.get("generation")
    rolled_out = (
        metadata.get("name") == DEPLOYMENT
        and metadata.get("namespace") == NAMESPACE
        and isinstance(generation, int)
        and status.get("observedGeneration") == generation
        and desired == 1
        and status.get("replicas") == desired
        and status.get("updatedReplicas") == desired
        and status.get("readyReplicas") == desired
        and status.get("availableReplicas") == desired
        and not status.get("unavailableReplicas", 0)
        and any(
            condition.get("type") == "Available" and condition.get("status") == "True"
            for condition in status.get("conditions", [])
        )
    )
    if not rolled_out:
        raise ContractFailure("preflight")

    match_labels = spec.get("selector", {}).get("matchLabels")
    if (
        not isinstance(match_labels, dict)
        or not match_labels
        or spec.get("selector", {}).get("matchExpressions")
        or any(not isinstance(key, str) or not isinstance(value, str) for key, value in match_labels.items())
    ):
        raise ContractFailure("preflight")
    selector = ",".join(f"{key}={match_labels[key]}" for key in sorted(match_labels))

    deployment_uid = metadata.get("uid")
    if not isinstance(deployment_uid, str) or not deployment_uid:
        raise ContractFailure("preflight")
    owned_replica_sets = {
        item.get("metadata", {}).get("uid")
        for item in replica_sets.get("items", [])
        if isinstance(item.get("metadata", {}).get("uid"), str)
        and item.get("metadata", {}).get("uid")
        and _controller(item, "Deployment", deployment_uid)
    }
    candidates = [
        item
        for item in pods.get("items", [])
        if _ready_container(item)
        and any(_controller(item, "ReplicaSet", uid) for uid in owned_replica_sets)
    ]
    if len(candidates) != 1:
        raise ContractFailure("preflight")
    pod_name = candidates[0].get("metadata", {}).get("name")
    if not isinstance(pod_name, str) or not pod_name:
        raise ContractFailure("preflight")
    return Target(pod_name=pod_name, selector=selector)


def exec_command(kubeconfig: Path, pod_name: str) -> list[str]:
    if not pod_name or any(character not in "abcdefghijklmnopqrstuvwxyz0123456789-." for character in pod_name):
        raise ContractFailure("preflight")
    return [
        "kubectl",
        "--kubeconfig",
        str(kubeconfig),
        "--context",
        DIAGNOSTIC_CONTEXT,
        "--namespace",
        NAMESPACE,
        "--request-timeout=9m",
        "exec",
        "-i",
        f"pod/{pod_name}",
        "-c",
        CONTAINER,
        "--",
        "node",
    ]


def read_command(
    kubeconfig: Path,
    resource: str,
    name: str | None = None,
    selector: str | None = None,
) -> list[str]:
    if resource not in {"deployment", "replicasets", "pods"}:
        raise ContractFailure("preflight")
    if name is not None and (resource != "deployment" or name != DEPLOYMENT):
        raise ContractFailure("preflight")
    if selector is not None and (
        resource not in {"replicasets", "pods"}
        or not selector
        or any(character not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.,/_=-" for character in selector)
    ):
        raise ContractFailure("preflight")
    command = [
        "kubectl",
        "--kubeconfig",
        str(kubeconfig),
        "--context",
        OBSERVER_CONTEXT,
        "--namespace",
        NAMESPACE,
        "--request-timeout=20s",
        "get",
        resource,
    ]
    if name is not None:
        command.append(name)
    if selector is not None:
        command.append(f"--selector={selector}")
    command.append("--output=json")
    return command


def confirm_target(initial: Target, current: Target) -> Target:
    if initial != current:
        raise ContractFailure("preflight")
    return current


def context_command(kubeconfig: Path, context: str) -> list[str]:
    if context not in {OBSERVER_CONTEXT, DIAGNOSTIC_CONTEXT}:
        raise ContractFailure("preflight")
    return [
        "kubectl",
        "--kubeconfig",
        str(kubeconfig),
        "config",
        "get-contexts",
        context,
        "--no-headers",
    ]


def _invoke(command: list[str], *, stdin: str | None = None, timeout: int | None = None) -> CommandResult:
    completed = subprocess.run(
        command,
        input=stdin,
        text=True,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=timeout,
    )
    return CommandResult(completed.returncode, completed.stdout)


def _json_result(result: CommandResult) -> dict:
    if result.returncode != 0 or len(result.stdout.encode("utf-8")) > 1024 * 1024:
        raise ContractFailure("preflight")
    try:
        document = json.loads(result.stdout)
    except (json.JSONDecodeError, UnicodeError) as error:
        raise ContractFailure("preflight") from error
    if not isinstance(document, dict):
        raise ContractFailure("preflight")
    return document


def _selector(deployment: dict) -> str:
    selector = deployment.get("spec", {}).get("selector", {})
    labels = selector.get("matchLabels")
    if (
        not isinstance(labels, dict)
        or not labels
        or selector.get("matchExpressions")
        or any(not isinstance(key, str) or not isinstance(value, str) for key, value in labels.items())
    ):
        raise ContractFailure("preflight")
    return ",".join(f"{key}={labels[key]}" for key in sorted(labels))


def collect_target(kubeconfig: Path, invoke: Callable[..., CommandResult]) -> Target:
    deployment = _json_result(
        invoke(read_command(kubeconfig, "deployment", DEPLOYMENT), timeout=30)
    )
    selector = _selector(deployment)
    replica_sets = _json_result(
        invoke(read_command(kubeconfig, "replicasets", selector=selector), timeout=30)
    )
    pods = _json_result(invoke(read_command(kubeconfig, "pods", selector=selector), timeout=30))
    return select_target(deployment, replica_sets, pods)


def execute(
    kubeconfig: Path,
    node_program: str,
    *,
    invoke: Callable[..., CommandResult] = _invoke,
) -> list[dict]:
    for context in (OBSERVER_CONTEXT, DIAGNOSTIC_CONTEXT):
        if invoke(context_command(kubeconfig, context), timeout=20).returncode != 0:
            raise ContractFailure("preflight")
    initial = collect_target(kubeconfig, invoke)
    current = collect_target(kubeconfig, invoke)
    target = confirm_target(initial, current)
    result = invoke(
        exec_command(kubeconfig, target.pod_name),
        stdin=node_program,
        timeout=540,
    )
    records = sanitize_results(result.stdout)
    passed = all(record["result"] == "pass" for record in records)
    if result.returncode not in {0, 1} or (result.returncode == 0) != passed:
        raise ContractFailure("result-output")
    return records


def failure_record(phase: str) -> dict:
    return {
        "phase": phase,
        "result": "fail",
        "status": 0,
        "size": 0,
        "count": 0,
        "duration": 0,
    }


def main(argv: list[str] | None = None) -> int:
    arguments = sys.argv[1:] if argv is None else argv
    if len(arguments) != 1:
        print(json.dumps(failure_record("runner"), separators=(",", ":")))
        return 2
    try:
        kubeconfig = Path(arguments[0])
        if not kubeconfig.is_file():
            raise ContractFailure("preflight")
        program_path = Path(__file__).with_name("live_contract_node.js")
        node_program = program_path.read_text(encoding="utf-8")
        records = execute(kubeconfig, node_program)
    except Exception:  # noqa: BLE001 - never expose kubectl or response details.
        print(json.dumps(failure_record("runner"), separators=(",", ":")))
        return 1
    for record in records:
        print(json.dumps(record, separators=(",", ":")))
    return 0 if all(record["result"] == "pass" for record in records) else 1


def sanitize_results(output: str) -> list[dict]:
    if len(output.encode("utf-8")) > MAX_RESULT_BYTES:
        raise ContractFailure("result-output")
    try:
        records = [json.loads(line) for line in output.splitlines()]
    except (json.JSONDecodeError, UnicodeError) as error:
        raise ContractFailure("result-output") from error
    if len(records) != len(PHASES):
        raise ContractFailure("result-output")
    for expected_phase, record in zip(PHASES, records, strict=True):
        if not isinstance(record, dict) or set(record) != RESULT_FIELDS:
            raise ContractFailure("result-output")
        if record["phase"] != expected_phase or record["result"] not in {"pass", "fail"}:
            raise ContractFailure("result-output")
        if not all(
            isinstance(record[field], int) and not isinstance(record[field], bool)
            for field in ("status", "size", "count", "duration")
        ):
            raise ContractFailure("result-output")
        if not 0 <= record["status"] <= 599 or min(
            record["size"], record["count"], record["duration"]
        ) < 0:
            raise ContractFailure("result-output")
    return records


if __name__ == "__main__":
    raise SystemExit(main())
