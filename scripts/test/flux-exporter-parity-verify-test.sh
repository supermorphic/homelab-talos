#!/usr/bin/env bash
# Ensure the live verifier rejects a Kubernetes response with the wrong received GVK.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="$repo_root/scripts/verify/flux-exporter-parity.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/flux-exporter-parity-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig"

vector='{"status":"success","data":{"result":[
{"metric":{"customresource_group":"kustomize.toolkit.fluxcd.io","customresource_version":"v1","customresource_kind":"Kustomization","exported_namespace":"flux-system","name":"cluster-apps","ready":"True","suspended":"false"},"value":[1,"1"]},
{"metric":{"customresource_group":"helm.toolkit.fluxcd.io","customresource_version":"v2","customresource_kind":"HelmRelease","exported_namespace":"monitoring","name":"kube-prometheus-stack","ready":"True","suspended":"false"},"value":[1,"1"]},
{"metric":{"customresource_group":"source.toolkit.fluxcd.io","customresource_version":"v1","customresource_kind":"GitRepository","exported_namespace":"flux-system","name":"flux-system","ready":"True","suspended":"false"},"value":[1,"1"]},
{"metric":{"customresource_group":"source.toolkit.fluxcd.io","customresource_version":"v1","customresource_kind":"OCIRepository","exported_namespace":"monitoring","name":"grafana","ready":"True","suspended":"false"},"value":[1,"1"]},
{"metric":{"customresource_group":"source.toolkit.fluxcd.io","customresource_version":"v1","customresource_kind":"HelmRepository","exported_namespace":"monitoring","name":"prometheus-community","ready":"False","suspended":"true"},"value":[1,"1"]}
]}}'
targets='{"status":"success","data":{"activeTargets":[
{"health":"up","discoveredLabels":{"__meta_kubernetes_service_name":"flux-kube-state-metrics","__meta_kubernetes_namespace":"monitoring"},"labels":{"job":"dedicated","instance":"192.0.2.1:8080","pod":"dedicated","service":"flux-kube-state-metrics","endpoint":"http","namespace":"monitoring","container":"kube-state-metrics"}},
{"health":"up","discoveredLabels":{"__meta_kubernetes_service_name":"kube-prometheus-stack-kube-state-metrics","__meta_kubernetes_namespace":"monitoring"},"labels":{"job":"bundled","instance":"192.0.2.2:8080","pod":"bundled","service":"kube-prometheus-stack-kube-state-metrics","endpoint":"http","namespace":"monitoring","container":"kube-state-metrics"}}
]}}'

cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *'/api/v1/targets?state=active'* ]]; then
  [[ -z "${FAKE_CALL_LOG:-}" ]] || printf 'target\n' >>"$FAKE_CALL_LOG"
  [[ "${FAKE_TARGET_MODE:-healthy}" != failed ]] || exit 22
  printf '%s\n' "$FAKE_TARGETS"
else
  [[ -z "${FAKE_CALL_LOG:-}" ]] || printf 'query\n' >>"$FAKE_CALL_LOG"
  printf '%s\n' "$FAKE_VECTOR"
fi
EOF
cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${FAKE_CALL_LOG:-}" ]] || printf 'inventory\n' >>"$FAKE_CALL_LOG"
case " $* " in
  *' kustomizations.v1.kustomize.toolkit.fluxcd.io '*)
    [[ -z "${FAKE_CALL_LOG:-}" ]] || printf 'inventory-resource:kustomizations\n' >>"$FAKE_CALL_LOG"
    [[ "${FAKE_INVENTORY_MODE:-wrong-gvk}" != first-fails ]] || exit 33
    if [[ "${FAKE_INVENTORY_MODE:-wrong-gvk}" == malformed ]]; then
      printf '%s\n' '{not-json'
    elif [[ "${FAKE_INVENTORY_MODE:-wrong-gvk}" == valid ]]; then
      printf '%s\n' '{"apiVersion":"kustomize.toolkit.fluxcd.io/v1","kind":"KustomizationList","items":[{"apiVersion":"kustomize.toolkit.fluxcd.io/v1","kind":"Kustomization","metadata":{"namespace":"flux-system","name":"cluster-apps"},"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    else
      printf '%s\n' '{"apiVersion":"wrong.example.io/v1","kind":"WrongList","items":[{"apiVersion":"wrong.example.io/v1","kind":"WrongKind","metadata":{"namespace":"flux-system","name":"cluster-apps"},"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    fi
    ;;
  *' helmreleases.v2.helm.toolkit.fluxcd.io '*) [[ -z "${FAKE_CALL_LOG:-}" ]] || printf 'inventory-resource:helmreleases\n' >>"$FAKE_CALL_LOG"; printf '%s\n' '{"apiVersion":"helm.toolkit.fluxcd.io/v2","kind":"HelmReleaseList","items":[{"apiVersion":"helm.toolkit.fluxcd.io/v2","kind":"HelmRelease","metadata":{"namespace":"monitoring","name":"kube-prometheus-stack"},"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' ;;
  *' gitrepositories.v1.source.toolkit.fluxcd.io '*) [[ -z "${FAKE_CALL_LOG:-}" ]] || printf 'inventory-resource:gitrepositories\n' >>"$FAKE_CALL_LOG"; printf '%s\n' '{"apiVersion":"source.toolkit.fluxcd.io/v1","kind":"GitRepositoryList","items":[{"apiVersion":"source.toolkit.fluxcd.io/v1","kind":"GitRepository","metadata":{"namespace":"flux-system","name":"flux-system"},"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' ;;
  *' ocirepositories.v1.source.toolkit.fluxcd.io '*) [[ -z "${FAKE_CALL_LOG:-}" ]] || printf 'inventory-resource:ocirepositories\n' >>"$FAKE_CALL_LOG"; printf '%s\n' '{"apiVersion":"source.toolkit.fluxcd.io/v1","kind":"OCIRepositoryList","items":[{"apiVersion":"source.toolkit.fluxcd.io/v1","kind":"OCIRepository","metadata":{"namespace":"monitoring","name":"grafana"},"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' ;;
  *' helmrepositories.v1.source.toolkit.fluxcd.io '*) [[ -z "${FAKE_CALL_LOG:-}" ]] || printf 'inventory-resource:helmrepositories\n' >>"$FAKE_CALL_LOG"; printf '%s\n' '{"apiVersion":"source.toolkit.fluxcd.io/v1","kind":"HelmRepositoryList","items":[{"apiVersion":"source.toolkit.fluxcd.io/v1","kind":"HelmRepository","metadata":{"namespace":"monitoring","name":"prometheus-community"},"spec":{"suspend":true},"status":{"conditions":[{"type":"Ready","status":"False"}]}}]}' ;;
  *) echo "Unexpected kubectl request: $*" >&2; exit 64 ;;
esac
EOF
cat >"$fixture/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$fixture/bin/curl" "$fixture/bin/kubectl" "$fixture/bin/sleep"

assert_invalid_inventory_rejected() {
  local mode="$1"
  local output="$fixture/${mode}.out"
  if PATH="$fixture/bin:$PATH" FAKE_VECTOR="$vector" FAKE_TARGETS="$targets" \
    FAKE_INVENTORY_MODE="$mode" bash "$verifier" "$fixture/kubeconfig" >"$output" 2>&1; then
    echo "Verifier accepted a ${mode} Kubernetes inventory response." >&2
    exit 1
  fi
  rg -Fq 'inventory-invalid-response: kustomize.toolkit.fluxcd.io/v1/Kustomization' "$output" || {
    echo "Verifier did not report the ${mode} Kubernetes inventory response." >&2
    cat "$output" >&2
    exit 1
  }
}

assert_invalid_inventory_rejected wrong-gvk
assert_invalid_inventory_rejected malformed

target_failure_log="$fixture/target-failure.log"
: >"$target_failure_log"
if PATH="$fixture/bin:$PATH" FAKE_VECTOR="$vector" FAKE_TARGETS="$targets" \
  FAKE_CALL_LOG="$target_failure_log" FAKE_TARGET_MODE=failed FAKE_INVENTORY_MODE=valid \
  bash "$verifier" "$fixture/kubeconfig" >"$fixture/target-failure.out" 2>&1; then
  echo 'Verifier unexpectedly accepted failed Prometheus targets.' >&2
  exit 1
fi
[[ "$(rg -c '^target$' "$target_failure_log")" == 12 ]] || {
  echo 'Verifier did not refresh Prometheus targets for every attempt.' >&2
  exit 1
}
[[ "$(rg -c '^query$' "$target_failure_log")" == 48 ]] || {
  echo 'Target failure skipped metric-query refreshes.' >&2
  exit 1
}
inventory_refreshes="$(rg -c '^inventory$' "$target_failure_log")"
[[ "$inventory_refreshes" == 60 ]] || {
  echo "Target failure skipped Kubernetes inventory refreshes: expected 60, got ${inventory_refreshes}." >&2
  exit 1
}

first_inventory_failure_log="$fixture/first-inventory-failure.log"
: >"$first_inventory_failure_log"
if PATH="$fixture/bin:$PATH" FAKE_VECTOR="$vector" FAKE_TARGETS="$targets" \
  FAKE_CALL_LOG="$first_inventory_failure_log" FAKE_INVENTORY_MODE=first-fails \
  bash "$verifier" "$fixture/kubeconfig" >"$fixture/first-inventory-failure.out" 2>&1; then
  echo 'Verifier unexpectedly accepted a failed first Kubernetes inventory request.' >&2
  exit 1
fi
for resource in kustomizations helmreleases gitrepositories ocirepositories helmrepositories; do
  [[ "$(rg -c "^inventory-resource:${resource}$" "$first_inventory_failure_log")" == 12 ]] || {
    echo "First inventory failure skipped ${resource} refreshes." >&2
    exit 1
  }
done

echo 'Flux exporter parity verifier rejects invalid inventory and refreshes all inputs.'
