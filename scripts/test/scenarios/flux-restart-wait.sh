#!/usr/bin/env bash
set -euo pipefail

[[ "$#" == 1 && -f "$1" ]] || {
  echo 'Usage: flux-restart-wait.sh <selected-kubeconfig>' >&2
  exit 2
}
kubeconfig="$1"
[[ "$(git remote get-url origin)" == 'https://forgejo.infra.supermorphic.com/supermorphic/homelab-talos.git' ]]
revision="$(git ls-remote --exit-code origin refs/heads/main | awk '{print $1}')"
[[ "$revision" =~ ^[0-9a-f]{40}$ ]]
deadline=$(( $(date -u +%s) + 300 ))

# A recovered controller can report its parent Ready before all applications
# have finished reconciling. Observe them before the unchanged final verifier.
while (( $(date -u +%s) < deadline )); do
  remaining=$(( deadline - $(date -u +%s) ))
  (( remaining > 0 )) || break
  request_timeout=10
  (( remaining >= request_timeout )) || request_timeout="$remaining"
  snapshot="$(kubectl --kubeconfig "$kubeconfig" --request-timeout="${request_timeout}s" \
    --namespace flux-system get kustomizations --output json)"
  jq -e 'type == "object" and (.items | type == "array" and length > 0) and
    all(.items[]; type == "object" and (.spec.sourceRef | type == "object"))' \
    <<<"$snapshot" >/dev/null
  applications="$(jq -c '[.items[] | select(.spec.sourceRef.kind == "GitRepository" and
    .spec.sourceRef.name == "flux-system" and (.spec.sourceRef.namespace // "flux-system") == "flux-system" and
    (.spec.suspend // false) == false)]' <<<"$snapshot")"
  jq -e 'length > 0 and all(.[]; (.metadata.name | type == "string" and length > 0) and
    (.metadata.generation | type == "number" and . > 0))' <<<"$applications" >/dev/null
  ready="$(jq -r --arg revision "main@sha1:$revision" 'all(.[];
    .metadata.generation as $generation |
    .status.observedGeneration == $generation and
    ([.status.conditions[]? | select(.type == "Ready" and .status == "True" and
      .observedGeneration == $generation)] | length == 1) and
    .status.lastAppliedRevision == $revision)' <<<"$applications")"
  (( $(date -u +%s) < deadline )) || break
  if [[ "$ready" == true ]]; then
    echo 'All active Flux applications have reconciled the current main revision.'
    exit 0
  fi
  remaining=$(( deadline - $(date -u +%s) ))
  (( remaining > 0 )) || break
  pause=5
  (( remaining >= pause )) || pause="$remaining"
  sleep "$pause"
done
echo 'Flux applications did not recover their current generation and main revision within five minutes.' >&2
exit 1
