"""Shared stdlib-only support for structured resilience phase controllers."""

from __future__ import annotations

import datetime as dt
import json
import os
import signal
import subprocess
import tempfile
from collections.abc import Callable
from pathlib import Path
from typing import Any

Runner = Callable[[list[str]], str]


class ScenarioFailure(RuntimeError):
    """A sanitized scenario failure safe to write to test artifacts."""


class InterruptedRun(ScenarioFailure):
    """The runner was interrupted; Chainsaw cleanup still owns recovery."""


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def run_command(argv: list[str]) -> str:
    result = subprocess.run(
        argv,
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        raise ScenarioFailure(f"{Path(argv[0]).name} exited with status {result.returncode}")
    return result.stdout


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent, text=True)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(value, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def load_state(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError) as error:
        raise ScenarioFailure("scenario state is missing or invalid") from error
    if not isinstance(value, dict):
        raise ScenarioFailure("scenario state must be a JSON object")
    return value


def transition(
    state: dict[str, Any],
    *,
    expected: set[str],
    next_phase: str,
) -> dict[str, Any]:
    current = state.get("phase")
    if current not in expected:
        raise ScenarioFailure(f"invalid phase transition from {current!r} to {next_phase!r}")
    state["phase"] = next_phase
    state["updatedAt"] = utc_now()
    return state


def kubectl_json(
    runner: Runner,
    kubeconfig: str,
    namespace: str | None,
    arguments: list[str],
) -> dict[str, Any]:
    command = ["kubectl", "--kubeconfig", kubeconfig]
    if namespace:
        command.extend(["--namespace", namespace])
    command.extend(arguments)
    try:
        value = json.loads(runner(command))
    except json.JSONDecodeError as error:
        raise ScenarioFailure("kubectl returned invalid JSON") from error
    if not isinstance(value, dict):
        raise ScenarioFailure("kubectl JSON root must be an object")
    return value


def selected_pod(
    runner: Runner,
    kubeconfig: str,
    namespace: str,
    selector: str,
) -> dict[str, Any]:
    listing = kubectl_json(
        runner,
        kubeconfig,
        namespace,
        ["get", "pods", "-l", selector, "-o", "json"],
    )
    active = [
        pod
        for pod in listing.get("items", [])
        if isinstance(pod, dict) and not pod.get("metadata", {}).get("deletionTimestamp")
    ]
    if len(active) != 1:
        raise ScenarioFailure(f"expected one active pod for {selector}, found {len(active)}")
    return active[0]


def named_status(
    pod: dict[str, Any],
    status_group: str,
    name: str,
) -> dict[str, Any]:
    statuses = pod.get("status", {}).get(status_group, [])
    for status in statuses:
        if isinstance(status, dict) and status.get("name") == name:
            return status
    return {}


def write_recovery(run_dir: Path, status: str, reason: str) -> None:
    atomic_write_json(run_dir / "recovery.json", {"status": status, "reason": reason})


def install_interrupt_handlers() -> None:
    def interrupted(signum: int, _frame: object) -> None:
        raise InterruptedRun(f"interrupted by signal {signum}")

    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)


def assert_no_secret_keys(value: Any) -> None:
    forbidden = {"apikey", "api_key", "secret", "password", "token"}

    def walk(item: Any) -> None:
        if isinstance(item, dict):
            for key, child in item.items():
                if str(key).lower() in forbidden:
                    raise ScenarioFailure(f"secret-like key persisted: {key}")
                walk(child)
        elif isinstance(item, list):
            for child in item:
                walk(child)

    walk(value)
