#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: ntfy.sh <kubeconfig>' >&2
  exit 2
}

kubeconfig="$1"
ns='ntfy'
base_url='https://ntfy.lab.supermorphic.com'
kc=(kubectl --kubeconfig "$kubeconfig")

# Do not print credentials, Authorization headers, or message bodies.
code() { curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$@"; }

# 1-4. Flux, Helm, rollout, and the retained claim.
[[ "$("${kc[@]}" --namespace flux-system get kustomization ntfy --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'ntfy Kustomization is not Ready.' >&2; exit 1; }
[[ "$("${kc[@]}" --namespace "$ns" get helmrelease ntfy --output jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == 'True' ]] || { echo 'ntfy HelmRelease is not Ready.' >&2; exit 1; }
"${kc[@]}" --namespace "$ns" rollout status deployment/ntfy --timeout=5m
[[ "$("${kc[@]}" --namespace "$ns" get pvc ntfy --output jsonpath='{.status.phase}' 2>/dev/null)" == 'Bound' ]] || { echo 'ntfy PVC is not Bound.' >&2; exit 1; }

# 5. Health through the internal gateway (real DNS -> gateway -> TLS -> Service path).
health="$(curl -sS --max-time 15 "$base_url/v1/health")"
[[ "$(yq -r '.healthy' <<<"$health")" == 'true' ]] || { echo "ntfy /v1/health is not healthy: $health" >&2; exit 1; }

# 6-7. Anonymous access is denied (auth-default-access: deny-all). Denied requests do
# not deliver, so these are side-effect free.
[[ "$(code -X POST -d 'verify' "$base_url/critical")" == '403' ]] || { echo 'Anonymous publish to critical was not denied.' >&2; exit 1; }
[[ "$(code "$base_url/critical/json?poll=1")" == '403' ]] || { echo 'Anonymous poll of critical was not denied.' >&2; exit 1; }

# 8-9. Least-privilege token ACLs. Read the publisher tokens from the live Secret via
# kubectl's own base64decode (portable; never echoed). Negative tests are side-effect
# free (ntfy rejects before delivering).
tokens="$("${kc[@]}" --namespace "$ns" get secret ntfy-secret -o go-template='{{ index .data "NTFY_AUTH_TOKENS" | base64decode }}')"
token_for() { awk -F, -v u="$1" '{for(i=1;i<=NF;i++){n=split($i,a,":"); if(a[1]==u){print a[2]; exit}}}' <<<"$tokens"; }
seerr_token="$(token_for seerr)"
am_token="$(token_for alertmanager)"
[[ -n "$seerr_token" && -n "$am_token" ]] || { echo 'Could not read seerr/alertmanager tokens from ntfy-secret.' >&2; exit 1; }

# seerr is write-only on media: it must NOT be able to publish to critical.
[[ "$(code -X POST -H "Authorization: Bearer $seerr_token" -d 'verify' "$base_url/critical")" == '403' ]] || { echo 'seerr token could publish to critical (should be denied).' >&2; exit 1; }
# alertmanager is write-only: it must NOT be able to read a topic.
[[ "$(code -H "Authorization: Bearer $am_token" "$base_url/critical/json?poll=1")" == '403' ]] || { echo 'alertmanager token could read critical (should be denied).' >&2; exit 1; }

# Optional positive publish tests actually deliver a notification, so they are guarded.
if [[ "${NTFY_VERIFY_PUBLISH_CONFIRM:-}" == 'publish:ntfy-verify' ]]; then
  [[ "$(code -X POST -H "Authorization: Bearer $seerr_token" -H 'Title: ntfy-verify' -d 'seerr->media ok' "$base_url/media")" == '200' ]] || { echo 'seerr token could not publish to media (should be allowed).' >&2; exit 1; }
  [[ "$(code -X POST -H "Authorization: Bearer $am_token" -H 'Title: ntfy-verify' -d 'alertmanager->critical ok' "$base_url/critical")" == '200' ]] || { echo 'alertmanager token could not publish to critical (should be allowed).' >&2; exit 1; }
  echo 'Positive publish ACLs passed (test notifications delivered to media + critical).'
fi

just kube foundation-verify
echo 'ntfy acceptance passed: Flux + HelmRelease Ready, rollout complete, PVC Bound, gateway /v1/health healthy, anonymous access denied, and least-privilege token ACLs enforced.'
echo
echo 'MANUAL (human acceptance, not automatable here):'
echo '  - subscriber password login can READ all topics and CANNOT publish (enter password on a client).'
echo '  - a unique marker survives a Pod recreation via the persistent cache.'
echo '  - iPhone receives a push on Wi-Fi and off-site via Tailscale VPN On Demand.'
echo '  - re-run with NTFY_VERIFY_PUBLISH_CONFIRM=publish:ntfy-verify to send positive-path test notifications.'
