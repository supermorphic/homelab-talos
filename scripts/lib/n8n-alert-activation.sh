#!/usr/bin/env bash

n8n_alert_resource_count() {
  local owner="$1" expected="$2" resource normalised count=0
  while IFS= read -r resource; do
    normalised="$resource"
    while [[ "$normalised" == ./* ]]; do
      normalised="${normalised#./}"
    done
    [[ "$normalised" != "$expected" ]] || count=$((count + 1))
  done < <(yq -r '.resources[]?' "$owner")
  printf '%s\n' "$count"
}

validate_n8n_alert_activation() {
  local alerts_kustomization='kubernetes/apps/monitoring/alerts/app/kustomization.yaml'
  local n8n_ks='kubernetes/apps/automation/n8n/ks.yaml'
  local postgresql_ks='kubernetes/apps/automation/n8n-postgresql/ks.yaml'
  local public_route_ks='kubernetes/apps/networking/public-webhook-gateway/ks.yaml'
  local gatus_kustomization='kubernetes/apps/monitoring/gatus/app/kustomization.yaml'
  local gatus_values='kubernetes/apps/monitoring/gatus/app/values.yaml'
  local alert_count canary_secret_count canary_env_count canary_endpoint_count
  local n8n_suspended postgresql_suspended public_route_suspended activation_complete=false
  local resource normalised

  for source in "$alerts_kustomization" "$n8n_ks" "$postgresql_ks" \
    "$public_route_ks" "$gatus_kustomization" "$gatus_values"; do
    [[ -f "$source" ]] || {
      echo "Missing n8n alert activation source: $source" >&2
      return 1
    }
  done

  while IFS= read -r resource; do
    normalised="$resource"
    while [[ "$normalised" == ./* ]]; do
      normalised="${normalised#./}"
    done
    if [[ "$normalised" == 'n8n.yaml' && "$resource" != './n8n.yaml' ]]; then
      echo 'The n8n alert rule must use only the exact ./n8n.yaml resource path.' >&2
      return 1
    fi
  done < <(yq -r '.resources[]?' "$alerts_kustomization")

  alert_count="$(n8n_alert_resource_count "$alerts_kustomization" 'n8n.yaml')"
  canary_secret_count="$(n8n_alert_resource_count "$gatus_kustomization" 'n8n-canary.sops.yaml')"
  canary_env_count="$(yq -r '[.env.GATUS_N8N_CANARY_TOKEN | select(. != null)] | length' \
    "$gatus_values")"
  canary_endpoint_count="$(yq -r \
    '[.config.endpoints[]? | select(.group == "Platform" and .name == "n8n-platform-canary")] | length' \
    "$gatus_values")"
  n8n_suspended="$(yq -r '.spec.suspend // false' "$n8n_ks")"
  postgresql_suspended="$(yq -r '.spec.suspend // false' "$postgresql_ks")"
  public_route_suspended="$(yq ea -r \
    'select(.metadata.name == "public-webhook-route") | .spec.suspend // false' \
    "$public_route_ks")"

  if [[ "$canary_secret_count" == '1' && "$canary_env_count" == '1' && \
    "$canary_endpoint_count" == '1' && "$n8n_suspended" == 'false' && \
    "$postgresql_suspended" == 'false' && "$public_route_suspended" == 'false' ]]; then
    activation_complete=true
  fi

  if [[ "$activation_complete" == true ]]; then
    [[ "$alert_count" == '1' ]] || {
      echo 'Complete n8n platform activation must select ./n8n.yaml exactly once.' >&2
      return 1
    }
  else
    [[ "$alert_count" == '0' ]] || {
      echo 'The n8n alert rule must remain unselected until complete platform activation.' >&2
      return 1
    }
  fi
}
