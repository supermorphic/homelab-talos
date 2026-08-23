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
  [[ "$status" -eq 1 ]] || {
    echo "$description: expected exit 1, got $status." >&2
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

echo '2. A different LoadBalancer address-pool annotation is rejected.'
reset_tree
yq -i '.service.app.annotations."metallb.io/address-pool" = "public"' "$app/values.yaml"
expect_fail 'address-pool annotation drifted off internal'

echo '3. A different LoadBalancer address is rejected.'
reset_tree
yq -i '.service.app.annotations."metallb.io/loadBalancerIPs" = "192.168.90.32"' "$app/values.yaml"
expect_fail 'service address drifted'

echo '4. externalTrafficPolicy Cluster is rejected.'
reset_tree
yq -i '.service.app.externalTrafficPolicy = "Cluster"' "$app/values.yaml"
expect_fail 'client-address preservation lost'

echo '4a. LoadBalancer NodePort allocation is rejected.'
reset_tree
yq -i '.service.app.allocateLoadBalancerNodePorts = true' "$app/values.yaml"
expect_fail 'node-wide listener allocation enabled'

echo '4b. Removing explicit existing NodePort deallocation is rejected.'
reset_tree
yq -i 'del(.spec.postRenderers)' "$app/helmrelease.yaml"
expect_fail 'existing NodePort deallocation removed'

echo '5. A renamed/second Service port key is rejected.'
reset_tree
yq -i '.service.app.ports.https.port = 443' "$app/values.yaml"
expect_fail 'service port key widened beyond http'

echo '6. The Service port number drifting from 32400 is rejected.'
reset_tree
yq -i '.service.app.ports.http.port = 32401' "$app/values.yaml"
expect_fail 'service port number drifted'

echo '7. Removing the world ingress rule is rejected.'
reset_tree
yq -i 'del(.spec.ingress[2])' "$app/ciliumnetworkpolicy.yaml"
expect_fail 'world ingress removed'

echo '8. A second port anywhere in ingress widens the global port set and is rejected.'
reset_tree
yq -i '.spec.ingress[2].toPorts[0].ports += [{"port": "32401", "protocol": "TCP"}]' "$app/ciliumnetworkpolicy.yaml"
expect_fail 'global ingress port set widened beyond 32400/TCP'

echo '9. A duplicated port entry inside the world rule itself is rejected.'
reset_tree
yq -i '.spec.ingress[2].toPorts[0].ports += [{"port": "32400", "protocol": "TCP"}]' "$app/ciliumnetworkpolicy.yaml"
expect_fail 'world rule port list no longer exactly 32400/TCP'

echo '10. Widening the world rule shape (e.g. adding an ICMP rule) is rejected.'
reset_tree
yq -i '.spec.ingress[2].icmps = [{"fields": [{"type": 8}]}]' "$app/ciliumnetworkpolicy.yaml"
expect_fail 'world rule keys no longer exactly fromEntities,toPorts'

echo '11. A second world rule widens the ingress rule count and is rejected.'
reset_tree
yq -i '.spec.ingress += [{"fromEntities": ["world"], "toPorts": [{"ports": [{"port": "32400", "protocol": "TCP"}]}]}]' \
  "$app/ciliumnetworkpolicy.yaml"
expect_fail 'ingress rule count widened beyond 3'

echo '12. Admitting the cluster entity is rejected.'
reset_tree
yq -i '.spec.ingress[2].fromEntities += ["cluster"]' "$app/ciliumnetworkpolicy.yaml"
expect_fail 'cluster entity admitted'

echo '13. Widening egress is rejected.'
reset_tree
yq -i '.spec.egress += [{"toEntities": ["world"]}]' "$app/ciliumnetworkpolicy.yaml"
expect_fail 'entity-based egress reintroduced'

echo '14. Dropping Seerr from the consumer set is rejected.'
reset_tree
yq -i 'del(.spec.ingress[0].fromEndpoints[] | select(.matchLabels."app.kubernetes.io/name" == "seerr"))' \
  "$app/ciliumnetworkpolicy.yaml"
expect_fail 'seerr removed from the Plex consumer set'

echo '14a. Dropping Sonarr from the consumer set is rejected.'
reset_tree
yq -i 'del(.spec.ingress[0].fromEndpoints[] | select(.matchLabels."app.kubernetes.io/name" == "sonarr"))' \
  "$app/ciliumnetworkpolicy.yaml"
expect_fail 'sonarr removed from the Plex consumer set'

echo '14b. Dropping Radarr from the consumer set is rejected.'
reset_tree
yq -i 'del(.spec.ingress[0].fromEndpoints[] | select(.matchLabels."app.kubernetes.io/name" == "radarr"))' \
  "$app/ciliumnetworkpolicy.yaml"
expect_fail 'radarr removed from the Plex consumer set'

echo '14c. Dropping Lidarr from the consumer set is rejected.'
reset_tree
yq -i 'del(.spec.ingress[0].fromEndpoints[] | select(.matchLabels."app.kubernetes.io/name" == "lidarr"))' \
  "$app/ciliumnetworkpolicy.yaml"
expect_fail 'lidarr removed from the Plex consumer set'

echo '15. Dropping the 32400 egress publish-check port is rejected.'
reset_tree
yq -i '.spec.egress[1].toPorts[0].ports = [{"port": "443", "protocol": "TCP"}]' \
  "$app/ciliumnetworkpolicy.yaml"
expect_fail 'egress publish-check port removed'

echo '16. Widening egress to a third port is rejected.'
reset_tree
yq -i '.spec.egress[1].toPorts[0].ports += [{"port": "8080", "protocol": "TCP"}]' \
  "$app/ciliumnetworkpolicy.yaml"
expect_fail 'egress widened beyond 443 and 32400'

echo 'Plex validator mutation tests passed.'
