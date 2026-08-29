#!/usr/bin/env bash

# Pure n8n verification predicates. Each function evaluates a caller-supplied API
# response and performs no network or Kubernetes operation.
# shellcheck disable=SC2016 # yq and embedded Python consume these literal programs.

n8n_flux_resource_current_ready() {
  local input="$1"
  yq -p=json -o=json -e '
    .metadata.generation as $generation |
    (((.spec.suspend // false) == false) and
    (.status.observedGeneration == $generation) and
    ([.status.conditions[]? | select(.type == "Ready")] | length) == 1 and
    ([.status.conditions[]? |
      select(.type == "Ready" and .status == "True" and
        .observedGeneration == $generation)] | length) == 1)
  ' "$input" >/dev/null 2>&1
}

n8n_deployment_current_ready() {
  local input="$1"
  yq -p=json -o=json -e '
    .spec.replicas as $replicas |
    ((.metadata.generation == .status.observedGeneration) and
    (.status.replicas == $replicas) and
    (.status.updatedReplicas == $replicas) and
    (.status.readyReplicas == $replicas) and
    (.status.availableReplicas == $replicas) and
    ((.status.unavailableReplicas // 0) == 0))
  ' "$input" >/dev/null 2>&1
}

n8n_statefulset_current_ready() {
  local input="$1"
  yq -p=json -o=json -e '
    .spec.replicas as $replicas |
    ((.metadata.generation == .status.observedGeneration) and
    (.status.replicas == $replicas) and
    (.status.currentReplicas == $replicas) and
    (.status.updatedReplicas == $replicas) and
    (.status.readyReplicas == $replicas) and
    ((.status.availableReplicas // $replicas) == $replicas) and
    (.status.currentRevision | type == "!!str" and length > 0) and
    (.status.currentRevision == .status.updateRevision))
  ' "$input" >/dev/null 2>&1
}

n8n_prometheus_targets_match_contract() {
  local input="$1" service endpoint pool
  yq -p=json -o=json -e '.status == "success"' "$input" >/dev/null 2>&1 || return 1
  for service in n8n n8n-postgresql; do
    endpoint='http'
    [[ "$service" == 'n8n' ]] || endpoint='metrics'
    pool="serviceMonitor/automation/$service/0"
    SERVICE="$service" ENDPOINT="$endpoint" POOL="$pool" \
      yq -p=json -o=json -e '
        [.data.activeTargets[]? | select(
          .labels.namespace == "automation" and
          .labels.service == strenv(SERVICE) and
          .labels.endpoint == strenv(ENDPOINT) and
          .labels.job == strenv(SERVICE)
        )] as $identity_targets |
        [.data.activeTargets[]? | select(.scrapePool == strenv(POOL))] as $pool_targets |
        (($identity_targets | length) == 1 and
        ($pool_targets | length) == 1 and
        $identity_targets[0].scrapePool == strenv(POOL) and
        $identity_targets[0].health == "up")
      ' "$input" >/dev/null 2>&1 || return 1
  done
}

n8n_expected_prometheus_alert_rules() {
  printf '%s\n' \
    N8nCanaryDown \
    N8nCanaryProbeMissing \
    N8nContainerOomKilled \
    N8nContainerRestarting \
    N8nExecutionFailures \
    N8nPersistentVolumeClaimNotBound \
    N8nPersistentVolumeUsageCritical \
    N8nPersistentVolumeUsageWarning \
    N8nPostgresqlBackupJobFailed \
    N8nPostgresqlBackupJobOverdue \
    N8nPostgresqlBackupStale \
    N8nPostgresqlUnavailable \
    N8nPostgresqlWorkloadUnavailable \
    N8nUnavailable \
    N8nWorkloadUnavailable
}

n8n_prometheus_rule_group_matches_contract() {
  local mode="$1" input="$2" group_count actual_rules expected_rules rule rule_row

  yq -p=json -o=json -e '.status == "success"' "$input" >/dev/null 2>&1 || return 1
  group_count="$(yq -p=json -o=json -r \
    '[.data.groups[]? | select(.name == "n8n-platform")] | length' "$input")"
  case "$mode" in
    private) [[ "$group_count" == '0' ]] ;;
    full)
      [[ "$group_count" == '1' ]] || return 1
      actual_rules="$(yq -p=json -o=json -r '
        [.data.groups[]? | select(.name == "n8n-platform") | .rules[]?.name] |
        sort | .[]
      ' "$input")"
      expected_rules="$(n8n_expected_prometheus_alert_rules | LC_ALL=C sort)"
      [[ "$actual_rules" == "$expected_rules" ]] || return 1
      while IFS= read -r rule; do
        rule_row="$(RULE="$rule" yq -p=json -o=json -r '
          [
            .data.groups[]? | select(.name == "n8n-platform") | .rules[]? |
            select(.name == strenv(RULE)) |
            [(.health // ""), (.lastError // "")] | join("|")
          ] | join(",")
        ' "$input")"
        [[ "$rule_row" == 'ok|' ]] || return 1
      done < <(n8n_expected_prometheus_alert_rules)
      ;;
    *) return 1 ;;
  esac
}

n8n_routes_target_service() {
  local target_namespace="$1" target_service="$2" input="$3"
  python - "$target_namespace" "$target_service" "$input" <<'PY'
import json
import sys

target_namespace, target_service, path = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    document = json.load(stream)
for route in document.get("items", []):
    route_namespace = route.get("metadata", {}).get("namespace", "")
    for rule in route.get("spec", {}).get("rules", []):
        for backend in rule.get("backendRefs", []):
            if (
                backend.get("group", "") == ""
                and backend.get("kind", "Service") == "Service"
                and backend.get("name") == target_service
                and backend.get("namespace", route_namespace) == target_namespace
            ):
                raise SystemExit(0)
raise SystemExit(1)
PY
}

n8n_routes_match_contract() {
  local mode="$1" input="$2"
  python - "$mode" "$input" <<'PY'
import json
import sys


def parent_ref(value, route_namespace):
    return {
        "group": value.get("group", "gateway.networking.k8s.io"),
        "kind": value.get("kind", "Gateway"),
        "namespace": value.get("namespace", route_namespace),
        "name": value.get("name"),
        "sectionName": value.get("sectionName", ""),
    }


def route_match(value):
    path = value.get("path", {})
    return {
        "path": {
            "type": path.get("type", "PathPrefix"),
            "value": path.get("value", "/"),
        },
        "method": value.get("method", ""),
        "headers": sorted(
            (
                {
                    "type": item.get("type", "Exact"),
                    "name": item.get("name"),
                    "value": item.get("value"),
                }
                for item in value.get("headers", [])
            ),
            key=lambda item: (item["type"], item["name"], item["value"]),
        ),
        "queryParams": sorted(
            (
                {
                    "type": item.get("type", "Exact"),
                    "name": item.get("name"),
                    "value": item.get("value"),
                }
                for item in value.get("queryParams", [])
            ),
            key=lambda item: (item["type"], item["name"], item["value"]),
        ),
    }


def backend_ref(value, route_namespace):
    return {
        "group": value.get("group", ""),
        "kind": value.get("kind", "Service"),
        "namespace": value.get("namespace", route_namespace),
        "name": value.get("name"),
        "port": value.get("port"),
        "weight": value.get("weight", 1),
        "filters": value.get("filters", []),
    }


def targets_n8n(route):
    namespace = route.get("metadata", {}).get("namespace", "")
    return any(
        backend.get("group", "") == ""
        and backend.get("kind", "Service") == "Service"
        and backend.get("name") == "n8n"
        and backend.get("namespace", namespace) == "automation"
        for rule in route.get("spec", {}).get("rules", [])
        for backend in rule.get("backendRefs", [])
    )


def normalize(route):
    metadata = route.get("metadata", {})
    namespace = metadata.get("namespace", "")
    generation = metadata.get("generation")
    spec = route.get("spec", {})
    status = route.get("status", {})
    status_parents = []
    for parent in status.get("parents", []):
        conditions = sorted(
            (
                {
                    "type": condition.get("type"),
                    "status": condition.get("status"),
                    "observedGeneration": condition.get("observedGeneration"),
                }
                for condition in parent.get("conditions", [])
                if condition.get("type") in {"Accepted", "ResolvedRefs"}
            ),
            key=lambda item: item["type"],
        )
        status_parents.append(
            {"parent": parent_ref(parent.get("parentRef", {}), namespace), "conditions": conditions}
        )
    status_parents.sort(key=lambda item: tuple(item["parent"].values()))
    return {
        "id": f'{namespace}/{metadata.get("name", "")}',
        "generation": generation,
        "hostnames": sorted(spec.get("hostnames", [])),
        "parents": sorted(
            (parent_ref(parent, namespace) for parent in spec.get("parentRefs", [])),
            key=lambda item: tuple(item.values()),
        ),
        "rules": [
            {
                "matches": [route_match(match) for match in rule.get("matches", [{}])],
                "filters": rule.get("filters", []),
                "backends": [
                    backend_ref(backend, namespace) for backend in rule.get("backendRefs", [])
                ],
            }
            for rule in spec.get("rules", [])
        ],
        "statusParents": status_parents,
    }


def expected(route_id, generation, hostname, parent, match_type, match_value):
    namespace = route_id.split("/", 1)[0]
    normalized_parent = parent_ref(parent, namespace)
    return {
        "id": route_id,
        "generation": generation,
        "hostnames": [hostname],
        "parents": [normalized_parent],
        "rules": [{
            "matches": [route_match({"path": {"type": match_type, "value": match_value}})],
            "filters": [],
            "backends": [{
                "group": "", "kind": "Service", "namespace": "automation",
                "name": "n8n", "port": 5678, "weight": 1, "filters": [],
            }],
        }],
        "statusParents": [{
            "parent": normalized_parent,
            "conditions": [
                {"type": "Accepted", "status": "True", "observedGeneration": generation},
                {"type": "ResolvedRefs", "status": "True", "observedGeneration": generation},
            ],
        }],
    }


mode, path = sys.argv[1:]
with open(path, encoding="utf-8") as stream:
    document = json.load(stream)
routes = document.get("items", [])
actual = sorted((normalize(route) for route in routes if targets_n8n(route)), key=lambda item: item["id"])
generations = {item["id"]: item["generation"] for item in actual}
private = expected(
    "automation/n8n", generations.get("automation/n8n"), "n8n.lab.supermorphic.com",
    {"name": "internal", "namespace": "networking", "sectionName": "https"},
    "PathPrefix", "/",
)
public = expected(
    "networking-public/n8n-platform-canary",
    generations.get("networking-public/n8n-platform-canary"),
    "hooks.lab.supermorphic.com",
    {"name": "public-webhooks", "sectionName": "https"},
    "Exact", "/webhook/platform-canary",
)
expected_routes = [private] if mode == "private" else [private, public] if mode == "full" else []
raise SystemExit(0 if actual == expected_routes else 1)
PY
}
