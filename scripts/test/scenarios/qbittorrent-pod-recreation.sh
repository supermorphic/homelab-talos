#!/usr/bin/env bash
# qBittorrent pod-recreation resilience scenario ORCHESTRATOR (follow-up item 5).
# DESTRUCTIVE: deletes the qBittorrent pod and observes the Deployment (strategy:
# Recreate) replace it, proving two boot-time invariants across the recreation:
#
#   1. STARTUP-GATING (start ordering, not just readiness): the app container must not
#      START until Gluetun's native-sidecar startup gate completes. Kubernetes guarantees
#      this for an initContainer with restartPolicy: Always + a startupProbe; this
#      scenario verifies it behaviorally — it never observes app.started while
#      gluetun.started is false, and app.startedAt >= gluetun.startedAt.
#   2. PERSISTENCE: the config PVC re-binds to the SAME Longhorn PV (same volumeName,
#      Bound) and a run-specific marker written to /config survives the recreation.
#
# This is an experiment (an orchestrator), not a measurement probe — hence scripts/test/
# scenarios/, not tests/probes/. Invoked by the thin Chainsaw resilience scenario; also
# runnable directly. Recovery outcome is written to recovery.json so the runner records
# it separately from the primary assertion.
set -euo pipefail

[[ "$#" -eq 1 ]] || { echo 'Usage: qbittorrent-pod-recreation.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
repo_root="$(git rev-parse --show-toplevel)"
ns='media'
selector='app.kubernetes.io/name=qbittorrent'
target='qbittorrent-pod-recreation'
recreate_timeout_s="${POD_RECREATION_TIMEOUT_S:-300}"

# Guard step 2: the scenario's first operation re-invokes the chaos guard before mutating.
"$repo_root/scripts/test/safety/require-chaos-confirmation.sh" "$target"

run_dir="${HOMELAB_TEST_RUN_DIR:-}"
if [[ -z "$run_dir" ]]; then
  mkdir -p "$repo_root/.test-results"
  run_dir="$(mktemp -d "$repo_root/.test-results/$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short=12 HEAD)-pod-recreation.XXXXXX")"
fi
run_id="$(basename "$run_dir" | tr -cd 'A-Za-z0-9')"
marker="/config/.pod-recreation-probe-${run_id}"
token="recreation-${run_id}-$$"
write_recovery() { printf '{"status":"%s","reason":"%s"}\n' "$1" "$2" >"$run_dir/recovery.json"; }
write_recovery 'not-attempted' 'orchestrator started'

k() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" "$@"; }
find_pod() { k get pod -l "$selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }
app_exec() { k exec "$1" -c app -- "${@:2}"; }

pod="$(find_pod)"
[[ -n "$pod" ]] || { echo 'No qbittorrent pod found (is Phase 12 bootstrapped?).' >&2; exit 1; }

# --- pre-state ---------------------------------------------------------------------
old_uid="$(k get pod "$pod" -o jsonpath='{.metadata.uid}')"
pre_volume="$(k get pvc qbittorrent -o jsonpath='{.spec.volumeName}')"
pre_phase="$(k get pvc qbittorrent -o jsonpath='{.status.phase}')"
[[ -n "$pre_volume" && "$pre_phase" == 'Bound' ]] || { echo "Config PVC not Bound at baseline (volume=$pre_volume phase=$pre_phase)." >&2; exit 1; }

# Structural startup-gating: this is what makes the gate a Kubernetes guarantee.
pod_json="$(k get pod "$pod" -o json)"
gluetun_restart="$(yq -r '.spec.initContainers[] | select(.name=="gluetun") | .restartPolicy // ""' <<<"$pod_json")"
gluetun_startup="$(yq -r '.spec.initContainers[] | select(.name=="gluetun") | (.startupProbe != null)' <<<"$pod_json")"
app_is_container="$(yq -r '[.spec.containers[] | select(.name=="app")] | length' <<<"$pod_json")"
[[ "$gluetun_restart" == 'Always' ]] || { echo "gluetun is not a native sidecar (restartPolicy=$gluetun_restart)." >&2; exit 1; }
[[ "$gluetun_startup" == 'true' ]] || { echo 'gluetun has no startup probe; the startup gate is not enforced.' >&2; exit 1; }
[[ "$app_is_container" == '1' ]] || { echo 'app is not a regular container.' >&2; exit 1; }
echo "Structural gate OK: gluetun is a native sidecar (restartPolicy: Always) with a startup probe; app is a regular container."

# Persistence marker: write a run-specific token into /config and read it back.
app_exec "$pod" sh -c "printf '%s' '$token' > '$marker' && sync" >/dev/null
readback="$(app_exec "$pod" sh -c "cat '$marker' 2>/dev/null" | tr -d '\r\n')"
[[ "$readback" == "$token" ]] || { echo "Failed to write the persistence marker before recreation." >&2; exit 1; }
echo "Wrote persistence marker $marker (pre-recreation)."

# --- disrupt: recreate the pod -----------------------------------------------------
passed=false
recover() {
  echo "Recovery: waiting for a healthy qbittorrent rollout."
  if k rollout status deployment/qbittorrent --timeout="${recreate_timeout_s}s" >/dev/null 2>&1; then
    write_recovery 'passed' 'deployment rolled out healthy after recreation'
  else
    write_recovery 'failed' "deployment did not roll out within ${recreate_timeout_s}s"
    return 1
  fi
}
trap '[[ "$passed" == true ]] || recover || true' EXIT

echo "Deleting pod $pod (uid $old_uid) to force recreation (strategy: Recreate)."
k delete pod "$pod" --wait=false >/dev/null 2>&1 || true

# --- startup-gating (temporal, START ordering) -------------------------------------
# Poll the fresh pod frequently; a single observation of app.started while gluetun has
# not started is a hard failure. Backstopped by the retrospective startedAt comparison.
newpod=''
gate_violations=0
poll_samples=0
deadline=$(( $(date +%s) + recreate_timeout_s ))
while [[ "$(date +%s)" -lt "$deadline" ]]; do
  cur="$(find_pod)"
  # Wait for a genuinely new pod (different uid, not the terminating old one).
  if [[ -z "$cur" ]]; then sleep 1; continue; fi
  cur_uid="$(k get pod "$cur" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)"
  [[ -n "$cur_uid" && "$cur_uid" != "$old_uid" ]] || { sleep 1; continue; }
  newpod="$cur"

  s_json="$(k get pod "$newpod" -o json 2>/dev/null || true)"
  [[ -n "$s_json" ]] || { sleep 1; continue; }
  g_started="$(yq -r '[.status.initContainerStatuses[]? | select(.name=="gluetun") | .started] | .[0] // false' <<<"$s_json")"
  a_started="$(yq -r '[.status.containerStatuses[]? | select(.name=="app") | .started] | .[0] // false' <<<"$s_json")"
  a_ready="$(yq -r '[.status.containerStatuses[]? | select(.name=="app") | .ready] | .[0] // false' <<<"$s_json")"
  poll_samples=$(( poll_samples + 1 ))

  if [[ "$a_started" == 'true' && "$g_started" != 'true' ]]; then
    gate_violations=$(( gate_violations + 1 ))
    echo "STARTUP-GATING VIOLATION: app started while gluetun startup gate not complete (sample $poll_samples)." >&2
  fi
  [[ "$a_ready" == 'true' ]] && break
  sleep 1
done

[[ -n "$newpod" ]] || { echo 'No replacement pod became visible within the timeout.' >&2; exit 1; }
[[ "$gate_violations" -eq 0 ]] || { echo "Startup gate breached: $gate_violations observation(s) of app started before gluetun." >&2; exit 1; }

# Wait for full readiness, then retrospective assertions.
k rollout status deployment/qbittorrent --timeout="${recreate_timeout_s}s" >/dev/null
newpod="$(find_pod)"
final_json="$(k get pod "$newpod" -o json)"
g_started_at="$(yq -r '[.status.initContainerStatuses[]? | select(.name=="gluetun") | .state.running.startedAt] | .[0] // ""' <<<"$final_json")"
a_started_at="$(yq -r '[.status.containerStatuses[]? | select(.name=="app") | .state.running.startedAt] | .[0] // ""' <<<"$final_json")"
g_ready="$(yq -r '[.status.initContainerStatuses[]? | select(.name=="gluetun") | .ready] | .[0] // false' <<<"$final_json")"
a_ready="$(yq -r '[.status.containerStatuses[]? | select(.name=="app") | .ready] | .[0] // false' <<<"$final_json")"
[[ -n "$g_started_at" && -n "$a_started_at" ]] || { echo 'Missing container startedAt timestamps after recreation.' >&2; exit 1; }
# ISO8601 UTC (…Z) is lexicographically ordered, so a string compare is a time compare.
[[ ! "$a_started_at" < "$g_started_at" ]] || { echo "Start-ordering violation: app startedAt ($a_started_at) < gluetun startedAt ($g_started_at)." >&2; exit 1; }
# app.ready implies gluetun.ready.
if [[ "$a_ready" == 'true' && "$g_ready" != 'true' ]]; then
  echo 'Readiness-relationship violation: app is Ready while gluetun is not.' >&2; exit 1
fi
echo "Startup gating held: no premature-start observations ($poll_samples samples); app startedAt $a_started_at >= gluetun startedAt $g_started_at."

# --- persistence (PV identity + marker round-trip) ---------------------------------
post_volume="$(k get pvc qbittorrent -o jsonpath='{.spec.volumeName}')"
post_phase="$(k get pvc qbittorrent -o jsonpath='{.status.phase}')"
[[ "$post_phase" == 'Bound' ]] || { echo "Config PVC not Bound after recreation (phase=$post_phase)." >&2; exit 1; }
[[ "$post_volume" == "$pre_volume" ]] || { echo "Config PVC re-bound to a DIFFERENT volume ($pre_volume -> $post_volume); persistence not guaranteed." >&2; exit 1; }
marker_after="$(app_exec "$newpod" sh -c "cat '$marker' 2>/dev/null" | tr -d '\r\n' || true)"
[[ "$marker_after" == "$token" ]] || { echo "Persistence marker missing or changed after recreation (got '$marker_after')." >&2; exit 1; }
# Cleanup the run-specific marker (best-effort; does not gate the primary result).
app_exec "$newpod" sh -c "rm -f '$marker'" >/dev/null 2>&1 || echo "Warning: could not remove marker $marker; remove it manually." >&2
echo "Persistence held: config PVC re-attached the same PV $post_volume (Bound); marker survived recreation."

# --- evidence + recovery status ----------------------------------------------------
recover
RUN_TARGET="$target" OLD_POD="$pod" NEW_POD="$newpod" PRE_VOL="$pre_volume" POST_VOL="$post_volume" \
G_STARTED_AT="$g_started_at" A_STARTED_AT="$a_started_at" GATE_VIOLATIONS="$gate_violations" POLL_SAMPLES="$poll_samples" \
  yq --null-input --output-format json '{
    "target": strenv(RUN_TARGET),
    "oldPod": strenv(OLD_POD),
    "newPod": strenv(NEW_POD),
    "persistence": {"preVolume": strenv(PRE_VOL), "postVolume": strenv(POST_VOL), "sameVolume": (strenv(PRE_VOL) == strenv(POST_VOL))},
    "startupGating": {
      "gluetunStartedAt": strenv(G_STARTED_AT),
      "appStartedAt": strenv(A_STARTED_AT),
      "appStartedAfterGluetun": (strenv(A_STARTED_AT) >= strenv(G_STARTED_AT)),
      "prematureStartObservations": (strenv(GATE_VIOLATIONS) | tonumber),
      "pollSamples": (strenv(POLL_SAMPLES) | tonumber)
    }
  }' >"$run_dir/evidence.json"

passed=true
trap - EXIT
echo "PASS: pod recreation held both invariants — startup gating (app starts only after gluetun's gate) and persistence (same PV + marker survived). Evidence: $run_dir"
