#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
verifier="$repo_root/scripts/verify/portainer-rbac.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/portainer-rbac-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"
touch "$fixture/kubeconfig"

cat >"$fixture/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

resource=''
name=''
for ((index = 0; index < $#; index++)); do
  argument="${@:$((index + 1)):1}"
  if [[ "$argument" == get ]]; then
    resource="${@:$((index + 2)):1}"
    name="${@:$((index + 3)):1}"
    break
  fi
done

case "$resource:$name" in
  clusterrole:portainer-readonly)
    yq ea -o=json -I=0 \
      'select(.kind == "ClusterRole" and .metadata.name == "portainer-readonly")' \
      "$FAKE_RBAC_SOURCE"
    ;;
  clusterrolebinding:portainer-readonly)
    yq ea -o=json -I=0 \
      'select(.kind == "ClusterRoleBinding" and .metadata.name == "portainer-readonly")' \
      "$FAKE_RBAC_SOURCE"
    ;;
  clusterrolebindings:--output)
    bindings="$(yq --null-input --output-format json '
      {
        "items": [
          {
            "kind": "ClusterRoleBinding",
            "metadata": {"name": "portainer-readonly"},
            "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "portainer-readonly"},
            "subjects": [{"kind": "ServiceAccount", "namespace": "portainer", "name": "portainer-readonly"}]
          },
          {
            "kind": "ClusterRoleBinding",
            "metadata": {"name": "system:basic-user"},
            "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "system:basic-user"},
            "subjects": [{"kind": "Group", "apiGroup": "rbac.authorization.k8s.io", "name": "system:authenticated"}]
          },
          {
            "kind": "ClusterRoleBinding",
            "metadata": {"name": "system:discovery"},
            "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "system:discovery"},
            "subjects": [{"kind": "Group", "apiGroup": "rbac.authorization.k8s.io", "name": "system:authenticated"}]
          },
          {
            "kind": "ClusterRoleBinding",
            "metadata": {"name": "system:public-info-viewer"},
            "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "system:public-info-viewer"},
            "subjects": [{"kind": "Group", "apiGroup": "rbac.authorization.k8s.io", "name": "system:authenticated"}]
          }
        ]
      }
    ')"
    if [[ "$FAKE_RISKY" == true ]]; then
      yq '.items += [{
        "kind": "ClusterRoleBinding",
        "metadata": {"name": "authenticated-cluster-admin"},
        "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "cluster-admin"},
        "subjects": [{"kind": "Group", "apiGroup": "rbac.authorization.k8s.io", "name": "system:authenticated"}]
      }]' <<<"$bindings"
    else
      printf '%s\n' "$bindings"
    fi
    ;;
  rolebindings:--all-namespaces)
    printf '{"items":[]}'
    ;;
  clusterrole:system:basic-user)
    printf '%s\n' '{"kind":"ClusterRole","metadata":{"name":"system:basic-user"},"rules":[{"apiGroups":["authorization.k8s.io"],"resources":["selfsubjectaccessreviews","selfsubjectrulesreviews"],"verbs":["create"]},{"apiGroups":["authentication.k8s.io"],"resources":["selfsubjectreviews"],"verbs":["create"]}]}'
    ;;
  clusterrole:system:discovery)
    printf '%s\n' '{"kind":"ClusterRole","metadata":{"name":"system:discovery"},"rules":[{"nonResourceURLs":["/api","/api/*","/apis","/apis/*","/healthz","/livez","/openapi","/openapi/*","/openid/v1/jwks","/openid/v1/jwks/","/readyz","/version","/version/"],"verbs":["get"]}]}'
    ;;
  clusterrole:system:public-info-viewer)
    printf '%s\n' '{"kind":"ClusterRole","metadata":{"name":"system:public-info-viewer"},"rules":[{"nonResourceURLs":["/healthz","/livez","/readyz","/version","/version/"],"verbs":["get"]}]}'
    ;;
  clusterrole:cluster-admin)
    printf '%s\n' '{"kind":"ClusterRole","metadata":{"name":"cluster-admin"},"rules":[{"apiGroups":["*"],"resources":["*"],"verbs":["*"]}]}'
    ;;
  *)
    echo "Unexpected kubectl request: $*" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fixture/bin/kubectl"

PATH="$fixture/bin:$PATH" \
FAKE_RBAC_SOURCE="$repo_root/kubernetes/apps/monitoring/portainer/app/rbac.yaml" \
FAKE_RISKY=false \
  "$verifier" "$fixture/kubeconfig" \
    "$repo_root/kubernetes/apps/monitoring/portainer/app/rbac.yaml"

if PATH="$fixture/bin:$PATH" \
  FAKE_RBAC_SOURCE="$repo_root/kubernetes/apps/monitoring/portainer/app/rbac.yaml" \
  FAKE_RISKY=true \
    "$verifier" "$fixture/kubeconfig" \
      "$repo_root/kubernetes/apps/monitoring/portainer/app/rbac.yaml" \
      >"$fixture/risky.out" 2>&1; then
  echo 'system:authenticated cluster-admin binding unexpectedly passed.' >&2
  exit 1
fi
rg -q 'Unexpected system:authenticated ClusterRoleBinding.*authenticated-cluster-admin' \
  "$fixture/risky.out"

echo 'Portainer effective RBAC graph tests passed.'
