#!/usr/bin/env bash

# Pure Longhorn verification predicates. Functions evaluate caller-supplied Kubernetes
# API responses and perform no cluster operation.

longhorn_volume_matches_claim_health() {
  [[ "$#" -eq 5 ]] || return 2
  local namespace="$1" claim="$2" volume="$3" mode="$4" input="$5"

  case "$mode" in
    active | retained-backup) ;;
    *) return 2 ;;
  esac

  NAMESPACE="$namespace" CLAIM_NAME="$claim" PV_NAME="$volume" MODE="$mode" \
    yq -p=json -o=json -e '
      [.items[]? | select(
        (.status.kubernetesStatus.namespace // "") == strenv(NAMESPACE) and
        (.status.kubernetesStatus.pvcName // "") == strenv(CLAIM_NAME) and
        (.status.kubernetesStatus.pvName // "") == strenv(PV_NAME)
      )] as $matches |
      (($matches | length) == 1 and
      ([$matches[0].status.conditions[]? | select(
        .type == "Scheduled"
      )] | length) == 1 and
      ([$matches[0].status.conditions[]? | select(
        .type == "Scheduled" and .status == "True"
      )] | length) == 1 and
      ([$matches[0].status.conditions[]? | select(
        .type == "Restore"
      )] | length) == 1 and
      ([$matches[0].status.conditions[]? | select(
        .type == "Restore" and .status == "False"
      )] | length) == 1 and
      ((strenv(MODE) == "active" and
        $matches[0].status.state == "attached" and
        $matches[0].status.robustness == "healthy") or
      (strenv(MODE) == "retained-backup" and
        (($matches[0].status.state == "attached" and
          $matches[0].status.robustness == "healthy") or
        ($matches[0].status.state == "detached" and
          $matches[0].status.robustness == "unknown")))))
    ' "$input" >/dev/null 2>&1
}
