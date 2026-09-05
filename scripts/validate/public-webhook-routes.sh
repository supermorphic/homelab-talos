#!/usr/bin/env bash
# Foundation owns the public Gateway invariant across every application domain.
set -euo pipefail

expected_public_route_contract='{"metadata":{"name":"n8n-platform-canary","namespace":"networking-public"},"parentRefs":[{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"public-webhooks","namespace":"networking-public","sectionName":"https"}],"rules":[{"backendRefs":[{"group":"","kind":"Service","name":"n8n","namespace":"automation","port":5678}],"matches":[{"path":{"type":"Exact","value":"/webhook/platform-canary"}}]}]}'
mapfile -t public_route_contracts < <(
  while IFS= read -r -d '' manifest; do
    # shellcheck disable=SC2016 # yq evaluates $route_namespace, not the shell.
    yq -o=json -I=0 '
      select(type == "!!map") |
      select(.kind == "HTTPRoute") |
      .metadata.namespace as $route_namespace |
      select([
        .spec.parentRefs[]? |
        select(.name == "public-webhooks" and
          (.namespace // $route_namespace) == "networking-public")
      ] | length > 0) |
      {
        "metadata": {"name": .metadata.name, "namespace": .metadata.namespace},
        "parentRefs": .spec.parentRefs,
        "rules": [
          .spec.rules[]? |
          {"backendRefs": (.backendRefs // []), "matches": (.matches // [])}
        ]
      }
    ' "$manifest" | jq -cS 'select(.metadata != null)'
  done < <(find kubernetes/apps -type f \
    \( -name '*.json' -o -name '*.yaml' -o -name '*.yml' \) -print0)
)
[[ "${#public_route_contracts[@]}" == '1' && \
  "${public_route_contracts[0]}" == "$expected_public_route_contract" ]] || {
  echo 'The public Gateway must have exactly one complete Platform Canary HTTPRoute contract.' >&2
  exit 1
}
