#!/usr/bin/env bash
# Verify Portainer's effective RBAC graph without impersonation.
set -euo pipefail

[[ "$#" -eq 2 ]] || {
  echo 'Usage: portainer-rbac.sh <kubeconfig> <rbac-source>' >&2
  exit 2
}

kubeconfig="$1"
rbac_source="$2"
kc=(kubectl --kubeconfig "$kubeconfig")

fail() {
  echo "Portainer RBAC verification failed: $*" >&2
  exit 1
}

normalize_role_rules() {
  # shellcheck disable=SC2016 # yq variables are intentionally literal shell input.
  yq -o=json -I=0 '.rules |
    map(. as $rule |
      {} +
      ({"apiGroups": ($rule.apiGroups | sort)} |
        select($rule | has("apiGroups")) // {}) +
      ({"resources": ($rule.resources | sort)} |
        select($rule | has("resources")) // {}) +
      ({"verbs": ($rule.verbs | sort)} |
        select($rule | has("verbs")) // {}) +
      ({"resourceNames": ($rule.resourceNames | sort)} |
        select($rule | has("resourceNames")) // {}) +
      ({"nonResourceURLs": ($rule.nonResourceURLs | sort)} |
        select($rule | has("nonResourceURLs")) // {})
    ) |
    sort_by(to_json)'
}

live_role="$("${kc[@]}" get clusterrole portainer-readonly --output json)"
expected_role="$(yq ea -o=json -I=0 \
  'select(.kind == "ClusterRole" and .metadata.name == "portainer-readonly")' \
  "$rbac_source")"
[[ "$(normalize_role_rules <<<"$live_role")" == \
  "$(normalize_role_rules <<<"$expected_role")" ]] ||
  fail 'Live portainer-readonly ClusterRole rules differ from the rendered policy.'

binding="$("${kc[@]}" get clusterrolebinding portainer-readonly --output json)"
[[ "$(yq -r '[.roleRef.apiGroup, .roleRef.kind, .roleRef.name] | join(":")' \
  - <<<"$binding")" == 'rbac.authorization.k8s.io:ClusterRole:portainer-readonly' ]] ||
  fail 'portainer-readonly ClusterRoleBinding has an unexpected roleRef.'
[[ "$(yq -r '[.subjects[] | [.kind, (.namespace // ""), .name] | join(":")] | join(",")' \
  - <<<"$binding")" == 'ServiceAccount:portainer:portainer-readonly' ]] ||
  fail 'portainer-readonly ClusterRoleBinding has unexpected subjects.'

cluster_bindings="$("${kc[@]}" get clusterrolebindings --output json)"
role_bindings="$("${kc[@]}" get rolebindings --all-namespaces --output json)"
portainer_subject_filter='[.subjects[]? | select(
  (.kind == "ServiceAccount" and .namespace == "portainer" and .name == "portainer-readonly") or
  (.kind == "User" and .name == "system:serviceaccount:portainer:portainer-readonly") or
  (.kind == "Group" and .name == "system:serviceaccounts:portainer")
)] | length > 0'
global_serviceaccount_filter='[.subjects[]? | select(
  .kind == "Group" and .name == "system:serviceaccounts"
)] | length > 0'
direct_cluster_refs="$(yq -r ".items[] | select($portainer_subject_filter) |
  [.kind, \"-\", .metadata.name, .roleRef.kind, .roleRef.name] | @tsv" \
  - <<<"$cluster_bindings")"
direct_role_refs="$(yq -r ".items[] |
  select(($portainer_subject_filter) or ($global_serviceaccount_filter)) |
  [.kind, .metadata.namespace, .metadata.name, .roleRef.kind, .roleRef.name] | @tsv" \
  - <<<"$role_bindings")"
serviceaccount_role_refs="$(yq -r ".items[] | select($global_serviceaccount_filter) |
  [.metadata.name, .roleRef.apiGroup, .roleRef.kind, .roleRef.name] | @tsv" \
  - <<<"$cluster_bindings")"
[[ "$direct_cluster_refs" == \
  $'ClusterRoleBinding\t-\tportainer-readonly\tClusterRole\tportainer-readonly' ]] ||
  fail "Unexpected direct ClusterRoleBinding grants Portainer access: ${direct_cluster_refs:-<none>}."
[[ -z "$direct_role_refs" ]] ||
  fail "Unexpected direct RoleBinding grants Portainer access: $direct_role_refs."

authenticated_role_refs="$(yq -r '.items[] |
  select([.subjects[]? | select(.kind == "Group" and .name == "system:authenticated")] | length > 0) |
  [.metadata.name, .roleRef.apiGroup, .roleRef.kind, .roleRef.name] | @tsv' \
  - <<<"$cluster_bindings")"
authenticated_role_bindings="$(yq -r '.items[] |
  select([.subjects[]? | select(.kind == "Group" and .name == "system:authenticated")] | length > 0) |
  [.metadata.namespace, .metadata.name, .roleRef.kind, .roleRef.name] | @tsv' \
  - <<<"$role_bindings")"
[[ -z "$authenticated_role_bindings" ]] ||
  fail "Unexpected system:authenticated RoleBinding grants Portainer access: $authenticated_role_bindings."

allowed_non_resource_url() {
  case "$1" in
    /api | '/api/*' | /apis | '/apis/*' | /healthz | /livez | /openapi | \
      '/openapi/*' | /openid/v1/jwks | /openid/v1/jwks/ | /readyz | /version | \
      /version/) return 0 ;;
    *) return 1 ;;
  esac
}

safe_bootstrap_role() {
  local role_name="$1"
  local role_json="$2"
  local rule api_group resource verb url

  case "$role_name" in
    system:basic-user | system:discovery | system:public-info-viewer) ;;
    *) return 1 ;;
  esac
  [[ "$(yq -r '.aggregationRule // ""' - <<<"$role_json")" == '' ]]
  [[ "$(yq -r '.rules | length' - <<<"$role_json")" -gt 0 ]]
  while IFS= read -r rule; do
    [[ -n "$rule" ]] || continue
    if [[ "$(yq -r '.nonResourceURLs | length' - <<<"$rule")" -gt 0 ]]; then
      [[ "$(yq -r '(.apiGroups // []) + (.resources // []) + (.resourceNames // []) | length' \
        - <<<"$rule")" -eq 0 ]]
      while IFS= read -r verb; do
        [[ "$verb" == get ]] || return 1
      done < <(yq -r '.verbs[]' - <<<"$rule")
      while IFS= read -r url; do
        allowed_non_resource_url "$url" || return 1
      done < <(yq -r '.nonResourceURLs[]' - <<<"$rule")
      continue
    fi

    [[ "$(yq -r '.apiGroups | length' - <<<"$rule")" -eq 1 ]]
    api_group="$(yq -r '.apiGroups[0]' - <<<"$rule")"
    while IFS= read -r verb; do
      [[ "$verb" == create ]] || return 1
    done < <(yq -r '.verbs[]' - <<<"$rule")
    while IFS= read -r resource; do
      case "$api_group:$resource" in
        authorization.k8s.io:selfsubjectaccessreviews | \
          authorization.k8s.io:selfsubjectrulesreviews | \
          authentication.k8s.io:selfsubjectreviews) ;;
        *) return 1 ;;
      esac
    done < <(yq -r '.resources[]' - <<<"$rule")
  done < <(yq -o=json -I=0 '.rules[]' - <<<"$role_json")
}

safe_serviceaccount_role() {
  local role_name="$1"
  local role_json="$2"

  [[ "$role_name" == 'system:service-account-issuer-discovery' ]]
  [[ "$(yq -r '.aggregationRule // ""' - <<<"$role_json")" == '' ]]
  [[ "$(yq -r '.rules | length' - <<<"$role_json")" == '1' ]]
  [[ "$(yq -r '.rules[0].verbs | sort | join(",")' - <<<"$role_json")" == 'get' ]]
  [[ "$(yq -r '(.rules[0].apiGroups // []) + (.rules[0].resources // []) +
    (.rules[0].resourceNames // []) | length' - <<<"$role_json")" == '0' ]]
  [[ "$(yq -r '.rules[0].nonResourceURLs | sort | .[]' - <<<"$role_json")" == \
    $'/.well-known/openid-configuration\n/.well-known/openid-configuration/\n/openid/v1/jwks\n/openid/v1/jwks/' ]]
}

expected_serviceaccount_ref=$'system:service-account-issuer-discovery\trbac.authorization.k8s.io\tClusterRole\tsystem:service-account-issuer-discovery'
[[ "$serviceaccount_role_refs" == "$expected_serviceaccount_ref" ]] ||
  fail "Unexpected system:serviceaccounts ClusterRoleBinding: ${serviceaccount_role_refs:-<none>}."
while IFS=$'\t' read -r binding_name api_group role_kind role_name; do
  [[ "$api_group" == 'rbac.authorization.k8s.io' && "$role_kind" == 'ClusterRole' &&
    "$binding_name" == "$role_name" ]] ||
    fail "Unexpected system:serviceaccounts ClusterRoleBinding: $binding_name -> $role_kind/$role_name."
  role_json="$("${kc[@]}" get clusterrole "$role_name" --output json)"
  safe_serviceaccount_role "$role_name" "$role_json" ||
    fail "Unsafe system:serviceaccounts ClusterRole rules: $role_name."
done <<<"$serviceaccount_role_refs"

while IFS=$'\t' read -r binding_name api_group role_kind role_name; do
  [[ -n "$binding_name" ]] || continue
  [[ "$api_group" == 'rbac.authorization.k8s.io' && "$role_kind" == 'ClusterRole' &&
    "$binding_name" == "$role_name" ]] ||
    fail "Unexpected system:authenticated ClusterRoleBinding: $binding_name -> $role_kind/$role_name."
  role_json="$("${kc[@]}" get clusterrole "$role_name" --output json)"
  safe_bootstrap_role "$role_name" "$role_json" ||
    fail "Unsafe system:authenticated ClusterRole rules: $role_name."
done <<<"$authenticated_role_refs"

echo 'Portainer effective RBAC graph passed.'
