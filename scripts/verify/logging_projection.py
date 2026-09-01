"""Project logging verification API responses into compact stable JSON."""

import argparse
import json
import math
import sys
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any


class ProjectionError(ValueError):
    """A response could not satisfy the bounded projection contract."""


def fail(kind: str, reason: str) -> None:
    raise ProjectionError(f"invalid {kind} response: {reason}")


def object_value(kind: str, value: Any, reason: str = "expected object") -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        fail(kind, reason)
    return value


def field(kind: str, value: Mapping[str, Any], name: str) -> Any:
    if name not in value:
        fail(kind, f"missing {name}")
    return value[name]


def string_value(kind: str, value: Any, reason: str) -> str:
    if not isinstance(value, str):
        fail(kind, reason)
    return value


def array_value(kind: str, value: Any, reason: str) -> list[Any]:
    if not isinstance(value, list):
        fail(kind, reason)
    return value


def optional_object(value: Mapping[str, Any], name: str) -> Mapping[str, Any]:
    nested = value.get(name, {})
    return nested if isinstance(nested, Mapping) else {}


def pod_projection(kind: str, response: Mapping[str, Any]) -> dict[str, Any]:
    items = array_value(kind, field(kind, response, "items"), "items must be an array")
    pods = []
    for item in items:
        pod = object_value(kind, item, "item must be an object")
        metadata = optional_object(pod, "metadata")
        specification = optional_object(pod, "spec")
        status = optional_object(pod, "status")
        node = specification.get("nodeName", "")
        deletion_timestamp = metadata.get("deletionTimestamp", "")
        phase = status.get("phase", "")
        if not all(isinstance(value, str) for value in (node, deletion_timestamp, phase)):
            fail(kind, "pod field must be a string")
        conditions = status.get("conditions", [])
        conditions = array_value(kind, conditions, "conditions must be an array")
        ready = (
            sum(
                1
                for condition in conditions
                if isinstance(condition, Mapping)
                and condition.get("type") == "Ready"
                and condition.get("status") == "True"
            )
            == 1
        )
        owners = []
        for owner in array_value(
            kind, metadata.get("ownerReferences", []), "ownerReferences must be an array"
        ):
            owner_object = object_value(kind, owner, "owner reference must be an object")
            owners.append(
                {
                    "api_version": owner_object.get("apiVersion", ""),
                    "controller": owner_object.get("controller", False),
                    "kind": owner_object.get("kind", ""),
                    "name": owner_object.get("name", ""),
                    "uid": owner_object.get("uid", ""),
                }
            )
        mounts = []
        for volume in array_value(
            kind, specification.get("volumes", []), "volumes must be an array"
        ):
            volume_object = object_value(kind, volume, "volume must be an object")
            claim = optional_object(volume_object, "persistentVolumeClaim").get("claimName", "")
            volume_name = volume_object.get("name", "")
            if not isinstance(claim, str) or not isinstance(volume_name, str):
                fail(kind, "volume field must be a string")
            if claim:
                mounts.append({"claim": claim, "name": volume_name})
        compact_pod = {
            "deleting": bool(deletion_timestamp),
            "node": node,
            "ready": ready,
            "running": phase == "Running",
        }
        if mounts:
            compact_pod["mounts"] = mounts
        if owners:
            compact_pod["owners"] = owners
        pods.append(compact_pod)
    return {"pods": sorted(pods, key=lambda pod: pod["node"])}


def project_topology(response: Any) -> dict[str, Any]:
    return pod_projection("topology", object_value("topology", response))


def recurring_labels(kind: str, metadata: Mapping[str, Any]) -> list[str]:
    labels = metadata.get("labels", {})
    labels = object_value(kind, labels, "labels must be an object")
    result = []
    for key, value in labels.items():
        if not isinstance(key, str) or not isinstance(value, str):
            fail(kind, "label must be a string")
        if key.startswith(("recurring-job.longhorn.io/", "recurring-job-group.longhorn.io/")):
            result.append(f"{key}={value}")
    return sorted(result)


def project_storage(response: Any) -> dict[str, Any]:
    kind = "storage"
    document = object_value(kind, response)
    if "items" not in document:
        return {"recurring_labels": recurring_labels(kind, optional_object(document, "metadata"))}
    items = array_value(kind, document["items"], "items must be an array")
    if any(
        "kubernetesStatus" in optional_object(object_value(kind, item), "status") for item in items
    ):
        volumes = []
        for item in items:
            volume = object_value(kind, item, "item must be an object")
            metadata = optional_object(volume, "metadata")
            status = optional_object(volume, "status")
            kubernetes_status = optional_object(status, "kubernetesStatus")
            values = {
                "name": metadata.get("name", ""),
                "namespace": kubernetes_status.get("namespace", ""),
                "pv_name": kubernetes_status.get("pvName", ""),
                "pvc_name": kubernetes_status.get("pvcName", ""),
            }
            if not all(isinstance(value, str) for value in values.values()):
                fail(kind, "volume field must be a string")
            volumes.append(values)
        return {"volumes": sorted(volumes, key=lambda volume: volume["name"])}
    claims = []
    for item in items:
        claim = object_value(kind, item, "item must be an object")
        metadata = optional_object(claim, "metadata")
        specification = optional_object(claim, "spec")
        status = optional_object(claim, "status")
        requests = optional_object(optional_object(specification, "resources"), "requests")
        values = {
            "deleting": bool(metadata.get("deletionTimestamp", "")),
            "name": metadata.get("name", ""),
            "phase": status.get("phase", ""),
            "request": requests.get("storage", ""),
            "volume_name": specification.get("volumeName", ""),
        }
        if not all(isinstance(value, str) for name, value in values.items() if name != "deleting"):
            fail(kind, "claim field must be a string")
        values["recurring_labels"] = recurring_labels(kind, metadata)
        claims.append(values)
    return {"claims": sorted(claims, key=lambda claim: claim["name"])}


def project_runtime_limits(response: Any) -> dict[str, Any]:
    kind = "runtime-limits"
    document = object_value(kind, response)
    if "limits_config" in document:
        limits_config = object_value(
            kind, document["limits_config"], "limits_config must be an object"
        )
        shard_streams = object_value(
            kind, field(kind, limits_config, "shard_streams"), "shard_streams must be an object"
        )
        enabled = field(kind, shard_streams, "enabled")
        if not isinstance(enabled, bool):
            fail(kind, "enabled must be a boolean")
        return {"shard_streams_enabled": enabled}
    retention_period = string_value(
        kind, field(kind, document, "retention_period"), "retention_period must be a string"
    )
    retention_stream = array_value(
        kind, document.get("retention_stream", []), "retention_stream must be an array"
    )
    discover_service_name = document.get("discover_service_name")
    return {
        "discover_service_name_disabled": isinstance(discover_service_name, list)
        and len(discover_service_name) == 0,
        "retention_period": retention_period,
        "retention_stream_count": len(retention_stream),
    }


def project_labels(response: Any) -> dict[str, Any]:
    kind = "labels"
    document = object_value(kind, response)
    if document.get("status") != "success":
        fail(kind, "status is not success")
    labels = array_value(kind, field(kind, document, "data"), "data must be an array")
    if not labels or any(not isinstance(label, str) or not label for label in labels):
        fail(kind, "labels must be non-empty strings")
    return {"labels": sorted(set(labels))}


def vector_value(kind: str, response: Any, name: str) -> float:
    document = object_value(kind, response)
    if document.get("status") != "success":
        fail(kind, "status is not success")
    data = object_value(kind, field(kind, document, "data"), "data must be an object")
    if data.get("resultType") != "vector":
        fail(kind, "resultType is not vector")
    result = array_value(kind, field(kind, data, "result"), "result must be an array")
    if len(result) != 1:
        fail(kind, "result must contain exactly one value")
    value = array_value(
        kind,
        field(kind, object_value(kind, result[0], "result item must be an object"), "value"),
        "value must be an array",
    )
    if len(value) != 2:
        fail(kind, "value must contain exactly two entries")
    try:
        number = float(value[1])
    except (TypeError, ValueError):
        fail(kind, f"{name} must be a number")
    if not math.isfinite(number):
        fail(kind, f"{name} must be finite")
    return number


def project_counts(response: Any) -> dict[str, Any]:
    count = vector_value("counts", response, "count")
    if count <= 0:
        fail("counts", "count must be positive")
    return {"count": count}


def project_targets(response: Any) -> dict[str, Any]:
    kind = "targets"
    document = object_value(kind, response)
    if document.get("status") != "success":
        fail(kind, "status is not success")
    data = object_value(kind, field(kind, document, "data"), "data must be an object")
    active_targets = array_value(
        kind, field(kind, data, "activeTargets"), "activeTargets must be an array"
    )
    targets = []
    identities = set()
    for target in active_targets:
        target_object = object_value(kind, target, "target must be an object")
        discovered_labels = optional_object(target_object, "discoveredLabels")
        labels = optional_object(target_object, "labels")
        compact = {
            "health": target_object.get("health", "unknown"),
            "job": labels.get("job", ""),
            "last_error": target_object.get("lastError", ""),
            "scrape_pool": target_object.get("scrapePool", ""),
            "service": labels.get("service", ""),
            "service_name": discovered_labels.get("__meta_kubernetes_service_name", ""),
        }
        if not all(isinstance(value, str) for value in compact.values()):
            fail(kind, "target field must be a string")
        address = discovered_labels.get("__address__", "")
        if not isinstance(address, str):
            fail(kind, "target field must be a string")
        identity = (
            compact["scrape_pool"],
            compact["service_name"],
            compact["service"],
            compact["job"],
            address,
        )
        if identity in identities:
            fail(kind, "duplicate target")
        identities.add(identity)
        targets.append(compact)
    return {
        "targets": sorted(
            targets,
            key=lambda target: (target["scrape_pool"], target["service_name"], target["job"]),
        )
    }


def project_compaction(response: Any) -> dict[str, Any]:
    return {"age_seconds": vector_value("compaction", response, "age")}


def project_rules(response: Any) -> dict[str, Any]:
    kind = "rules"
    document = object_value(kind, response)
    if document.get("status") != "success":
        fail(kind, "status is not success")
    data = object_value(kind, field(kind, document, "data"), "data must be an object")
    groups = array_value(kind, field(kind, data, "groups"), "groups must be an array")
    rules = []
    names = set()
    for group in groups:
        group_object = object_value(kind, group, "group must be an object")
        for rule in array_value(kind, group_object.get("rules", []), "rules must be an array"):
            rule_object = object_value(kind, rule, "rule must be an object")
            compact = {
                "health": rule_object.get("health", "unknown"),
                "last_error": rule_object.get("lastError", ""),
                "name": rule_object.get("name", ""),
            }
            if not all(isinstance(value, str) for value in compact.values()):
                fail(kind, "rule field must be a string")
            if compact["name"] in names:
                fail(kind, "duplicate rule")
            names.add(compact["name"])
            rules.append(compact)
    return {"rules": sorted(rules, key=lambda rule: rule["name"])}


PROJECTORS: dict[str, Callable[[Any], dict[str, Any]]] = {
    "topology": project_topology,
    "storage": project_storage,
    "runtime-limits": project_runtime_limits,
    "labels": project_labels,
    "counts": project_counts,
    "targets": project_targets,
    "compaction": project_compaction,
    "rules": project_rules,
}


def project(kind: str, response: Any) -> dict[str, Any]:
    projector = PROJECTORS.get(kind)
    if projector is None:
        raise ProjectionError(f"invalid {kind} response: unsupported kind")
    return projector(response)


def main(arguments: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--kind", required=True, choices=sorted(PROJECTORS))
    parser.add_argument("--input", required=True)
    try:
        options = parser.parse_args(arguments)
        try:
            with Path(options.input).open(encoding="utf-8") as input_file:
                response = json.load(input_file)
        except (OSError, json.JSONDecodeError):
            fail(options.kind, "invalid JSON")
        print(json.dumps(project(options.kind, response), sort_keys=True, separators=(",", ":")))
    except ProjectionError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
