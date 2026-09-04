#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$repo_root/scripts/verify/nocodb.sh"

[[ -x "$verifier" ]] || {
  echo 'NocoDB verification contract test failed: verifier is missing or not executable.' >&2
  exit 1
}

# The verifier has a deliberately small observation surface. These checks prevent later
# changes from widening it to credential reads, data-plane calls, or mutation.
for forbidden in \
  ' get secret ' ' secrets ' ' exec ' ' port-forward ' \
  ' -X POST' ' -X PATCH' ' -X PUT' ' -X DELETE' \
  'kubectl apply' 'kubectl delete' 'kubectl patch' 'kubectl create' \
  'nocodb.lab.supermorphic.com/api/' 'curl.*nocodb'; do
  ! rg -i -q -- "$forbidden" "$verifier" || {
    echo "NocoDB verification contract test failed: forbidden verifier observation: $forbidden" >&2
    exit 1
  }
done

for allowed in \
  'gatus_results_endpoint_success{name="nocodb", group="Platform"}' \
  'automation_data_postgresql_backup_last_success_timestamp_seconds'; do
  rg -Fq -- "$allowed" "$verifier" || {
    echo "NocoDB verification contract test failed: missing required observation: $allowed" >&2
    exit 1
  }
done

fixture="$(mktemp -d "${TMPDIR:-/tmp}/nocodb-verification-contract-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig" "$fixture/observations.log"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$OBSERVATIONS"
case " $* " in
  *' get kustomization '*|*' get helmrelease '*)
    printf '%s\n' '{"metadata":{"generation":1},"spec":{"suspend":false},"status":{"observedGeneration":1,"conditions":[{"type":"Ready","status":"True","observedGeneration":1}]}}' ;;
  *' get deployment nocodb '*)
    printf '%s\n' '{"metadata":{"generation":1},"spec":{"replicas":1},"status":{"observedGeneration":1,"replicas":1,"updatedReplicas":1,"readyReplicas":1,"availableReplicas":1,"unavailableReplicas":0}}' ;;
  *' get pods '*)
    printf '%s\n' '{"items":[{"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}' ;;
  *' get service nocodb '*)
    printf '%s\n' '{"spec":{"type":"ClusterIP","clusterIP":"10.0.0.1","selector":{"app.kubernetes.io/name":"nocodb"},"ports":[{"port":8080,"targetPort":8080}]}}' ;;
  *' get endpointslice '*)
    printf '%s\n' '{"items":[{"endpoints":[{"conditions":{"ready":true},"targetRef":{"kind":"Pod","name":"nocodb-a"}}],"ports":[{"port":8080}]}]}' ;;
  *' get httproute nocodb '*)
    printf '%s\n' '{"metadata":{"generation":1},"spec":{"hostnames":["nocodb.lab.supermorphic.com"],"parentRefs":[{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"internal","namespace":"networking","sectionName":"https"}]},"status":{"parents":[{"conditions":[{"type":"Accepted","status":"True","observedGeneration":1},{"type":"ResolvedRefs","status":"True","observedGeneration":1}]}]}}' ;;
  *' get ciliumnetworkpolicy nocodb '*)
    printf '%s\n' '{"spec":{"endpointSelector":{"matchLabels":{"app.kubernetes.io/name":"nocodb"}},"ingress":[{"toPorts":[{"ports":[{"port":"8080","protocol":"TCP"}]}]},{"toPorts":[{"ports":[{"port":"8080","protocol":"TCP"}]}]},{"toPorts":[{"ports":[{"port":"8080","protocol":"TCP"}]}]}],"egress":[{"toPorts":[{"ports":[{"port":"53","protocol":"UDP"},{"port":"53","protocol":"TCP"}]}]},{"toPorts":[{"ports":[{"port":"5432","protocol":"TCP"}]}]}]}}' ;;
  *' get persistentvolumeclaim nocodb-data '*)
    printf '%s\n' '{"spec":{"storageClassName":"longhorn","resources":{"requests":{"storage":"10Gi"}},"volumeName":"pvc-volume"},"status":{"phase":"Bound"}}' ;;
  *' get volumes.longhorn.io '*)
    printf '%s\n' '{"items":[{"metadata":{"labels":{"recurring-job-group.longhorn.io/default":"enabled"}},"status":{"kubernetesStatus":{"namespace":"automation-data","pvcName":"nocodb-data","pvName":"pvc-volume"},"state":"attached","robustness":"healthy","replicaModeMap":{"replica-a":"RW","replica-b":"RW"}}}]}' ;;
  *' get prometheusrule nocodb '*)
    printf '%s\n' '{"spec":{"groups":[{"name":"nocodb","rules":[{"alert":"NocoDBAcceptanceJobFailed"},{"alert":"NocoDBAcceptanceJobOverdue"},{"alert":"NocoDBContainerOomKilled"},{"alert":"NocoDBContainerRestarting"},{"alert":"NocoDBDown"},{"alert":"NocoDBMetadataBootstrapJobFailed"},{"alert":"NocoDBMetadataBootstrapJobOverdue"},{"alert":"NocoDBPersistentVolumeClaimNotBound"},{"alert":"NocoDBPersistentVolumeUsageCritical"},{"alert":"NocoDBPersistentVolumeUsageWarning"},{"alert":"NocoDBProbeMissing"},{"alert":"NocoDBWorkloadUnavailable"}]}]}}' ;;
  *) echo "Unexpected Kubernetes observation: $*" >&2; exit 64 ;;
esac
EOF

cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"$OBSERVATIONS"
case " $* " in
  *'/api/v1/rules?type=alert'*)
    printf '%s\n' '{"status":"success","data":{"groups":[{"name":"nocodb","rules":[{"name":"NocoDBAcceptanceJobFailed"},{"name":"NocoDBAcceptanceJobOverdue"},{"name":"NocoDBContainerOomKilled"},{"name":"NocoDBContainerRestarting"},{"name":"NocoDBDown"},{"name":"NocoDBMetadataBootstrapJobFailed"},{"name":"NocoDBMetadataBootstrapJobOverdue"},{"name":"NocoDBPersistentVolumeClaimNotBound"},{"name":"NocoDBPersistentVolumeUsageCritical"},{"name":"NocoDBPersistentVolumeUsageWarning"},{"name":"NocoDBProbeMissing"},{"name":"NocoDBWorkloadUnavailable"}]}]}}' ;;
  *'query=gatus_results_endpoint_success'*|*'query=automation_data_postgresql_backup_last_success_timestamp_seconds'*)
    printf '{"status":"success","data":{"result":[{"value":[0,"'
    if [[ " $* " == *'query=gatus_results_endpoint_success'* ]]; then printf '1'; else date +%s; fi
    printf '"]}]}}\n' ;;
  *) echo "Unexpected Prometheus observation: $*" >&2; exit 65 ;;
esac
EOF
chmod +x "$fixture/bin/kubectl" "$fixture/bin/curl"

PATH="$fixture/bin:$PATH" OBSERVATIONS="$fixture/observations.log" \
  "$verifier" "$fixture/kubeconfig" >/dev/null

while IFS= read -r observation; do
  case "$observation" in
    *' get kustomization '*) ;;
    *' get helmrelease '*) ;;
    *' get deployment '*) ;;
    *' get pods '*) ;;
    *' get service '*) ;;
    *' get endpointslice '*) ;;
    *' get httproute '*) ;;
    *' get ciliumnetworkpolicy '*) ;;
    *' get persistentvolumeclaim '*) ;;
    *' get volumes.longhorn.io '*) ;;
    *' get prometheusrule '*) ;;
    curl\ *) ;;
    *) echo "NocoDB verification contract test failed: disallowed observation: $observation" >&2; exit 1 ;;
  esac
done <"$fixture/observations.log"

echo 'NocoDB verification contract source and fake-observation guards passed.'
