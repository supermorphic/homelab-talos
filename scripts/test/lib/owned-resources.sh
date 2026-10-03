#!/usr/bin/env bash

# Create one fixture and keep only the API's ownership metadata in a local ledger.
# Do not record Secret data, workload env values, or other runtime content.
test_create_owned() { # <ledger> <one-object-json-or-yaml> <kubectl-command...>
  local ledger="$1" manifest="$2" created record expected
  shift 2
  expected="$(yq -o=json -I=0 '{"apiVersion": .apiVersion, "kind": .kind,
    "metadata": {"name": .metadata.name, "namespace": .metadata.namespace, "labels": .metadata.labels}}' "$manifest")" || return 1
  if [[ -f "$ledger" ]]; then
    jq -se --argjson expected "$expected" '
      [.[] | select(.kind == $expected.kind and .metadata.name == $expected.metadata.name and
        .metadata.namespace == $expected.metadata.namespace)] | length == 0
    ' "$ledger" >/dev/null || {
      echo 'Refusing to recreate a previously recorded test resource name.' >&2
      return 1
    }
  fi
  created="$("$@" create --filename "$manifest" --output json)" || return 1
  record="$(jq -ce --argjson expected "$expected" '
    select(.apiVersion == $expected.apiVersion and .kind == $expected.kind and
      .metadata.name == $expected.metadata.name and
      .metadata.namespace == $expected.metadata.namespace and
      .metadata.labels == $expected.metadata.labels and
      (.metadata.uid | type == "string" and length > 0) and
      (.metadata.resourceVersion | type == "string" and length > 0)) |
    {apiVersion, kind, metadata: (.metadata | {name, namespace, uid, labels})}
  ' <<<"$created")" || {
    echo 'Created test resource did not return its expected ownership metadata.' >&2
    return 1
  }
  printf '%s\n' "$record" >>"$ledger"
}

# Existing restore builders emit arrays or YAML document streams. Create each
# object separately so partial failures retain every returned creation UID.
test_create_owned_stream() ( # <ledger> <kubectl-command...>; manifests on stdin
  set -euo pipefail
  local ledger="$1" temporary document
  shift
  umask 077
  temporary="$(mktemp -d "${TMPDIR:-/tmp}/homelab-owned-create.XXXXXX")"
  trap 'rm -rf -- "$temporary"' EXIT
  yq -o=json -I=0 '.' - |
    jq -c 'if type == "array" then .[] else . end |
      if type == "object" and has("apiVersion") and has("kind") and has("metadata")
      then . else error("invalid owned-resource manifest") end' >"$temporary/documents.jsonl"
  [[ -s "$temporary/documents.jsonl" ]]
  while IFS= read -r document <&3; do
    printf '%s\n' "$document" >"$temporary/object.json"
    test_create_owned "$ledger" "$temporary/object.json" "$@" 3<&-
  done 3<"$temporary/documents.jsonl"
)

# Match one previously created object, then enforce its UID in the API DELETE.
# Controller dependents are removed by foreground garbage collection.
test_delete_owned() { # <ledger> <kind> <namespace> <name> <kubectl-command...>
  local ledger="$1" kind="$2" namespace="$3" name="$4"
  shift 4
  local record current uid options prefix resource deadline
  [[ -f "$ledger" ]] || return 0
  [[ "$namespace" =~ ^[a-z0-9][a-z0-9-]*$ && "$name" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || return 2
  record="$(jq -sc --arg kind "$kind" --arg ns "$namespace" --arg name "$name" '
    [.[] | select(.kind == $kind and .metadata.namespace == $ns and .metadata.name == $name)] |
    if length > 1 then error("ambiguous recorded ownership") else (.[0] // null) end
  ' "$ledger")" || return 1
  # An unrecorded name never grants authority to adopt a live object.
  [[ "$record" != null ]] || return 0
  uid="$(jq -er '.metadata.uid' <<<"$record")" || return 1
  case "$kind" in
    Pod) prefix='/api/v1'; resource=pods ;;
    Service) prefix='/api/v1'; resource=services ;;
    PersistentVolumeClaim) prefix='/api/v1'; resource=persistentvolumeclaims ;;
    ConfigMap) prefix='/api/v1'; resource=configmaps ;;
    Secret) prefix='/api/v1'; resource=secrets ;;
    Job) prefix='/apis/batch/v1'; resource='jobs' ;;
    Deployment) prefix='/apis/apps/v1'; resource=deployments ;;
    StatefulSet) prefix='/apis/apps/v1'; resource=statefulsets ;;
    CiliumNetworkPolicy) prefix='/apis/cilium.io/v2'; resource=ciliumnetworkpolicies ;;
    Kustomization) prefix='/apis/kustomize.toolkit.fluxcd.io/v1'; resource=kustomizations ;;
    *) echo 'Unsupported owned test resource kind.' >&2; return 2 ;;
  esac
  current="$("$@" get "$resource" "$name" --ignore-not-found --output json)" || return 1
  [[ -n "$current" ]] || return 0
  jq -e --argjson expected "$record" '
    .kind == $expected.kind and .metadata.name == $expected.metadata.name and
    .metadata.namespace == $expected.metadata.namespace and
    .metadata.uid == $expected.metadata.uid and .metadata.labels == $expected.metadata.labels
  ' <<<"$current" >/dev/null || {
    echo 'Recorded test resource ownership changed; refusing deletion.' >&2
    return 1
  }
  if jq -e '.metadata.deletionTimestamp == null' <<<"$current" >/dev/null; then
    options="$(jq -ce '{apiVersion:"v1",kind:"DeleteOptions",propagationPolicy:"Foreground",
      preconditions:{uid:.metadata.uid,resourceVersion:.metadata.resourceVersion}}' <<<"$current")" || return 1
    "$@" delete --raw "$prefix/namespaces/$namespace/$resource/$name" --filename - \
      <<<"$options" >/dev/null || return 1
  fi
  deadline=$((SECONDS + 300))
  while true; do
    current="$("$@" get "$resource" "$name" --ignore-not-found --output json)" || return 1
    [[ -n "$current" ]] || return 0
    [[ "$(jq -er '.metadata.uid' <<<"$current")" == "$uid" ]] || {
      echo 'A different object appeared during test resource cleanup.' >&2
      return 1
    }
    ((SECONDS < deadline)) || return 124
    sleep 1
  done
}
