#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/recovery-verification-chain.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
cat >"$fixture/kubeconfig" <<'EOF'
apiVersion: v1
kind: Config
contexts:
  - name: fixture
    context: {cluster: fixture, user: fixture}
EOF
cat >"$fixture/talosconfig" <<'EOF'
context: fixture
contexts:
  fixture: {endpoints: [192.168.90.10]}
EOF
trace="$fixture/trace"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >>"$RECOVERY_FIXTURE_TRACE"
[[ " $* " == *' --kubeconfig '* && " $* " == *' --context fixture '* ]] || {
  echo 'kubectl omitted the explicit fixture context' >&2
  exit 65
}
case " $* " in
  *' create '*|*' replace '*|*' patch '*|*' delete '*|*' apply '*|*' cordon '*|*' uncordon '*|*' drain '*)
    echo 'recovery verifier attempted a Kubernetes mutation' >&2
    exit 66 ;;
  *' config view --minify '*) printf '%s' 'https://192.168.90.20:6443' ;;
  *' get nodes --output json '*)
    if [[ "${RECOVERY_FIXTURE_NODE_CASE:-}" == baseline-contained ]]; then
      printf '%s\n' '{"items":[{"metadata":{"name":"nuc1"},"spec":{"unschedulable":true},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc2"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc3"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    elif [[ "${RECOVERY_FIXTURE_NODE_CASE:-}" == wrong-record ]]; then
      printf '%s\n' '{"items":[{"metadata":{"name":"nuc1","annotations":{"homelab.supermorphic.com/node-lifecycle":"{\"schemaVersion\":1,\"kind\":\"abrupt-loss\"}"}},"spec":{"unschedulable":true},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc2"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc3"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    elif [[ "$RECOVERY_MODE" == recovery ]]; then
      printf '%s\n' '{"items":[{"metadata":{"name":"nuc1","annotations":{"homelab.supermorphic.com/node-lifecycle":"{\"schemaVersion\":1,\"kind\":\"reboot\"}"}},"spec":{"unschedulable":true},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc2"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc3"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    else
      printf '%s\n' '{"items":[{"metadata":{"name":"nuc1"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc2"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}},{"metadata":{"name":"nuc3"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    fi ;;
  *' get helmrelease cilium '*) printf '%s\n' '{"metadata":{"generation":1},"spec":{"releaseName":"cilium"},"status":{"observedGeneration":1,"conditions":[{"type":"Ready","status":"True"}],"history":[{"chartName":"cilium","chartVersion":"1.19.6+b8d600c542c9"}]}}' ;;
  *' get ocirepository cilium '*) printf '%s\n' '{"spec":{"ref":{"tag":"1.19.6"}},"status":{"conditions":[{"type":"Ready","status":"True"}],"artifact":{"revision":"1.19.6@sha256:b8d600c542c97dc8652429e12487ecce922d73de9785505457a8f653833e75f9"}}}' ;;
  *' get configmap cilium-values '*) cat kubernetes/apps/kube-system/cilium/app/values.yaml ;;
  *' get daemonset cilium '*) printf '%s\n' '{"status":{"desiredNumberScheduled":3,"numberReady":3,"numberUnavailable":0}}' ;;
  *' get deployment cilium-operator '*) printf '%s\n' '{"spec":{"replicas":2},"status":{"availableReplicas":2}}' ;;
  *' get deployment hubble-relay '*) printf '%s\n' '{"spec":{"replicas":1},"status":{"availableReplicas":1}}' ;;
  *' get deployment coredns '*) printf '%s\n' '{"status":{"availableReplicas":1}}' ;;
  *' get daemonset kube-proxy '*|*' get deployment hubble-ui '*|*' get daemonset cilium-envoy '*|*' wait '*|*' rollout status '*) ;;
  *' get deployment source-controller '*|*' get deployment kustomize-controller '*|*' get deployment helm-controller '*|*' get deployment notification-controller '*) printf '1' ;;
  *' get gitrepository flux-system '*) printf '%s\n' "{\"spec\":{\"url\":\"ssh://git@ssh.github.com:443/supermorphic/homelab-talos\",\"ref\":{\"branch\":\"main\"}},\"status\":{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}],\"artifact\":{\"revision\":\"main@sha1:$RECOVERY_SOURCE_REVISION\"}}}" ;;
  *' get kustomization '*) printf '%s\n' '{"spec":{"suspend":false},"status":{"conditions":[{"type":"Ready","status":"True"}]}}' ;;
  *' get deployment cert-manager '*|*' get deployment cert-manager-webhook '*|*' get deployment cert-manager-cainjector '*) printf '%s\n' '{"spec":{"replicas":2},"status":{"availableReplicas":2}}' ;;
  *' get deployment metallb-controller '*) printf '%s\n' '{"spec":{"replicas":1},"status":{"availableReplicas":1}}' ;;
  *' get daemonset metallb-speaker '*) printf '%s\n' '{"status":{"desiredNumberScheduled":3,"numberReady":3,"numberUnavailable":0}}' ;;
  *' get ipaddresspool internal '*) printf '%s\n' '{"spec":{"addresses":["192.168.90.30-192.168.90.38"],"autoAssign":false}}' ;;
  *' get daemonset frr-k8s-daemon '*) ;;
  *' get gatewayclass internal '*) printf '%s\n' '{"status":{"conditions":[{"type":"Accepted","status":"True"}]}}' ;;
  *' get gateway internal '*) printf '%s\n' '{"status":{"conditions":[{"type":"Programmed","status":"True"}],"addresses":[{"value":"192.168.90.30"}],"listeners":[{"name":"https","conditions":[{"type":"Accepted","status":"True"}]}]}}' ;;
  *' get services '*) printf '%s\n' '{"items":[{"metadata":{"name":"envoy-internal"},"spec":{"type":"LoadBalancer"},"status":{"loadBalancer":{"ingress":[{"ip":"192.168.90.30"}]}}}]}' ;;
  *' get deployments '*) printf '%s\n' '{"items":[{"metadata":{"labels":{"gateway.envoyproxy.io/owning-gateway-name":"internal"}},"spec":{"replicas":2},"status":{"availableReplicas":2}}]}' ;;
  *' get deployment external-dns-internal '*)
    ca="$(git hash-object kubernetes/apps/networking/external-dns/app/pihole-ca.crt)"
    secret="$(git hash-object kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml)"
    CA="$ca" SECRET="$secret" yq -n -o=json '{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"external-dns-internal"},"spec":{"template":{"metadata":{"annotations":{"pihole-ca-hash":strenv(CA),"sops-hash":strenv(SECRET)}},"spec":{"containers":[{"name":"external-dns","args":["--source=crd","--source=gateway-httproute","--provider=pihole","--registry=noop","--policy=upsert-only","--domain-filter=lab.supermorphic.com","--annotation-filter=external-dns.k8s.io/audience=internal","--gateway-name=internal","--pihole-api-version=6","--pihole-server=https://pi.hole"],"env":[{"name":"SSL_CERT_FILE","value":"/etc/ssl/pihole/tls_ca.crt"}],"volumeMounts":[{"name":"pihole-ca","mountPath":"/etc/ssl/pihole","readOnly":true}]}],"volumes":[{"name":"pihole-ca","configMap":{"name":"pihole-ca"}}]}}}}' ;;
  *' get configmap pihole-ca '*) cat kubernetes/apps/networking/external-dns/app/pihole-ca.crt ;;
  *' get deployment echo '*) printf '%s\n' '{"spec":{"replicas":2},"status":{"availableReplicas":2}}' ;;
  *' get httproute echo '*) printf '%s\n' '{"status":{"parents":[{"conditions":[{"type":"Accepted","status":"True"},{"type":"ResolvedRefs","status":"True"}]}]}}' ;;
  *' get namespaces '*) printf '%s\n' '{"items":[]}' ;;
  *) echo "unexpected kubectl request: $*" >&2; exit 64 ;;
esac
EOF

cat >"$fixture/bin/talosctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'talosctl %s\n' "$*" >>"$RECOVERY_FIXTURE_TRACE"
[[ " $* " == *' --talosconfig '* && " $* " == *' --context fixture '* ]] || exit 65
case " $* " in
  *' get diagnostics '*) ;;
  *' etcd status '*) printf 'NODE ID\n1 a\n2 b\n3 c\n' ;;
  *' etcd alarm list '*) printf 'NODE ID ALARM\n' ;;
  *) exit 64 ;;
esac
EOF

cat >"$fixture/bin/flux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *' version --client '* ]]; then printf 'flux: v2.9.2\n'; exit; fi
printf 'flux %s\n' "$*" >>"$RECOVERY_FIXTURE_TRACE"
[[ " $* " == *' --kubeconfig '* && " $* " == *' --context fixture '* ]]
EOF

cat >"$fixture/bin/cilium" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'cilium %s\n' "$*" >>"$RECOVERY_FIXTURE_TRACE"
[[ " $* " == *' --kubeconfig '* && " $* " == *' --context fixture '* ]]
[[ "${RECOVERY_FIXTURE_CILIUM_FAIL:-}" != true ]] || exit 77
if [[ " $* " == *' --output json '* ]]; then
  printf '%s\n' '{"pod_state":{"hubble-relay":{"Desired":1,"Ready":1,"Available":1,"Unavailable":0}},"cilium_status":[{"hubble":{"state":"Ok"}}],"errors":{"hubble-relay":{"hubble-relay":{"Errors":[],"Warnings":[]}}}}'
fi
EOF

cat >"$fixture/bin/dig" <<'EOF'
#!/usr/bin/env bash
printf '192.168.90.30\n'
EOF
cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'fixture response\n'
EOF
cat >"$fixture/bin/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == pull ]]; then
  reference="$2"
  shift 2
  version='' destination=''
  while (( $# )); do
    case "$1" in
      --version) version="$2"; shift 2 ;;
      --destination) destination="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  name="${reference##*/}"
  [[ "$reference" != metallb && "$reference" != external-dns ]] || name="$reference"
  work="$(mktemp -d)"
  mkdir -p "$work/$name"
  printf 'name: %s\nversion: %s\n' "$name" "$version" >"$work/$name/Chart.yaml"
  tar -czf "$destination/$name-$version.tgz" -C "$work" "$name"
  rm -rf -- "$work"
  exit
fi
[[ "${1:-}" == template ]]
case "${2:-}" in
  cilium)
    cat <<'YAML'
---
kind: DaemonSet
metadata: {name: cilium}
---
kind: Deployment
metadata: {name: cilium-operator}
---
kind: Deployment
metadata: {name: hubble-relay}
---
kind: Service
metadata: {name: hubble-metrics, labels: {k8s-app: hubble}}
spec: {ports: [{name: hubble-metrics, port: 9965}]}
YAML
    ;;
  cert-manager)
    cat <<'YAML'
---
kind: Deployment
metadata: {name: cert-manager}
---
kind: Service
metadata:
  name: cert-manager
  namespace: cert-manager
spec:
  selector: {app.kubernetes.io/component: controller, app.kubernetes.io/instance: cert-manager, app.kubernetes.io/name: cert-manager}
  ports: [{name: http-metrics, port: 9402, protocol: TCP}]
YAML
    ;;
  metallb)
    printf '%s\n' $'kind: DaemonSet\nmetadata:\n  name: metallb-speaker'
    ;;
  envoy-gateway)
    cat <<'YAML'
---
metadata:
  name: envoy-gateway
---
metadata:
  name: gatewayclasses.gateway.networking.k8s.io
---
metadata:
  name: gateways.gateway.networking.k8s.io
---
metadata:
  name: httproutes.gateway.networking.k8s.io
---
metadata:
  name: envoyproxies.gateway.envoyproxy.io
YAML
    ;;
  external-dns-internal)
    ca="$(git hash-object kubernetes/apps/networking/external-dns/app/pihole-ca.crt)"
    secret="$(git hash-object kubernetes/apps/networking/external-dns/app/pihole-password.sops.yaml)"
    CA="$ca" SECRET="$secret" yq -n -P '{"kind":"Deployment","metadata":{"name":"external-dns-internal"},"spec":{"template":{"metadata":{"annotations":{"pihole-ca-hash":strenv(CA),"sops-hash":strenv(SECRET)}},"spec":{"containers":[{"name":"external-dns","args":["--source=crd","--source=gateway-httproute","--provider=pihole","--registry=noop","--policy=upsert-only","--domain-filter=lab.supermorphic.com","--annotation-filter=external-dns.k8s.io/audience=internal","--gateway-name=internal","--pihole-api-version=6","--pihole-server=https://pi.hole"],"env":[{"name":"SSL_CERT_FILE","value":"/etc/ssl/pihole/tls_ca.crt"}],"volumeMounts":[{"name":"pihole-ca","mountPath":"/etc/ssl/pihole","readOnly":true}]}],"volumes":[{"name":"pihole-ca","configMap":{"name":"pihole-ca"}}]}}}}'
    ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$fixture/bin"/*

revision="$(git rev-parse HEAD)"
chart_cache="$fixture/recovery-helm"

dirty_source="$fixture/dirty-source"
mkdir -p "$dirty_source/scripts/verify" "$dirty_source/scripts/lib"
cp scripts/verify/recovery-cache-prepare.sh "$dirty_source/scripts/verify/"
cp scripts/lib/common.sh "$dirty_source/scripts/lib/"
git -C "$dirty_source" init -q
git -C "$dirty_source" add scripts
git -C "$dirty_source" -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -qm fixture
printf '%s\n' dirty >"$dirty_source/unreviewed"
if (cd "$dirty_source" && scripts/verify/recovery-cache-prepare.sh "$fixture/dirty-cache" \
  >"$fixture/dirty-prepare.out" 2>"$fixture/dirty-prepare.err"); then
  echo 'recovery cache preparation accepted a dirty source checkout' >&2
  exit 1
fi
rg -q 'selected source checkout is dirty' "$fixture/dirty-prepare.err"

PATH="$fixture/bin:$PATH" scripts/verify/recovery-cache-prepare.sh "$chart_cache"
[[ "$(yq -r '.sourceRevision' "$chart_cache/manifest.json")" == "$revision" ]]
request="$fixture/request.json"
make_request() {
  local mode="$1" containment='null'
  [[ "$mode" != recovery ]] || containment='{"node":"nuc1","record":"{\"schemaVersion\":1,\"kind\":\"reboot\"}"}'
  MODE="$mode" CONTAINMENT="$containment" REVISION="$revision" KUBECONFIG="$fixture/kubeconfig" TALOSCONFIG="$fixture/talosconfig" \
    yq -n -o=json '{"schemaVersion":1,"requestId":"4e17c4dd-f983-4e2c-b261-b620916201a3","mode":strenv(MODE),"node":"nuc1","sourceRevision":strenv(REVISION),"apiServer":"https://192.168.90.20:6443","nodes":{"nuc1":"192.168.90.10","nuc2":"192.168.90.11","nuc3":"192.168.90.12"},"talosEndpoints":["192.168.90.10","192.168.90.11","192.168.90.12"],"credentials":{"kubeconfig":strenv(KUBECONFIG),"kubeContext":"fixture","talosconfig":strenv(TALOSCONFIG),"talosContext":"fixture"},"expectedContainment":(strenv(CONTAINMENT)|from_json),"timeoutSeconds":120}' >"$request"
}

make_request baseline
: >"$trace"
mkdir "$fixture/missing-cache"
if PATH="$fixture/bin:$PATH" RECOVERY_FIXTURE_TRACE="$trace" \
  RECOVERY_HELM_CACHE="$fixture/missing-cache" \
  python scripts/verify/recovery.py "$request" >"$fixture/missing-cache.json" 2>"$fixture/missing-cache.err"; then
  echo 'recovery verifier accepted a missing prepared chart cache' >&2
  exit 1
fi
[[ ! -s "$trace" && ! -s "$fixture/missing-cache.json" ]]

for mode in prepare baseline recovery; do
  make_request "$mode"
  : >"$trace"
  PATH="$fixture/bin:$PATH" RECOVERY_FIXTURE_TRACE="$trace" RECOVERY_HELM_CACHE="$chart_cache" \
    python scripts/verify/recovery.py "$request" >"$fixture/$mode.json"
  [[ "$(yq -r '.mode' "$fixture/$mode.json")" == "$mode" ]]
  if [[ "$mode" == prepare ]]; then
    [[ "$(yq -r '.checks | [.source,.cilium,.foundation] | join(" ")' "$fixture/$mode.json")" == 'passed not-run not-run' ]]
    [[ ! -s "$trace" ]]
  else
    [[ "$(yq -r '.checks | [.source,.cilium,.foundation] | join(" ")' "$fixture/$mode.json")" == 'passed passed passed' ]]
    rg -q -- '--context fixture' "$trace"
  fi
  if rg -q ' (create|replace|patch|delete|apply|cordon|uncordon|drain) ' "$trace"; then
    echo 'recovery chain emitted a mutation verb' >&2
    exit 1
  fi
done

make_request baseline
if PATH="$fixture/bin:$PATH" RECOVERY_FIXTURE_TRACE="$trace" RECOVERY_HELM_CACHE="$chart_cache" \
  RECOVERY_FIXTURE_NODE_CASE=baseline-contained \
  python scripts/verify/recovery.py "$request" >"$fixture/rejected-baseline.json" 2>"$fixture/rejected-baseline.err"; then
  echo 'baseline accepted a cordoned node' >&2
  exit 1
fi
[[ ! -s "$fixture/rejected-baseline.json" ]]

make_request recovery
if PATH="$fixture/bin:$PATH" RECOVERY_FIXTURE_TRACE="$trace" RECOVERY_HELM_CACHE="$chart_cache" \
  RECOVERY_FIXTURE_NODE_CASE=wrong-record \
  python scripts/verify/recovery.py "$request" >"$fixture/rejected-record.json" 2>"$fixture/rejected-record.err"; then
  echo 'recovery accepted a different lifecycle record' >&2
  exit 1
fi
[[ ! -s "$fixture/rejected-record.json" ]]

if PATH="$fixture/bin:$PATH" RECOVERY_FIXTURE_TRACE="$trace" RECOVERY_HELM_CACHE="$chart_cache" \
  RECOVERY_FIXTURE_CILIUM_FAIL=true \
  python scripts/verify/recovery.py "$request" >"$fixture/rejected-child.json" 2>"$fixture/rejected-child.err"; then
  echo 'recovery accepted a failed Cilium stage' >&2
  exit 1
fi
[[ ! -s "$fixture/rejected-child.json" ]]

echo 'Recovery verification real-chain fixture passed.'
