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

n8n_normalise_relative_path() {
  local path="$1" segment last_index
  local -a segments=() resolved=()

  IFS='/' read -r -a segments <<<"$path"
  for segment in "${segments[@]}"; do
    case "$segment" in
      ''|.) ;;
      ..)
        if [[ "${#resolved[@]}" -gt 0 ]]; then
          last_index=$((${#resolved[@]} - 1))
          if [[ "${resolved[$last_index]}" != '..' ]]; then
            unset "resolved[$last_index]"
          else
            resolved+=("$segment")
          fi
        else
          resolved+=("$segment")
        fi
        ;;
      *) resolved+=("$segment") ;;
    esac
  done

  if [[ "${#resolved[@]}" -eq 0 ]]; then
    printf '.\n'
  else
    local IFS=/
    printf '%s\n' "${resolved[*]}"
  fi
}

validate_n8n_activation_lifecycle() {
  local n8n_suspended="$1"
  local postgresql_suspended="$2"
  local public_route_suspended="$3"
  local state

  for state in "$n8n_suspended" "$postgresql_suspended" "$public_route_suspended"; do
    case "$state" in
      true | false) ;;
      *)
        echo 'n8n activation suspend fields must contain explicit booleans.' >&2
        return 1
        ;;
    esac
  done

  [[ "$n8n_suspended" == "$postgresql_suspended" ]] || {
    echo 'n8n and n8n-postgresql must be suspended or active together.' >&2
    return 1
  }
  [[ "$public_route_suspended" != false || "$n8n_suspended" == false ]] || {
    echo 'The public webhook route cannot be active while n8n or n8n-postgresql is suspended.' >&2
    return 1
  }
}

validate_n8n_alert_activation() {
  local alerts_kustomization='kubernetes/apps/monitoring/alerts/app/kustomization.yaml'
  local n8n_ks='kubernetes/apps/automation/n8n/ks.yaml'
  local postgresql_ks='kubernetes/apps/automation/n8n-postgresql/ks.yaml'
  local public_route_ks='kubernetes/apps/networking/public-webhook-gateway/ks.yaml'
  local gatus_kustomization='kubernetes/apps/monitoring/gatus/app/kustomization.yaml'
  local gatus_values='kubernetes/apps/monitoring/gatus/app/values.yaml'
  local alert_count=0 alert_resource='' canary_secret_count canary_env_count canary_endpoint_count
  local n8n_suspended postgresql_suspended public_route_suspended activation_complete=false
  local resource resolved_resource alerts_directory n8n_alert_path

  for source in "$alerts_kustomization" "$n8n_ks" "$postgresql_ks" \
    "$public_route_ks" "$gatus_kustomization" "$gatus_values"; do
    [[ -f "$source" ]] || {
      echo "Missing n8n alert activation source: $source" >&2
      return 1
    }
  done

  alerts_directory="${alerts_kustomization%/*}"
  n8n_alert_path="$(n8n_normalise_relative_path "$alerts_directory/n8n.yaml")"
  while IFS= read -r resource; do
    resolved_resource="$(n8n_normalise_relative_path "$alerts_directory/$resource")"
    if [[ "$resolved_resource" == "$n8n_alert_path" ]]; then
      alert_count=$((alert_count + 1))
      alert_resource="$resource"
    fi
  done < <(yq -r '.resources[]?' "$alerts_kustomization")

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
  validate_n8n_activation_lifecycle \
    "$n8n_suspended" "$postgresql_suspended" "$public_route_suspended"

  if [[ "$canary_secret_count" == '1' && "$canary_env_count" == '1' && \
    "$canary_endpoint_count" == '1' && "$n8n_suspended" == 'false' && \
    "$postgresql_suspended" == 'false' && "$public_route_suspended" == 'false' ]]; then
    activation_complete=true
  fi

  if [[ "$activation_complete" == true ]]; then
    [[ "$alert_count" == '1' ]] || {
      echo "Complete n8n platform activation must select exactly one resource path resolving to n8n.yaml; found $alert_count." >&2
      return 1
    }
    [[ "$alert_resource" == './n8n.yaml' ]] || {
      echo "Complete n8n platform activation must use the literal resource path ./n8n.yaml; got $alert_resource." >&2
      return 1
    }
  else
    [[ "$alert_count" == '0' ]] || {
      echo "Pre-activation n8n alerts must select no resource path resolving to n8n.yaml; found $alert_count." >&2
      return 1
    }
  fi
}
