#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate/plex.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/plex-validator-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

tree_root="$test_dir/tree"
app="$tree_root/kubernetes/apps/media/plex/app"

reset_tree() {
  rm -rf -- "$tree_root"
  mkdir -p "$tree_root/kubernetes/apps/media/namespace/app" "$tree_root/scripts/lib"
  cp -R "$repo_root/kubernetes/apps/media/plex" "$tree_root/kubernetes/apps/media/plex"
  cp "$repo_root/kubernetes/apps/media/namespace/app/ocirepository.yaml" \
    "$tree_root/kubernetes/apps/media/namespace/app/ocirepository.yaml"
  cp "$repo_root/kubernetes/apps/media/kustomization.yaml" \
    "$tree_root/kubernetes/apps/media/kustomization.yaml"
  cp "$repo_root/scripts/lib/common.sh" "$tree_root/scripts/lib/common.sh"
}

run_validator() { (cd "$tree_root" && "$validator") 2>&1; }

expect_pass() {
  run_validator >/dev/null || { echo "$1: expected the production source to pass." >&2; exit 1; }
}

expect_fail() {
  local description="$1"
  set +e
  local output status
  output="$(run_validator)"
  status="$?"
  set -e
  [[ "$status" -ne 0 ]] || {
    echo "$description: expected a non-zero exit, got 0." >&2
    echo "$output" >&2
    exit 1
  }
}

reset_tree
expect_pass 'production Plex source'

echo '1. Service reverting to ClusterIP is rejected.'
reset_tree
yq -i '.service.app.type = "ClusterIP"' "$app/values.yaml"
expect_fail 'service type reverted to ClusterIP'

echo '2. A different LoadBalancer address is rejected.'
reset_tree
yq -i '.service.app.annotations."metallb.io/loadBalancerIPs" = "192.168.90.32"' "$app/values.yaml"
expect_fail 'service address drifted'

echo '3. externalTrafficPolicy Cluster is rejected.'
reset_tree
yq -i '.service.app.externalTrafficPolicy = "Cluster"' "$app/values.yaml"
expect_fail 'client-address preservation lost'

echo '4. Removing the world ingress rule is rejected.'
reset_tree
yq -i 'del(.spec.ingress[2])' "$app/ciliumnetworkpolicy.yaml"
expect_fail 'world ingress removed'

echo '5. Opening a second port to world is rejected.'
reset_tree
yq -i '.spec.ingress[2].toPorts[0].ports += [{"port": "32401", "protocol": "TCP"}]' "$app/ciliumnetworkpolicy.yaml"
expect_fail 'world admitted on a second port'

echo '6. A second world rule is rejected.'
reset_tree
yq -i '.spec.ingress += [{"fromEntities": ["world"], "toPorts": [{"ports": [{"port": "32400", "protocol": "TCP"}]}]}]' \
  "$app/ciliumnetworkpolicy.yaml"
expect_fail 'world admitted by a second rule'

echo '7. Admitting the cluster entity is rejected.'
reset_tree
yq -i '.spec.ingress[2].fromEntities += ["cluster"]' "$app/ciliumnetworkpolicy.yaml"
expect_fail 'cluster entity admitted'

echo '8. Widening egress is rejected.'
reset_tree
yq -i '.spec.egress += [{"toEntities": ["world"]}]' "$app/ciliumnetworkpolicy.yaml"
expect_fail 'entity-based egress reintroduced'

echo 'Plex validator mutation tests passed.'
