#!/usr/bin/env bash
# Check the staged session sweeper CronJob, its network path, and the guarded enable
# command without a cluster.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
source scripts/lib/automation-data-bootstrap.sh
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-session-sweeper.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
fail() {
  echo "automation-data session sweeper test failed: $*" >&2
  exit 1
}
app=kubernetes/apps/automation-data/postgresql/app

# check_workload PACKAGE OUTPUT_DIR checks the rendered sweeper workload.
check_workload() {
  local package="$1" out="$2"
  kustomize build "$package" >"$out/rendered.yaml"
  yq ea -o=json 'select(.kind == "CronJob" and .metadata.name == "automation-data-session-sweeper")' \
    "$out/rendered.yaml" >"$out/cronjob.json"
  jq -e '
    .spec.schedule == "*/5 * * * *" and .spec.timeZone == "Etc/UTC" and
    .spec.concurrencyPolicy == "Forbid" and
    .spec.successfulJobsHistoryLimit == 1 and .spec.failedJobsHistoryLimit == 1 and
    .spec.jobTemplate.spec.activeDeadlineSeconds == 240 and
    .spec.jobTemplate.spec.backoffLimit == 0 and
    .spec.jobTemplate.spec.ttlSecondsAfterFinished == 900 and
    (.spec.jobTemplate.spec.template.spec |
      .automountServiceAccountToken == false and .restartPolicy == "Never" and
      .securityContext.runAsNonRoot == true and .securityContext.runAsUser == 70 and
      (.containers | length) == 1 and
      (.containers[0] |
        .image == "postgres:17.11-alpine3.24" and
        .command == ["/bin/sh"] and .args == ["/scripts/sweep-session-logins.sh"] and
        ([.env[].name] == ["PGCONNECT_TIMEOUT","PGDATABASE","PGHOST","PGPORT","PGUSER","PGPASSWORD"]) and
        ([.env[] | select(.name == "PGUSER") | .value] == ["automation_data_session_sweeper"]) and
        ([.env[] | select(.valueFrom) | .valueFrom.secretKeyRef] ==
          [{"name":"automation-data-session-sweeper","key":"password"}]) and
        .securityContext.readOnlyRootFilesystem == true and
        .securityContext.allowPrivilegeEscalation == false))
  ' "$out/cronjob.json" >/dev/null || fail 'the sweeper CronJob is not the reviewed shape'
  sweeper_configmap="$(jq -r '.spec.jobTemplate.spec.template.spec.volumes[] |
    select(.name == "scripts") | .configMap.name' "$out/cronjob.json")"
  [[ "$sweeper_configmap" =~ ^automation-data-session-sweeper-[a-z0-9]+$ ]] ||
    fail 'the sweeper must mount its generated script ConfigMap'
  NAME="$sweeper_configmap" yq ea -o=json 'select(.kind == "ConfigMap" and .metadata.name == strenv(NAME))' \
    "$out/rendered.yaml" >"$out/configmap.json"
  [[ "$(jq -r '.data | keys | join(",")' "$out/configmap.json")" == sweep-session-logins.sh ]] ||
    fail 'the sweeper ConfigMap must contain only the sweep script'
  jq -j '.data."sweep-session-logins.sh"' "$out/configmap.json" |
    cmp -s - "$package/scripts/sweep-session-logins.sh" || fail 'the packaged sweep script differs from source'
  yq ea -e 'select(.kind == "StatefulSet") |
      [.spec.template.spec.volumes[].configMap.name // ""] |
      map(select(test("session-sweeper"))) | length == 0' "$out/rendered.yaml" >/dev/null ||
    fail 'the StatefulSet must not mount the sweeper ConfigMap'
  # Staged: suspended without its Secret. After the operator's writer runs, the
  # encrypted Secret is selected and the CronJob may be resumed.
  if rg -Fxq '  - ./session-sweeper-credentials.sops.yaml' "$package/kustomization.yaml"; then
    yq -o=json "$package/session-sweeper-credentials.sops.yaml" | jq -e '
      .kind == "Secret" and .metadata.name == "automation-data-session-sweeper" and
      .metadata.namespace == "automation-data" and (.stringData | keys) == ["password"] and
      has("sops")' >/dev/null ||
      fail 'a selected sweeper Secret must be the SOPS-encrypted password Secret'
  else
    ! rg -q 'session-sweeper-credentials' "$package/kustomization.yaml" ||
      fail 'the sweeper Secret must be selected exactly as the writer selects it'
    jq -e '.spec.suspend == true' "$out/cronjob.json" >/dev/null ||
      fail 'the sweeper must stay suspended until its Secret is selected'
  fi

}
check_workload "$app" "$temp_dir"
# The enabled state that the operator's writer and a later resume produce. Start
# from the staged package even after the real one selects the Secret.
mkdir -p "$temp_dir/enabled"
cp -R "$app" "$temp_dir/enabled/app"
grep -vxF '  - ./session-sweeper-credentials.sops.yaml' "$app/kustomization.yaml" |
  awk '$0 == "  - ./session-sweeper.yaml" { print "  - ./session-sweeper-credentials.sops.yaml" } { print }' \
    >"$temp_dir/enabled/app/kustomization.yaml"
cat >"$temp_dir/enabled/app/session-sweeper-credentials.sops.yaml" <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: automation-data-session-sweeper
  namespace: automation-data
type: Opaque
stringData:
  password: ENC[synthetic]
sops:
  age:
    - recipient: age1synthetic
YAML
yq -i '.spec.suspend = false' "$temp_dir/enabled/app/session-sweeper.yaml"
check_workload "$temp_dir/enabled/app" "$temp_dir/enabled"

sweeper_egress="$(yq ea -r '
  select(.kind == "CiliumNetworkPolicy" and .metadata.name == "automation-data-session-sweeper") |
  (.spec.endpointSelector.matchLabels."app.kubernetes.io/name") + ";" +
  ((.spec.ingress | length) | tostring) + ";" +
  ([.spec.egress[] | [
    .toEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace",
    (.toEndpoints[0].matchLabels."app.kubernetes.io/name" //
      .toEndpoints[0].matchLabels."k8s:k8s-app"),
    ([.toPorts[0].ports[] | .port + "/" + .protocol] | sort | join("+"))
  ] | join("|")] | sort | join(","))
' "$temp_dir/rendered.yaml")"
[[ "$sweeper_egress" == \
  'automation-data-session-sweeper;0;automation-data|automation-data-postgresql|5432/TCP,kube-system|kube-dns|53/TCP+53/UDP' ]] ||
  fail 'sweeper traffic must be limited to DNS and local PostgreSQL'

# The enable Job runs the packaged wrapper as the backup identity with the Secret value.
configmap="$(yq ea -r 'select(.kind == "ConfigMap" and
  (.metadata.name | test("^automation-data-postgresql-access-sessions-[a-z0-9]+$"))) |
  .metadata.name' "$temp_dir/rendered.yaml")"
if automation_data_session_sweeper_enable_job_manifest job run-1 not-a-configmap >/dev/null 2>&1; then
  fail 'the enable manifest must reject an unexpected ConfigMap name'
fi
automation_data_session_sweeper_enable_job_manifest automation-data-sweeper-run-1 run-1 "$configmap" \
  >"$temp_dir/job.yaml"
yq -o=json "$temp_dir/job.yaml" | jq -e --arg cm "$configmap" '
  .kind == "Job" and .metadata.labels."homelab-talos/run-id" == "run-1" and
  .metadata.labels."homelab-talos/role" == "session-sweeper-enable" and
  .spec.backoffLimit == 0 and
  .spec.template.spec.automountServiceAccountToken == false and
  .spec.template.spec.containers[0].args == ["/scripts/enable-session-sweeper.sh"] and
  ([.spec.template.spec.volumes[] | select(.name == "scripts") | .configMap.name] == [$cm]) and
  ([.spec.template.spec.containers[0].env[] | select(.name == "PGUSER") | .value] ==
    ["automation_data_backup"]) and
  ([.spec.template.spec.containers[0].env[] | select(.name == "SWEEPER_PASSWORD") |
    .valueFrom.secretKeyRef] == [{"name":"automation-data-session-sweeper","key":"password"}])
' >/dev/null || fail 'the enable Job manifest is not the reviewed shape'

if AUTOMATION_DATA_SESSION_SWEEPER_ENABLE_CONFIRM='' \
    scripts/operations/automation-data-session-sweeper-enable.sh "$temp_dir/missing" \
    >"$temp_dir/command.out" 2>"$temp_dir/command.err"; then
  fail 'the enable command must require confirmation'
fi
rg -Fq 'AUTOMATION_DATA_SESSION_SWEEPER_ENABLE_CONFIRM=enable:automation-data:session-sweeper' \
  "$temp_dir/command.err" || fail 'the enable command must name its confirmation'
just --justfile kubernetes/mod.just --dry-run automation-data-session-sweeper-enable >/dev/null 2>&1 ||
  fail 'the automation-data-session-sweeper-enable recipe is missing'

echo 'automation-data session sweeper test passed'
