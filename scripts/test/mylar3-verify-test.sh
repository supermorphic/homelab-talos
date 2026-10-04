#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="$repo_root/scripts/verify/mylar3.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/mylar3-verify-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/scripts/lib" "$fixture/kubernetes/apps/media/mylar3/app"
cp "$repo_root/kubernetes/apps/media/mylar3/app/values.yaml" \
  "$fixture/kubernetes/apps/media/mylar3/app/values.yaml"
cat >"$fixture/scripts/lib/network.sh" <<'EOF'
HOMELAB_DNS_RESOLVER='192.0.2.2'
HOMELAB_GATEWAY_VIP='192.0.2.30'
EOF

# Independent storage fixtures. Only the image follows the unrelated version pin.
cat >"$fixture/deployment.base.json" <<'EOF'
{"spec":{"replicas":1,"strategy":{"type":"Recreate"},"template":{"spec":{
  "containers":[{"name":"app","image":"fixture-image","volumeMounts":[
    {"name":"config-volume","mountPath":"/config"},
    {"name":"data","mountPath":"/data"}]}],
  "volumes":[{"name":"config-volume","persistentVolumeClaim":{"claimName":"mylar3"}},
    {"name":"data","persistentVolumeClaim":{"claimName":"media-data"}}]
}}}}
EOF
IMAGE="$(yq -r '.controllers.mylar3.containers.app.image | .repository + ":" + .tag' \
  "$repo_root/kubernetes/apps/media/mylar3/app/values.yaml")" \
  yq -i '.spec.template.spec.containers[0].image = strenv(IMAGE)' "$fixture/deployment.base.json"
cat >"$fixture/config.base.json" <<'EOF'
{"metadata":{"name":"mylar3","annotations":{"helm.sh/resource-policy":"keep"}},
 "spec":{"storageClassName":"longhorn","accessModes":["ReadWriteOnce"]},
 "status":{"phase":"Bound"}}
EOF
cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --kubeconfig && " $* " != *' --context '* ]] || exit 64
shift 2
case "$*" in
  '-n flux-system get kustomization mylar3 -o jsonpath='*|'-n media get helmrelease mylar3 -o jsonpath='*) printf True ;;
  '-n media rollout status deployment/mylar3 --timeout=60s') exit 0 ;;
  '-n media get pvc mylar3 -o json') cat "$MYLAR_FIXTURE/config.json" ;;
  '-n media get pvc media-data -o json') printf '{"status":{"phase":"Bound"}}' ;;
  '-n media get pvc mylar3 -o jsonpath={.status.phase}') yq -r '.status.phase' "$MYLAR_FIXTURE/config.json" ;;
  '-n media get pvc media-data -o jsonpath={.status.phase}') printf Bound ;;
  '-n media get deployment mylar3 -o json') cat "$MYLAR_FIXTURE/deployment.json" ;;
  '-n media get httproute mylar3 -o json')
    printf '{"status":{"parents":[{"parentRef":{"name":"internal"},"conditions":[{"type":"Accepted","status":"True"},{"type":"ResolvedRefs","status":"True"}]}]}}'
    ;;
  *) echo "Unexpected kubectl invocation: $*" >&2; exit 64 ;;
esac
EOF
cat >"$fixture/bin/dig" <<'EOF'
#!/usr/bin/env bash
printf '192.0.2.30\n'
EOF
cat >"$fixture/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 200
EOF
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH" MYLAR_FIXTURE="$fixture"
cd "$fixture"

reset_storage() {
  cp "$fixture/deployment.base.json" "$fixture/deployment.json"
  cp "$fixture/config.base.json" "$fixture/config.json"
}
expect_failure() {
  local scenario="$1" expected="$2"
  if "$verifier" "$fixture/kubeconfig" >"$fixture/output" 2>&1; then
    echo "Mylar3 verifier incorrectly accepted $scenario." >&2
    cat "$fixture/output" >&2
    exit 1
  fi
  if ! rg -q "Mylar3 verification failed: .*${expected}" "$fixture/output"; then
    echo "Mylar3 verifier rejected $scenario for the wrong reason." >&2
    cat "$fixture/output" >&2
    exit 1
  fi
}

reset_storage
"$verifier" "$fixture/kubeconfig" >"$fixture/output" 2>&1

# Removing the mount checks would make these invalid deployments pass even
# though both named claims remain Bound and the login endpoint is healthy.
while IFS='|' read -r scenario mutation; do
  reset_storage
  yq -i "$mutation" "$fixture/deployment.json"
  expect_failure "$scenario" '/config'
done <<'EOF'
missing config mount|del(.spec.template.spec.containers[0].volumeMounts[0])
wrong config mount path|.spec.template.spec.containers[0].volumeMounts[0].mountPath = "/wrong"
config mounted only by sidecar|.spec.template.spec.containers += [{"name":"sidecar","volumeMounts":[{"name":"config-volume","mountPath":"/config"}]}] | del(.spec.template.spec.containers[0].volumeMounts[0])
dangling volume reference|.spec.template.spec.containers[0].volumeMounts[0].name = "missing"
ephemeral config volume|del(.spec.template.spec.volumes[0].persistentVolumeClaim) | .spec.template.spec.volumes[0].emptyDir = {}
wrong config claim|.spec.template.spec.volumes[0].persistentVolumeClaim.claimName = "other-config"
read-only config mount|.spec.template.spec.containers[0].volumeMounts[0].readOnly = true
read-only config volume|.spec.template.spec.volumes[0].persistentVolumeClaim.readOnly = true
EOF

while IFS='|' read -r scenario expected mutation; do
  reset_storage
  yq -i "$mutation" "$fixture/config.json"
  expect_failure "$scenario" "$expected"
done <<'EOF'
unbound config claim|not Bound|.status.phase = "Pending"
wrong storage class|longhorn|.spec.storageClassName = "other"
wrong access mode|ReadWriteOnce|.spec.accessModes = ["ReadWriteMany"]
missing access mode|ReadWriteOnce|del(.spec.accessModes)
missing retention annotation|retained|del(.metadata.annotations)
EOF

# Resolve by volume name rather than depending on chart-generated names/order.
reset_storage
yq -i '.spec.template.spec.containers[0].volumeMounts[0].name = "renamed" |
  .spec.template.spec.volumes[0].name = "renamed" |
  .spec.template.spec.volumes |= reverse' "$fixture/deployment.json"
"$verifier" "$fixture/kubeconfig" >"$fixture/output" 2>&1
echo 'Mylar3 verifier storage checks passed: valid mounts and 13 invalid layouts.'
