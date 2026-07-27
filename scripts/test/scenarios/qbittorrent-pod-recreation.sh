#!/usr/bin/env bash
# Phase helper for the Chainsaw qBittorrent pod-recreation resilience test.
set -euo pipefail

[[ "$#" -eq 2 ]] || {
  echo 'Usage: qbittorrent-pod-recreation.sh <prepare|disrupt|observe|assert|recover> <kubeconfig>' >&2
  exit 2
}
phase="$1"
kubeconfig="$2"
repo_root="$(git rev-parse --show-toplevel)"
ns='media'
selector='app.kubernetes.io/name=qbittorrent'
target='qbittorrent-pod-recreation'
timeout_s="${POD_RECREATION_TIMEOUT_S:-300}"
run_dir="${HOMELAB_TEST_RUN_DIR:?HOMELAB_TEST_RUN_DIR is required}"
state="$run_dir/diagnostics/qbittorrent-pod-recreation-state.json"

k() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" "$@"; }
kc() { kubectl --kubeconfig "$kubeconfig" "$@"; }
find_pod() { k get pod -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
app_exec() { k exec "$1" -c app -- "${@:2}"; }
write_recovery() {
  STATUS="$1" REASON="$2" yq --null-input --output-format json \
    '{"status": strenv(STATUS), "reason": strenv(REASON)}' >"$run_dir/recovery.json"
}
read_state() { yq -r "$1" "$state"; }

case "$phase" in
  prepare)
    "$repo_root/scripts/test/safety/require-chaos-confirmation.sh" "$target"
    write_recovery not-attempted 'scenario prepared; recovery not yet attempted'
    pod="$(find_pod)"
    [[ -n "$pod" ]] || { echo 'No qBittorrent pod found.' >&2; exit 3; }
    old_uid="$(k get pod "$pod" -o jsonpath='{.metadata.uid}')"
    pre_volume="$(k get pvc qbittorrent -o jsonpath='{.spec.volumeName}')"
    pre_phase="$(k get pvc qbittorrent -o jsonpath='{.status.phase}')"
    [[ -n "$pre_volume" && "$pre_phase" == 'Bound' ]] || {
      echo "qBittorrent PVC is not Bound ($pre_volume/$pre_phase)." >&2
      exit 3
    }
    pod_json="$(k get pod "$pod" -o json)"
    [[ "$(yq -r '.spec.initContainers[] | select(.name=="gluetun") | .restartPolicy // ""' <<<"$pod_json")" == 'Always' ]]
    [[ "$(yq -r '.spec.initContainers[] | select(.name=="gluetun") | (.startupProbe != null)' <<<"$pod_json")" == 'true' ]]
    [[ "$(yq -r '[.spec.containers[] | select(.name=="app")] | length' <<<"$pod_json")" == '1' ]]
    run_id="$(basename "$run_dir" | tr -cd 'A-Za-z0-9')"
    marker="/config/.pod-recreation-probe-${run_id}"
    token="recreation-${run_id}-$$"
    app_exec "$pod" sh -c "printf '%s' '$token' > '$marker' && sync"
    [[ "$(app_exec "$pod" sh -c "cat '$marker'" | tr -d '\r\n')" == "$token" ]]
    POD="$pod" OLD_UID="$old_uid" PRE_VOLUME="$pre_volume" MARKER="$marker" TOKEN="$token" \
      yq --null-input --output-format json '{
        "oldPod": strenv(POD),
        "oldUid": strenv(OLD_UID),
        "preVolume": strenv(PRE_VOLUME),
        "marker": strenv(MARKER),
        "token": strenv(TOKEN)
      }' >"$state"
    echo "Prepared marker and baseline for qBittorrent pod $pod."
    ;;
  disrupt)
    "$repo_root/scripts/test/safety/require-chaos-confirmation.sh" "$target"
    pod="$(read_state '.oldPod')"
    k delete pod "$pod" --wait=false
    echo "Deleted qBittorrent pod $pod."
    ;;
  observe)
    old_uid="$(read_state '.oldUid')"
    new_pod=''
    violations=0
    samples=0
    deadline=$((EPOCHSECONDS + timeout_s))
    while [[ "$EPOCHSECONDS" -lt "$deadline" ]]; do
      current="$(find_pod)"
      [[ -n "$current" ]] || { sleep 1; continue; }
      current_uid="$(k get pod "$current" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
      [[ -n "$current_uid" && "$current_uid" != "$old_uid" ]] || { sleep 1; continue; }
      new_pod="$current"
      pod_json="$(k get pod "$new_pod" -o json 2>/dev/null || true)"
      [[ -n "$pod_json" ]] || { sleep 1; continue; }
      gluetun_started="$(yq -r '[.status.initContainerStatuses[]? | select(.name=="gluetun") | .started] | .[0] // false' <<<"$pod_json")"
      app_started="$(yq -r '[.status.containerStatuses[]? | select(.name=="app") | .started] | .[0] // false' <<<"$pod_json")"
      app_ready="$(yq -r '[.status.containerStatuses[]? | select(.name=="app") | .ready] | .[0] // false' <<<"$pod_json")"
      samples=$((samples + 1))
      if [[ "$app_started" == 'true' && "$gluetun_started" != 'true' ]]; then
        violations=$((violations + 1))
      fi
      [[ "$app_ready" == 'true' ]] && break
      sleep 1
    done
    [[ -n "$new_pod" ]] || { echo 'No replacement pod appeared.' >&2; exit 1; }
    [[ "$violations" -eq 0 ]] || {
      echo "Observed $violations startup-gate violation(s)." >&2
      exit 1
    }
    pod_json="$(k get pod "$new_pod" -o json)"
    gluetun_started_at="$(yq -r '[.status.initContainerStatuses[]? | select(.name=="gluetun") | .state.running.startedAt] | .[0] // ""' <<<"$pod_json")"
    app_started_at="$(yq -r '[.status.containerStatuses[]? | select(.name=="app") | .state.running.startedAt] | .[0] // ""' <<<"$pod_json")"
    [[ -n "$gluetun_started_at" && -n "$app_started_at" ]]
    [[ ! "$app_started_at" < "$gluetun_started_at" ]] || {
      echo "App started before Gluetun ($app_started_at < $gluetun_started_at)." >&2
      exit 1
    }
    NEW_POD="$new_pod" G_STARTED="$gluetun_started_at" A_STARTED="$app_started_at" \
    SAMPLES="$samples" yq -i '
      .newPod = strenv(NEW_POD) |
      .gluetunStartedAt = strenv(G_STARTED) |
      .appStartedAt = strenv(A_STARTED) |
      .pollSamples = (strenv(SAMPLES) | tonumber)
    ' "$state"
    echo "Observed correct startup ordering across $samples samples."
    ;;
  assert)
    new_pod="$(read_state '.newPod')"
    pre_volume="$(read_state '.preVolume')"
    marker="$(read_state '.marker')"
    token="$(read_state '.token')"
    post_volume="$(k get pvc qbittorrent -o jsonpath='{.spec.volumeName}')"
    post_phase="$(k get pvc qbittorrent -o jsonpath='{.status.phase}')"
    [[ "$post_phase" == 'Bound' && "$post_volume" == "$pre_volume" ]]
    pod_node="$(k get pod "$new_pod" -o jsonpath='{.spec.nodeName}')"
    longhorn_node="$(kc -n longhorn-system get volumes.longhorn.io "$post_volume" -o jsonpath='{.status.currentNodeID}')"
    longhorn_state="$(kc -n longhorn-system get volumes.longhorn.io "$post_volume" -o jsonpath='{.status.state}')"
    [[ "$longhorn_state" == 'attached' && "$longhorn_node" == "$pod_node" ]] || {
      echo "Longhorn volume is $longhorn_state on $longhorn_node, expected attached on $pod_node." >&2
      exit 1
    }
    [[ "$(app_exec "$new_pod" sh -c "cat '$marker' 2>/dev/null" | tr -d '\r\n')" == "$token" ]]
    cp "$state" "$run_dir/evidence.json"
    echo "Same PVC/PV, Longhorn attachment, and marker persistence verified."
    ;;
  recover)
    recovery_ok=true
    k rollout status deployment/qbittorrent --timeout="${timeout_s}s" >/dev/null 2>&1 ||
      recovery_ok=false
    pod="$(find_pod || true)"
    if [[ -f "$state" ]]; then
      marker="$(read_state '.marker')"
      if [[ -n "$pod" ]]; then
        app_exec "$pod" sh -c "rm -f '$marker'" >/dev/null 2>&1 || recovery_ok=false
      else
        recovery_ok=false
      fi
    fi
    if [[ "$recovery_ok" == 'true' ]]; then
      write_recovery passed 'marker removed and qBittorrent rollout healthy'
    else
      write_recovery failed 'marker cleanup or qBittorrent rollout recovery failed'
      exit 1
    fi
    ;;
  *)
    echo "Unknown phase: $phase" >&2
    exit 2
    ;;
esac
