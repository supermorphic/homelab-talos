#!/usr/bin/env bash

DISRUPTION_LIFECYCLE_ANNOTATION='homelab.supermorphic.com/node-lifecycle'

disruption_kubectl() {
  local kubeconfig="$1" context="$2"
  shift 2
  kubectl --kubeconfig "$kubeconfig" --context "$context" "$@"
}

disruption_record_is_schema_one() {
  local record="$1"
  python - "$record" <<'PY' >/dev/null 2>&1
import json
import sys

try:
    record = json.loads(sys.argv[1])
except (json.JSONDecodeError, IndexError):
    raise SystemExit(1)
if not isinstance(record, dict) or type(record.get("schemaVersion")) is not int or record["schemaVersion"] != 1:
    raise SystemExit(1)
if set(record) == {"schemaVersion", "kind"} and record["kind"] in {"reboot", "abrupt-loss"}:
    raise SystemExit(0)
if set(record) != {"schemaVersion", "kind", "longhorn"} or record["kind"] != "maintenance":
    raise SystemExit(1)
longhorn = record["longhorn"]
if not isinstance(longhorn, dict) or set(longhorn) != {"allowScheduling", "evictionRequested"}:
    raise SystemExit(1)
allow = longhorn["allowScheduling"]
eviction = longhorn["evictionRequested"]
if not isinstance(allow, dict) or set(allow) != {"before", "during"}:
    raise SystemExit(1)
if not isinstance(eviction, dict) or set(eviction) != {"before", "during"}:
    raise SystemExit(1)
if any(type(value) is not bool for value in (*allow.values(), *eviction.values())):
    raise SystemExit(1)
raise SystemExit(0 if allow["during"] is False and eviction["during"] is True else 1)
PY
}

assert_disruption_admissible() {
  local kubeconfig="$1" context="$2" source_file="${3:-talos/talconfig.yaml}"
  local nodes_json expected_names observed_names row name ready unschedulable record
  [[ -f "$source_file" ]] || {
    echo "Missing desired node source: $source_file" >&2
    return 1
  }
  expected_names="$(yq -r '.nodes[] | select(.controlPlane == true) | .hostname' "$source_file" | sort)"
  [[ "$(awk 'NF {count++} END {print count + 0}' <<<"$expected_names")" == 3 ]] || {
    echo 'Desired source must contain exactly three control-plane nodes.' >&2
    return 1
  }
  nodes_json="$(disruption_kubectl "$kubeconfig" "$context" get nodes --output json)" || {
    echo 'Cannot establish disruption admission through the Kubernetes API.' >&2
    return 1
  }
  observed_names="$(yq -r '.items[].metadata.name' <<<"$nodes_json" | sort)"
  [[ "$observed_names" == "$expected_names" ]] || {
    echo 'Live node set differs from the approved desired source.' >&2
    return 1
  }
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    name="$(yq -r '.metadata.name' <<<"$row")"
    ready="$(yq -r '[.status.conditions[]? | select(.type == "Ready") | .status][0] // "Unknown"' <<<"$row")"
    unschedulable="$(yq -r '.spec.unschedulable // false' <<<"$row")"
    record="$(ANNOTATION="$DISRUPTION_LIFECYCLE_ANNOTATION" yq -r '.metadata.annotations[strenv(ANNOTATION)] // ""' <<<"$row")"
    if [[ -n "$record" ]]; then
      disruption_record_is_schema_one "$record" || {
        echo "Node $name has a malformed or unsupported lifecycle record." >&2
        return 1
      }
      echo "Node $name has active lifecycle containment." >&2
      return 1
    fi
    [[ "$ready" == True ]] || {
      echo "Node $name is $ready rather than Ready." >&2
      return 1
    }
    [[ "$unschedulable" == false ]] || {
      echo "Node $name is unexpectedly cordoned." >&2
      return 1
    }
  done < <(yq -o=json -I=0 '.items[]' <<<"$nodes_json")
}
