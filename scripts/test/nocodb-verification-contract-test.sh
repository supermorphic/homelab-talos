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
  'kubectl apply' 'kubectl delete' 'kubectl patch' 'kubectl create' \
  'nocodb.lab.supermorphic.com/api/' 'curl.*nocodb'; do
  ! rg -i -q -- "$forbidden" "$verifier" || {
    echo "NocoDB verification contract test failed: forbidden verifier observation: $forbidden" >&2
    exit 1
  }
done

for forbidden_curl_option in \
  '(^|[[:space:]])-X([^[:space:]]*)?' \
  '--request(=|[[:space:]])'; do
  ! rg -i -q -- "$forbidden_curl_option" "$verifier" || {
    echo "NocoDB verification contract test failed: forbidden curl option: $forbidden_curl_option" >&2
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
  *' get deployments '*)
    if [[ "${FIXTURE_CASE:-healthy}" == worker ]]; then
      printf '%s\n' '{"items":[{"metadata":{"name":"nocodb"}},{"metadata":{"name":"nocodb-worker"}}]}'
    else
      printf '%s\n' '{"items":[{"metadata":{"name":"nocodb"}}]}'
    fi ;;
  *' get deployment nocodb '*)
    printf '%s\n' '{"metadata":{"generation":1},"spec":{"replicas":1},"status":{"observedGeneration":1,"replicas":1,"updatedReplicas":1,"readyReplicas":1,"availableReplicas":1,"unavailableReplicas":0}}' ;;
  *' get pods '*)
    if [[ "${FIXTURE_CASE:-healthy}" == redis-pod && " $* " == *' get pods --output json '* ]]; then
      printf '%s\n' '{"items":[{"metadata":{"name":"nocodb","labels":{"app.kubernetes.io/name":"nocodb"}},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"redis","labels":{"app.kubernetes.io/name":"redis"}}}]}'
    else
      printf '%s\n' '{"items":[{"status":{"phase":"Running","conditions":[{"type":"Ready","status":"True"}]}}]}'
    fi ;;
  *' get services '*)
    if [[ "${FIXTURE_CASE:-healthy}" == redis-service ]]; then
      printf '%s\n' '{"items":[{"metadata":{"name":"nocodb","labels":{"app.kubernetes.io/name":"nocodb"}}},{"metadata":{"name":"nocodb-redis","labels":{"app.kubernetes.io/name":"redis"}}}]}'
    else
      printf '%s\n' '{"items":[{"metadata":{"name":"nocodb","labels":{"app.kubernetes.io/name":"nocodb"}}},{"metadata":{"name":"automation-data-postgresql","labels":{"app.kubernetes.io/name":"automation-data-postgresql"}}}]}'
    fi ;;
  *' get service nocodb '*)
    printf '%s\n' '{"spec":{"type":"ClusterIP","clusterIP":"10.0.0.1","selector":{"app.kubernetes.io/name":"nocodb"},"ports":[{"port":8080,"targetPort":8080}]}}' ;;
  *' get endpointslice '*)
    printf '%s\n' '{"items":[{"endpoints":[{"conditions":{"ready":true},"targetRef":{"kind":"Pod","name":"nocodb-a"}}],"ports":[{"port":8080}]}]}' ;;
  *' get httproute nocodb '*)
    printf '%s\n' '{"metadata":{"generation":1},"spec":{"hostnames":["nocodb.lab.supermorphic.com"],"parentRefs":[{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"internal","namespace":"networking","sectionName":"https"}]},"status":{"parents":[{"conditions":[{"type":"Accepted","status":"True","observedGeneration":1},{"type":"ResolvedRefs","status":"True","observedGeneration":1}]}]}}' ;;
  *' get ciliumnetworkpolicy nocodb '*)
    if [[ "${FIXTURE_CASE:-healthy}" == policy-broadened ]]; then
      printf '%s\n' '{"spec":{"endpointSelector":{"matchLabels":{"app.kubernetes.io/name":"nocodb"}},"ingress":[{"fromEndpoints":[{"matchLabels":{"k8s:io.kubernetes.pod.namespace":"wrong"}}],"fromEntities":["world"],"toPorts":[{"ports":[{"port":"8080","protocol":"TCP"}]}]},{"fromEndpoints":[{"matchLabels":{"k8s:io.kubernetes.pod.namespace":"automation","app.kubernetes.io/name":"n8n"}}],"toPorts":[{"ports":[{"port":"8080","protocol":"TCP"}]}]},{"fromEntities":["host","remote-node"],"toPorts":[{"ports":[{"port":"8080","protocol":"TCP"}]}]}],"egress":[{"toEndpoints":[{"matchLabels":{"k8s:io.kubernetes.pod.namespace":"kube-system","k8s:k8s-app":"kube-dns"}}],"toPorts":[{"ports":[{"port":"53","protocol":"UDP"},{"port":"53","protocol":"TCP"}]}]},{"toEndpoints":[{"matchLabels":{"k8s:io.kubernetes.pod.namespace":"automation-data","app.kubernetes.io/name":"automation-data-postgresql"}}],"toPorts":[{"ports":[{"port":"5432","protocol":"TCP"}]}]}]}}'
    else
      policy='{ "spec": {"endpointSelector":{"matchLabels":{"app.kubernetes.io/name":"nocodb"}},"ingress":[{"fromEndpoints":[{"matchLabels":{"k8s:io.kubernetes.pod.namespace":"envoy-gateway-system","gateway.envoyproxy.io/owning-gateway-name":"internal","gateway.envoyproxy.io/owning-gateway-namespace":"networking"}}],"toPorts":[{"ports":[{"port":"8080","protocol":"TCP"}]}]},{"fromEndpoints":[{"matchLabels":{"k8s:io.kubernetes.pod.namespace":"automation","app.kubernetes.io/name":"n8n"}}],"toPorts":[{"ports":[{"port":"8080","protocol":"TCP"}]}]},{"fromEntities":["host","remote-node"],"toPorts":[{"ports":[{"port":"8080","protocol":"TCP"}]}]}],"egress":[{"toEndpoints":[{"matchLabels":{"k8s:io.kubernetes.pod.namespace":"kube-system","k8s:k8s-app":"kube-dns"}}],"toPorts":[{"ports":[{"port":"53","protocol":"UDP"},{"port":"53","protocol":"TCP"}]}]},{"toEndpoints":[{"matchLabels":{"k8s:io.kubernetes.pod.namespace":"automation-data","app.kubernetes.io/name":"automation-data-postgresql"}}],"toPorts":[{"ports":[{"port":"5432","protocol":"TCP"}]}]}]}}'
      case "${FIXTURE_CASE:-healthy}" in
        policy-extra-auth|policy-extra-cidr|policy-extra-to-cidr|policy-extra-entity|policy-extra-fqdn|policy-extra-expression|policy-extra-l7|policy-extra-rule)
          policy="$(FIXTURE_CASE="${FIXTURE_CASE:-healthy}" python -c '
import json
import os
import sys

document = json.load(sys.stdin)
spec = document["spec"]
case = os.environ["FIXTURE_CASE"]
if case == "policy-extra-auth":
    spec["authentication"] = {"mode": "required"}
elif case == "policy-extra-cidr":
    spec["ingress"][0]["fromCIDR"] = ["192.0.2.0/24"]
elif case == "policy-extra-to-cidr":
    spec["egress"][0]["toCIDR"] = ["192.0.2.0/24"]
elif case == "policy-extra-entity":
    spec["egress"][0]["toEntities"] = ["world"]
elif case == "policy-extra-fqdn":
    spec["egress"][0]["toFQDNs"] = [{"matchName": "example.invalid"}]
elif case == "policy-extra-expression":
    spec["ingress"][0]["fromEndpoints"][0]["matchExpressions"] = [{"key": "role", "operator": "Exists"}]
elif case == "policy-extra-l7":
    spec["ingress"][0]["toPorts"][0]["rules"] = {"http": [{"method": "GET"}]}
elif case == "policy-extra-rule":
    spec["ingress"].append({"fromEntities": ["world"], "toPorts": [{"ports": [{"port": "8080", "protocol": "TCP"}]}]})
print(json.dumps(document, separators=(",", ":")))
' <<<"$policy")"
          ;;
      esac
      printf '%s\n' "$policy"
    fi ;;
  *' get persistentvolumeclaim nocodb-data '*)
    printf '%s\n' '{"spec":{"storageClassName":"longhorn","resources":{"requests":{"storage":"10Gi"}},"volumeName":"pvc-volume"},"status":{"phase":"Bound"}}' ;;
  *' get volumes.longhorn.io '*)
    if [[ "${FIXTURE_CASE:-healthy}" == longhorn-third-failed ]]; then
      printf '%s\n' '{"items":[{"metadata":{"labels":{"recurring-job-group.longhorn.io/default":"enabled"}},"spec":{"numberOfReplicas":2},"status":{"kubernetesStatus":{"namespace":"automation-data","pvcName":"nocodb-data","pvName":"pvc-volume"},"state":"attached","robustness":"healthy","replicaModeMap":{"replica-a":"RW","replica-b":"RW","replica-c":"ERR"}}}]}'
    elif [[ "${FIXTURE_CASE:-healthy}" == longhorn-attached-wo ]]; then
      printf '%s\n' '{"items":[{"metadata":{"labels":{"recurring-job-group.longhorn.io/default":"enabled"}},"spec":{"numberOfReplicas":2},"status":{"kubernetesStatus":{"namespace":"automation-data","pvcName":"nocodb-data","pvName":"pvc-volume"},"state":"attached","robustness":"healthy","replicaModeMap":{"replica-a":"RW","replica-b":"WO"}}}]}'
    elif [[ "${FIXTURE_CASE:-healthy}" == longhorn-missing-config ]]; then
      printf '%s\n' '{"items":[{"metadata":{"labels":{"recurring-job-group.longhorn.io/default":"enabled"}},"status":{"kubernetesStatus":{"namespace":"automation-data","pvcName":"nocodb-data","pvName":"pvc-volume"},"state":"attached","robustness":"healthy","replicaModeMap":{"replica-a":"RW","replica-b":"RW"}}}]}'
    elif [[ "${FIXTURE_CASE:-healthy}" == longhorn-detached-bad ]]; then
      printf '%s\n' '{"items":[{"metadata":{"labels":{"recurring-job-group.longhorn.io/default":"enabled"}},"spec":{"numberOfReplicas":2},"status":{"kubernetesStatus":{"namespace":"automation-data","pvcName":"nocodb-data","pvName":"pvc-volume"},"state":"detached","robustness":"unknown","replicaModeMap":{"replica-a":"RW","replica-b":"ERR"}}}]}'
    elif [[ "${FIXTURE_CASE:-healthy}" == longhorn-detached-healthy ]]; then
      printf '%s\n' '{"items":[{"metadata":{"labels":{"recurring-job-group.longhorn.io/default":"enabled"}},"spec":{"numberOfReplicas":2},"status":{"kubernetesStatus":{"namespace":"automation-data","pvcName":"nocodb-data","pvName":"pvc-volume"},"state":"detached","robustness":"unknown","replicaModeMap":{}}}]}'
    elif [[ "${FIXTURE_CASE:-healthy}" == longhorn-detached-rw ]]; then
      printf '%s\n' '{"items":[{"metadata":{"labels":{"recurring-job-group.longhorn.io/default":"enabled"}},"spec":{"numberOfReplicas":2},"status":{"kubernetesStatus":{"namespace":"automation-data","pvcName":"nocodb-data","pvName":"pvc-volume"},"state":"detached","robustness":"unknown","replicaModeMap":{"replica-a":"RW"}}}]}'
    elif [[ "${FIXTURE_CASE:-healthy}" == longhorn-detached-wo ]]; then
      printf '%s\n' '{"items":[{"metadata":{"labels":{"recurring-job-group.longhorn.io/default":"enabled"}},"spec":{"numberOfReplicas":2},"status":{"kubernetesStatus":{"namespace":"automation-data","pvcName":"nocodb-data","pvName":"pvc-volume"},"state":"detached","robustness":"unknown","replicaModeMap":{"replica-a":"WO"}}}]}'
    elif [[ "${FIXTURE_CASE:-healthy}" == longhorn-detached-err ]]; then
      printf '%s\n' '{"items":[{"metadata":{"labels":{"recurring-job-group.longhorn.io/default":"enabled"}},"spec":{"numberOfReplicas":2},"status":{"kubernetesStatus":{"namespace":"automation-data","pvcName":"nocodb-data","pvName":"pvc-volume"},"state":"detached","robustness":"unknown","replicaModeMap":{"replica-a":"ERR"}}}]}'
    elif [[ "${FIXTURE_CASE:-healthy}" == longhorn-detached-missing-config ]]; then
      printf '%s\n' '{"items":[{"metadata":{"labels":{"recurring-job-group.longhorn.io/default":"enabled"}},"status":{"kubernetesStatus":{"namespace":"automation-data","pvcName":"nocodb-data","pvName":"pvc-volume"},"state":"detached","robustness":"unknown","replicaModeMap":{}}}]}'
    else
      printf '%s\n' '{"items":[{"metadata":{"labels":{"recurring-job-group.longhorn.io/default":"enabled"}},"spec":{"numberOfReplicas":2},"status":{"kubernetesStatus":{"namespace":"automation-data","pvcName":"nocodb-data","pvName":"pvc-volume"},"state":"attached","robustness":"healthy","replicaModeMap":{"replica-a":"RW","replica-b":"RW"}}}]}'
    fi ;;
  *' get prometheusrule nocodb '*)
    printf '%s\n' '{"spec":{"groups":[{"name":"nocodb","rules":[{"alert":"NocoDBAcceptanceJobFailed"},{"alert":"NocoDBAcceptanceJobOverdue"},{"alert":"NocoDBContainerOomKilled"},{"alert":"NocoDBContainerRestarting"},{"alert":"NocoDBDown"},{"alert":"NocoDBMetadataBootstrapJobFailed"},{"alert":"NocoDBMetadataBootstrapJobOverdue"},{"alert":"NocoDBPersistentVolumeClaimNotBound"},{"alert":"NocoDBPersistentVolumeUsageCritical"},{"alert":"NocoDBPersistentVolumeUsageWarning"},{"alert":"NocoDBProbeMissing"},{"alert":"NocoDBWorkloadUnavailable"}]}]}}' ;;
  *) echo "Unexpected Kubernetes observation: $*" >&2; exit 64 ;;
esac
EOF

cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"$OBSERVATIONS"
get_count=0
data_count=0
data_argument=''
url=''
while (($#)); do
  argument="$1"
  shift
  case "$argument" in
    -X*|--request|--request=*|-d|--data|--data=*|--form*|--upload-file)
      echo "Mutation-capable curl option rejected: $argument" >&2
      exit 66 ;;
    --silent|--show-error|--fail) ;;
    --max-time)
      [[ "${1:-}" == 20 ]] || { echo 'Unexpected curl timeout.' >&2; exit 65; }
      shift ;;
    --resolve)
      [[ "${1:-}" == 'prometheus.lab.supermorphic.com:443:192.168.90.30' ]] || {
        echo 'Unexpected curl resolve target.' >&2
        exit 65
      }
      shift ;;
    --get) ((get_count += 1)) ;;
    --data-urlencode)
      [[ -n "${1:-}" ]] || { echo 'Missing Prometheus query.' >&2; exit 65; }
      data_argument="$1"
      ((data_count += 1))
      shift ;;
    https://prometheus.lab.supermorphic.com/*)
      [[ -z "$url" ]] || { echo 'Multiple Prometheus URLs are not allowed.' >&2; exit 65; }
      url="$argument" ;;
    *) echo "Unexpected Prometheus curl argument: $argument" >&2; exit 65 ;;
  esac
done

case "$url" in
  'https://prometheus.lab.supermorphic.com/api/v1/rules?type=alert')
    [[ "$get_count" == 0 && "$data_count" == 0 ]] || {
      echo 'Unexpected Prometheus rules request options.' >&2
      exit 65
    }
    if [[ "${FIXTURE_CASE:-healthy}" == rules-unhealthy ]]; then
      printf '%s\n' '{"status":"success","data":{"groups":[{"name":"nocodb","rules":[{"name":"NocoDBAcceptanceJobFailed","health":"ok","lastError":""},{"name":"NocoDBAcceptanceJobOverdue","health":"err","lastError":"bad query"},{"name":"NocoDBContainerOomKilled","health":"ok","lastError":""},{"name":"NocoDBContainerRestarting","health":"ok","lastError":""},{"name":"NocoDBDown","health":"ok","lastError":""},{"name":"NocoDBMetadataBootstrapJobFailed","health":"ok","lastError":""},{"name":"NocoDBMetadataBootstrapJobOverdue","health":"ok","lastError":""},{"name":"NocoDBPersistentVolumeClaimNotBound","health":"ok","lastError":""},{"name":"NocoDBPersistentVolumeUsageCritical","health":"ok","lastError":""},{"name":"NocoDBPersistentVolumeUsageWarning","health":"ok","lastError":""},{"name":"NocoDBProbeMissing","health":"ok","lastError":""},{"name":"NocoDBWorkloadUnavailable","health":"ok","lastError":""}]}]}}'
    else
      printf '%s\n' '{"status":"success","data":{"groups":[{"name":"nocodb","rules":[{"name":"NocoDBAcceptanceJobFailed","health":"ok","lastError":""},{"name":"NocoDBAcceptanceJobOverdue","health":"ok","lastError":""},{"name":"NocoDBContainerOomKilled","health":"ok","lastError":""},{"name":"NocoDBContainerRestarting","health":"ok","lastError":""},{"name":"NocoDBDown","health":"ok","lastError":""},{"name":"NocoDBMetadataBootstrapJobFailed","health":"ok","lastError":""},{"name":"NocoDBMetadataBootstrapJobOverdue","health":"ok","lastError":""},{"name":"NocoDBPersistentVolumeClaimNotBound","health":"ok","lastError":""},{"name":"NocoDBPersistentVolumeUsageCritical","health":"ok","lastError":""},{"name":"NocoDBPersistentVolumeUsageWarning","health":"ok","lastError":""},{"name":"NocoDBProbeMissing","health":"ok","lastError":""},{"name":"NocoDBWorkloadUnavailable","health":"ok","lastError":""}]}]}}'
    fi ;;
  'https://prometheus.lab.supermorphic.com/api/v1/query')
    case "$data_argument" in
      'query=gatus_results_endpoint_success{name="nocodb", group="Platform"}'|\
      'query=automation_data_postgresql_backup_last_success_timestamp_seconds{namespace="automation-data",service="automation-data-postgresql"}') ;;
      *) echo "Unexpected Prometheus query: $data_argument" >&2; exit 65 ;;
    esac
    [[ "$get_count" == 1 && "$data_count" == 1 ]] || {
      echo 'Unexpected Prometheus query request options.' >&2
      exit 65
    }
    printf '{"status":"success","data":{"result":[{"value":[0,"'
    if [[ "$data_argument" == query=gatus_results_endpoint_success* ]]; then
      [[ "${FIXTURE_CASE:-healthy}" == gatus-down ]] && printf '0' || printf '1'
    else
      date +%s
    fi
    printf '"]}]}}\n' ;;
  *) echo "Unexpected Prometheus observation: $url" >&2; exit 65 ;;
esac
EOF
chmod +x "$fixture/bin/kubectl" "$fixture/bin/curl"

PATH="$fixture/bin:$PATH" OBSERVATIONS="$fixture/observations.log" \
  "$verifier" "$fixture/kubeconfig" >/dev/null

expect_fixture_failure() {
  local fixture_case="$1" fixture_output
  if fixture_output="$(PATH="$fixture/bin:$PATH" OBSERVATIONS="$fixture/observations.log" \
    FIXTURE_CASE="$fixture_case" "$verifier" "$fixture/kubeconfig" 2>&1)"; then
    echo "NocoDB verification contract test failed: $fixture_case was accepted." >&2
    exit 1
  fi
  case "$fixture_output" in
    *'Mutation-capable curl option rejected'*|*'Unexpected Prometheus '*|*'Unexpected curl '*|*'Missing Prometheus query'*|*'Multiple Prometheus URLs'*)
      echo "NocoDB verification contract test failed: $fixture_case violated the curl trace contract." >&2
      exit 1 ;;
  esac
}

expect_fixture_failure worker
expect_fixture_failure redis-pod
expect_fixture_failure redis-service
expect_fixture_failure policy-broadened
expect_fixture_failure policy-extra-auth
expect_fixture_failure policy-extra-cidr
expect_fixture_failure policy-extra-to-cidr
expect_fixture_failure policy-extra-entity
expect_fixture_failure policy-extra-fqdn
expect_fixture_failure policy-extra-expression
expect_fixture_failure policy-extra-l7
expect_fixture_failure policy-extra-rule
expect_fixture_failure longhorn-third-failed
expect_fixture_failure longhorn-attached-wo
expect_fixture_failure longhorn-missing-config
expect_fixture_failure longhorn-detached-bad
expect_fixture_failure longhorn-detached-rw
expect_fixture_failure longhorn-detached-wo
expect_fixture_failure longhorn-detached-err
expect_fixture_failure longhorn-detached-missing-config
expect_fixture_failure rules-unhealthy
expect_fixture_failure gatus-down

PATH="$fixture/bin:$PATH" OBSERVATIONS="$fixture/observations.log" \
  FIXTURE_CASE=longhorn-detached-healthy "$verifier" "$fixture/kubeconfig" >/dev/null

if PATH="$fixture/bin:$PATH" OBSERVATIONS="$fixture/observations.log" \
  "$fixture/bin/curl" --request POST 'https://prometheus.lab.supermorphic.com/api/v1/query' >/dev/null 2>&1; then
  echo 'NocoDB verification contract test failed: fake curl accepted a mutation request.' >&2
  exit 1
fi

while IFS= read -r observation; do
  case "$observation" in
    *' get kustomization '*) ;;
    *' get helmrelease '*) ;;
    *' get deployments '*) ;;
    *' get deployment '*) ;;
    *' get pods '*) ;;
    *' get service '*) ;;
    *' get services '*) ;;
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
