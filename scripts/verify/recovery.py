#!/usr/bin/env python3
"""Read-only platform verifier for guarded Talos node recovery."""

from __future__ import annotations

import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tarfile
import time
import uuid
from pathlib import Path, PurePosixPath
from typing import NamedTuple


ANNOTATION = "homelab.supermorphic.com/node-lifecycle"
REQUEST_KEYS = {
    "schemaVersion",
    "requestId",
    "mode",
    "node",
    "sourceRevision",
    "apiServer",
    "nodes",
    "talosEndpoints",
    "credentials",
    "expectedContainment",
    "timeoutSeconds",
}
CREDENTIAL_KEYS = {"kubeconfig", "kubeContext", "talosconfig", "talosContext"}
CONTAINMENT_KEYS = {"node", "record"}
NAME_RE = re.compile(r"^[a-z0-9](?:[a-z0-9.-]{0,61}[a-z0-9])?$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
CHART_ENTRY_KEYS = {"file", "chartName", "version", "sha256"}
CHART_ENV = {
    "cilium": "RECOVERY_CILIUM_CHART",
    "cert-manager": "RECOVERY_CERT_MANAGER_CHART",
    "metallb": "RECOVERY_METALLB_CHART",
    "envoy-gateway": "RECOVERY_ENVOY_GATEWAY_CHART",
    "external-dns": "RECOVERY_EXTERNAL_DNS_CHART",
}


class ContractError(ValueError):
    """The request, desired source, or observed state violates the contract."""


class NodeState(NamedTuple):
    name: str
    ready: bool
    unschedulable: bool
    record: str


def _object_no_duplicates(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_request_text(text: str) -> dict:
    try:
        value = json.loads(text, object_pairs_hook=_object_no_duplicates)
    except (json.JSONDecodeError, ContractError) as exc:
        raise ContractError(f"invalid request JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ContractError("request must be a JSON object")
    return value


def _exact_keys(value: dict, expected: set[str], label: str) -> None:
    actual = set(value)
    if actual != expected:
        raise ContractError(
            f"{label} keys differ: missing={sorted(expected - actual)}, "
            f"unknown={sorted(actual - expected)}"
        )


def _required_string(value: object, label: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ContractError(f"{label} must be a non-empty string")
    return value


def _load_desired_source(source_dir: Path) -> tuple[str, dict[str, str], list[str]]:
    config = source_dir / "talos/talconfig.yaml"
    if not config.is_file():
        raise ContractError("selected source has no talos/talconfig.yaml")
    try:
        rendered = subprocess.run(
            ["yq", "-o=json", ".", str(config)],
            cwd=source_dir,
            text=True,
            capture_output=True,
            check=True,
        ).stdout
        data = json.loads(rendered)
        endpoint = data["endpoint"]
        rows = data["nodes"]
        nodes = {
            row["hostname"]: row["ipAddress"]
            for row in rows
            if row.get("controlPlane") is True
        }
    except (subprocess.CalledProcessError, KeyError, TypeError, json.JSONDecodeError) as exc:
        raise ContractError("selected Talos desired source is malformed") from exc
    if len(rows) != 3 or len(nodes) != 3:
        raise ContractError("selected source must define exactly three control-plane nodes")
    return endpoint, nodes, list(nodes.values())


def _load_yaml_object(path: Path, label: str) -> dict:
    try:
        rendered = subprocess.run(
            ["yq", "-o=json", ".", str(path)],
            text=True,
            capture_output=True,
            check=True,
        ).stdout
        value = json.loads(rendered)
    except (subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        raise ContractError(f"{label} is malformed") from exc
    if not isinstance(value, dict):
        raise ContractError(f"{label} must be an object")
    return value


def _yaml_value(source_dir: Path, relative: str, expression: str) -> str:
    path = source_dir / relative
    try:
        value = subprocess.run(
            ["yq", "-r", expression, str(path)],
            cwd=source_dir,
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as exc:
        raise ContractError(f"cannot read chart version from {relative}") from exc
    if not value or value == "null":
        raise ContractError(f"chart version is absent from {relative}")
    return value


def expected_charts(source_dir: Path) -> dict[str, tuple[str, str]]:
    return {
        "cilium": (
            "cilium",
            _yaml_value(source_dir, "kubernetes/apps/kube-system/cilium/app/ocirepository.yaml", ".spec.ref.tag"),
        ),
        "cert-manager": (
            "cert-manager",
            _yaml_value(source_dir, "kubernetes/apps/security/cert-manager/app/ocirepository.yaml", ".spec.ref.tag"),
        ),
        "metallb": (
            "metallb",
            _yaml_value(source_dir, "kubernetes/apps/networking/metallb/app/helmrelease.yaml", ".spec.chart.spec.version"),
        ),
        "envoy-gateway": (
            "gateway-helm",
            _yaml_value(source_dir, "kubernetes/apps/networking/envoy-gateway/app/ocirepository.yaml", ".spec.ref.tag"),
        ),
        "external-dns": (
            "external-dns",
            _yaml_value(source_dir, "kubernetes/apps/networking/external-dns/app/helmrelease.yaml", ".spec.chart.spec.version"),
        ),
    }


def _archive_identity(path: Path) -> tuple[str, str]:
    try:
        with tarfile.open(path, "r:gz") as bundle:
            members = bundle.getmembers()
            for member in members:
                member_path = PurePosixPath(member.name)
                if member_path.is_absolute() or ".." in member_path.parts:
                    raise ContractError(f"chart archive {path.name} contains an unsafe path")
            members = [
                member
                for member in members
                if member.isfile()
                and len(PurePosixPath(member.name).parts) == 2
                and PurePosixPath(member.name).name == "Chart.yaml"
            ]
            if len(members) != 1:
                raise ContractError(f"chart archive {path.name} has no unique root Chart.yaml")
            stream = bundle.extractfile(members[0])
            if stream is None:
                raise ContractError(f"cannot read Chart.yaml from {path.name}")
            text = stream.read().decode("utf-8")
    except (tarfile.TarError, UnicodeDecodeError, OSError) as exc:
        raise ContractError(f"chart archive {path.name} is malformed") from exc
    fields: dict[str, str] = {}
    for line in text.splitlines():
        match = re.match(r"^(name|version):\s*['\"]?([^'\"#\s]+)", line)
        if match:
            fields[match.group(1)] = match.group(2)
    if set(fields) != {"name", "version"}:
        raise ContractError(f"chart archive {path.name} lacks name/version")
    return fields["name"], fields["version"]


def validate_chart_cache(request: dict, source_dir: Path, cache_dir: Path) -> dict[str, Path]:
    if not cache_dir.is_absolute() or cache_dir.is_symlink() or not cache_dir.is_dir():
        raise ContractError("RECOVERY_HELM_CACHE must be an absolute non-symlink directory")
    manifest_path = cache_dir / "manifest.json"
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ContractError("recovery Helm cache manifest is missing")
    manifest = load_request_text(manifest_path.read_text(encoding="utf-8"))
    _exact_keys(manifest, {"schemaVersion", "sourceRevision", "charts"}, "chart cache manifest")
    if type(manifest["schemaVersion"]) is not int or manifest["schemaVersion"] != 1:
        raise ContractError("chart cache schemaVersion must be integer 1")
    if manifest["sourceRevision"] != request["sourceRevision"]:
        raise ContractError("chart cache source revision differs from request")
    expected = expected_charts(source_dir)
    charts = manifest["charts"]
    if not isinstance(charts, dict) or set(charts) != set(expected):
        raise ContractError("chart cache entries differ from required charts")
    resolved: dict[str, Path] = {}
    for logical, (expected_name, expected_version) in expected.items():
        entry = charts[logical]
        if not isinstance(entry, dict):
            raise ContractError(f"chart cache entry {logical} must be an object")
        _exact_keys(entry, CHART_ENTRY_KEYS, f"chart cache entry {logical}")
        filename = _required_string(entry["file"], f"chart cache entry {logical}.file")
        if Path(filename).name != filename:
            raise ContractError(f"chart cache entry {logical} file must be a basename")
        archive = cache_dir / filename
        if archive.is_symlink() or not archive.is_file():
            raise ContractError(f"chart cache archive {logical} is missing")
        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        if entry["sha256"] != digest:
            raise ContractError(f"chart cache archive {logical} digest differs from manifest")
        if entry["chartName"] != expected_name or entry["version"] != expected_version:
            raise ContractError(f"chart cache entry {logical} differs from desired source")
        if _archive_identity(archive) != (expected_name, expected_version):
            raise ContractError(f"chart cache archive {logical} identity differs from desired source")
        resolved[logical] = archive
    return resolved


def _valid_schema_one_record(record: dict) -> bool:
    if type(record.get("schemaVersion")) is not int or record["schemaVersion"] != 1:
        return False
    if set(record) == {"schemaVersion", "kind"}:
        return record["kind"] in {"reboot", "abrupt-loss"}
    if set(record) != {"schemaVersion", "kind", "longhorn"} or record["kind"] != "maintenance":
        return False
    longhorn = record["longhorn"]
    if not isinstance(longhorn, dict) or set(longhorn) != {"allowScheduling", "evictionRequested"}:
        return False
    allow = longhorn["allowScheduling"]
    eviction = longhorn["evictionRequested"]
    if not isinstance(allow, dict) or set(allow) != {"before", "during"}:
        return False
    if not isinstance(eviction, dict) or set(eviction) != {"before", "during"}:
        return False
    if any(type(value) is not bool for value in (*allow.values(), *eviction.values())):
        return False
    return allow["during"] is False and eviction["during"] is True


def validate_request(value: dict, source_dir: Path) -> dict:
    _exact_keys(value, REQUEST_KEYS, "request")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1:
        raise ContractError("schemaVersion must be integer 1")
    mode = _required_string(value["mode"], "mode")
    if mode not in {"prepare", "baseline", "recovery"}:
        raise ContractError("unsupported mode")
    try:
        uuid.UUID(_required_string(value["requestId"], "requestId"))
    except ValueError as exc:
        raise ContractError("requestId must be a UUID") from exc
    node = _required_string(value["node"], "node")
    if not NAME_RE.fullmatch(node):
        raise ContractError("node has invalid syntax")
    revision = _required_string(value["sourceRevision"], "sourceRevision")
    if not SHA_RE.fullmatch(revision):
        raise ContractError("sourceRevision must be a full lowercase commit ID")
    timeout = value["timeoutSeconds"]
    if type(timeout) is not int or not 1 <= timeout <= 3600:
        raise ContractError("timeoutSeconds must be an integer in 1..3600")

    nodes = value["nodes"]
    if not isinstance(nodes, dict) or len(nodes) != 3:
        raise ContractError("nodes must contain exactly three entries")
    for name, address in nodes.items():
        if not isinstance(name, str) or not NAME_RE.fullmatch(name):
            raise ContractError("nodes contains an invalid name")
        _required_string(address, f"nodes[{name}]")
    if len(set(nodes.values())) != 3 or node not in nodes:
        raise ContractError("node names and addresses must be unique and include node")
    endpoints = value["talosEndpoints"]
    if (
        not isinstance(endpoints, list)
        or len(endpoints) != 3
        or any(not isinstance(item, str) or not item for item in endpoints)
        or len(set(endpoints)) != 3
    ):
        raise ContractError("talosEndpoints must contain three unique addresses")

    credentials = value["credentials"]
    if not isinstance(credentials, dict):
        raise ContractError("credentials must be an object")
    _exact_keys(credentials, CREDENTIAL_KEYS, "credentials")
    for key in CREDENTIAL_KEYS:
        field = _required_string(credentials[key], f"credentials.{key}")
        if key.endswith("config"):
            path = Path(field)
            if not path.is_absolute() or not path.is_file():
                raise ContractError(f"credentials.{key} must be an absolute regular file")
    kube_data = _load_yaml_object(Path(credentials["kubeconfig"]), "kubeconfig")
    kube_contexts = {
        item.get("name")
        for item in kube_data.get("contexts", [])
        if isinstance(item, dict)
    }
    if credentials["kubeContext"] not in kube_contexts:
        raise ContractError("explicit Kubernetes context is absent from kubeconfig")
    talos_data = _load_yaml_object(Path(credentials["talosconfig"]), "talosconfig")
    talos_contexts = talos_data.get("contexts")
    if not isinstance(talos_contexts, dict) or credentials["talosContext"] not in talos_contexts:
        raise ContractError("explicit Talos context is absent from talosconfig")

    containment = value["expectedContainment"]
    if mode == "recovery":
        if not isinstance(containment, dict):
            raise ContractError("recovery requires expectedContainment")
        _exact_keys(containment, CONTAINMENT_KEYS, "expectedContainment")
        if containment["node"] != node:
            raise ContractError("containment node must match request node")
        record_text = _required_string(containment["record"], "expectedContainment.record")
        record = load_request_text(record_text)
        if not _valid_schema_one_record(record):
            raise ContractError("expectedContainment.record is not exact schema 1")
    elif containment is not None:
        raise ContractError("prepare and baseline require null expectedContainment")

    try:
        head = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=source_dir,
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as exc:
        raise ContractError("selected source is not a Git checkout") from exc
    if head != revision:
        raise ContractError("sourceRevision does not match selected source HEAD")
    endpoint, desired_nodes, desired_endpoints = _load_desired_source(source_dir)
    if value["apiServer"] != endpoint or nodes != desired_nodes:
        raise ContractError("request endpoint or nodes differ from selected source")
    if endpoints != desired_endpoints:
        raise ContractError("talosEndpoints differ from selected source order")
    return value


def validate_node_states(request: dict, states: list[NodeState]) -> None:
    expected = set(request["nodes"])
    actual = {state.name for state in states}
    if actual != expected or len(states) != len(expected):
        raise ContractError("live node set differs from selected source")
    containment = request["expectedContainment"]
    for state in states:
        if not state.ready:
            raise ContractError(f"node {state.name} is not Ready")
        if request["mode"] in {"prepare", "baseline"}:
            if state.unschedulable or state.record:
                raise ContractError(f"node {state.name} has unexpected containment")
        elif state.name == containment["node"]:
            if not state.unschedulable or state.record != containment["record"]:
                raise ContractError("recovery target containment differs from request")
        elif state.unschedulable or state.record:
            raise ContractError(f"node {state.name} has unexpected containment")


def _response(request: dict, live: bool) -> dict:
    return {
        "schemaVersion": 1,
        "requestId": request["requestId"],
        "mode": request["mode"],
        "node": request["node"],
        "sourceRevision": request["sourceRevision"],
        "kubeContext": request["credentials"]["kubeContext"],
        "talosContext": request["credentials"]["talosContext"],
        "checks": {
            "source": "passed",
            "cilium": "passed" if live else "not-run",
            "foundation": "passed" if live else "not-run",
        },
    }


def run_supervised(
    command: list[str], *, cwd: Path, env: dict[str, str], timeout: int, capture: bool = False
) -> str:
    process = subprocess.Popen(
        command,
        cwd=cwd,
        env=env,
        stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        raise
    if process.returncode != 0:
        safe_lines = [
            line
            for line in (stderr or "").splitlines()
            if line.startswith("recovery verification:")
        ]
        for line in safe_lines[-5:]:
            print(line, file=sys.stderr)
        raise subprocess.CalledProcessError(process.returncode, command)
    return stdout or ""


def _run_checks(request: dict, source_dir: Path, deadline: float) -> None:
    credentials = request["credentials"]
    environment = os.environ.copy()
    cache_value = environment.get("RECOVERY_HELM_CACHE", "")
    chart_paths = validate_chart_cache(request, source_dir, Path(cache_value))
    environment.update(
        {
            "RECOVERY_KUBECONFIG": credentials["kubeconfig"],
            "RECOVERY_KUBE_CONTEXT": credentials["kubeContext"],
            "RECOVERY_TALOSCONFIG": credentials["talosconfig"],
            "RECOVERY_TALOS_CONTEXT": credentials["talosContext"],
            "RECOVERY_SOURCE_REVISION": request["sourceRevision"],
            "RECOVERY_API_SERVER": request["apiServer"],
            "RECOVERY_MODE": request["mode"],
            "RECOVERY_NODE": request["node"],
            "RECOVERY_RECORD": ""
            if request["expectedContainment"] is None
            else request["expectedContainment"]["record"],
            "RECOVERY_NODES_JSON": json.dumps(request["nodes"], separators=(",", ":")),
            "RECOVERY_TALOS_ENDPOINTS": ",".join(request["talosEndpoints"]),
        }
    )
    for logical, variable in CHART_ENV.items():
        environment[variable] = str(chart_paths[logical])
    remaining = max(1, int(deadline - time.monotonic()))
    if request["mode"] != "prepare":
        nodes_output = run_supervised(
            [
                "kubectl",
                "--kubeconfig",
                credentials["kubeconfig"],
                "--context",
                credentials["kubeContext"],
                "get",
                "nodes",
                "--output",
                "json",
            ],
            cwd=source_dir,
            env=environment,
            timeout=remaining,
            capture=True,
        )
        try:
            live_nodes = json.loads(nodes_output)["items"]
            states = [
                NodeState(
                    name=item["metadata"]["name"],
                    ready=next(
                        condition["status"] == "True"
                        for condition in item.get("status", {}).get("conditions", [])
                        if condition.get("type") == "Ready"
                    ),
                    unschedulable=item.get("spec", {}).get("unschedulable", False) is True,
                    record=item.get("metadata", {}).get("annotations", {}).get(ANNOTATION, ""),
                )
                for item in live_nodes
            ]
        except (json.JSONDecodeError, KeyError, TypeError, StopIteration) as exc:
            raise ContractError("Kubernetes returned malformed node state") from exc
        validate_node_states(request, states)
        remaining = max(1, int(deadline - time.monotonic()))
    run_supervised(
        ["bash", "scripts/lib/recovery-verification.sh"],
        cwd=source_dir,
        env=environment,
        timeout=remaining,
    )


def main(argv: list[str]) -> int:
    if len(argv) != 2 or not Path(argv[1]).is_absolute():
        print("Usage: recovery.py /absolute/private/request.json", file=sys.stderr)
        return 2
    try:
        request_path = Path(argv[1])
        if not request_path.is_file():
            raise ContractError("request path is not a regular file")
        request = validate_request(load_request_text(request_path.read_text()), Path.cwd())
        deadline = time.monotonic() + request["timeoutSeconds"]
        live = request["mode"] != "prepare"
        _run_checks(request, Path.cwd(), deadline)
        print(json.dumps(_response(request, live), separators=(",", ":")))
        return 0
    except (ContractError, OSError, subprocess.SubprocessError) as exc:
        print(f"recovery verification failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
