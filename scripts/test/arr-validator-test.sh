#!/usr/bin/env bash
# Negative coverage for scripts/validate/arr.sh. The validator only ever sees passing input
# in `just ci`, so without this its guards — especially the activation-aware Gatus/Homepage
# pair that holds a staged app suspended — could be broken by an edit and CI would stay green.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

validator="$repo_root/scripts/validate/arr.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-arr-validator-test.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT

# The validator resolves every source path relative to the working directory, so a case runs
# against a throwaway copy of the trees it reads. Mutations never touch the real repository.
tree_root="$test_dir/tree"
media="$tree_root/kubernetes/apps/media"
gatus="$tree_root/kubernetes/apps/monitoring/gatus/app/values.yaml"

reset_tree() {
  rm -rf -- "$tree_root"
  mkdir -p "$tree_root/kubernetes/apps/monitoring/gatus/app"
  cp -R "$repo_root/kubernetes/apps/media" "$tree_root/kubernetes/apps/media"
  cp "$repo_root/kubernetes/apps/monitoring/gatus/app/values.yaml" "$gatus"
}

run_validator() {
  (cd "$tree_root" && "$validator") 2>&1
}

expect_pass() {
  local description="$1"
  run_validator >/dev/null || {
    echo "$description: expected *arr validation to pass." >&2
    exit 1
  }
}

expect_fail() {
  local description="$1"
  local expected_message="$2"
  local output exit_code

  set +e
  output="$(run_validator)"
  exit_code="$?"
  set -e

  [[ "$exit_code" -eq 1 ]] || {
    echo "$description: expected exit 1, got $exit_code." >&2
    echo "$output" >&2
    exit 1
  }
  rg -Fq "$expected_message" <<<"$output" || {
    echo "$description: missing expected failure message: $expected_message" >&2
    echo "$output" >&2
    exit 1
  }
}

# Suspend an app the way an operator would stage one: drop its Gatus endpoint so the
# suspended-app Gatus guard passes and the case isolates the check under test.
suspend_app() {
  local app="$1"
  yq -i '.spec.suspend = true' "$media/$app/ks.yaml"
  yq -i "del(.config.endpoints[] | select(.name == \"$app\"))" "$gatus"
}

reset_tree
expect_pass 'production *arr source'

# --- Source wiring -----------------------------------------------------------------------
# Cases target prowlarr (first in the validator's table) so the run exits before any chart
# render, except where the check only applies to a media-mounting app.

reset_tree
rm -f "$media/prowlarr/app/httproute.yaml"
expect_fail 'app source file deleted' \
  'Missing *arr source: kubernetes/apps/media/prowlarr/app/httproute.yaml'

reset_tree
yq -i 'del(.resources[] | select(. == "./prowlarr/ks.yaml"))' "$media/kustomization.yaml"
expect_fail 'app not wired into the media kustomization' \
  './prowlarr/ks.yaml is not wired into kubernetes/apps/media/kustomization.yaml.'

reset_tree
yq -i '.spec.decryption.provider = "sops"' "$media/prowlarr/ks.yaml"
expect_fail 'ks.yaml claims secrets these apps do not have' \
  'prowlarr ks.yaml must not declare decryption (no secrets).'

reset_tree
yq -i 'del(.spec.dependsOn[] | select(.name == "media"))' "$media/prowlarr/ks.yaml"
expect_fail 'dependency graph narrowed' \
  'prowlarr dependsOn must be [internal-gateway,media]; got: internal-gateway.'

reset_tree
yq -i '.spec.dependsOn += [{"name": "media-storage"}]' "$media/prowlarr/ks.yaml"
expect_fail 'dependency graph widened' \
  'prowlarr dependsOn must be [internal-gateway,media]; got: internal-gateway,media,media-storage.'

# --- Single-writer storage contract ------------------------------------------------------

reset_tree
yq -i '.controllers.prowlarr.strategy = "RollingUpdate"' "$media/prowlarr/app/values.yaml"
expect_fail 'RollingUpdate on a ReadWriteOnce config PVC' \
  'prowlarr must set strategy: Recreate (it mounts a ReadWriteOnce config PVC).'

reset_tree
yq -i '.persistence.data.existingClaim = "media-data"' "$media/prowlarr/app/values.yaml"
expect_fail 'config-only app given the shared media claim' \
  'prowlarr must not mount media-data (config-only).'

reset_tree
yq -i '.persistence.data.existingClaim = "sonarr-data"' "$media/sonarr/app/values.yaml"
expect_fail 'media app on a private claim instead of the shared one' \
  'sonarr data persistence must use existingClaim media-data.'

reset_tree
yq -i '.persistence.data.globalMounts[0].path = "/media"' "$media/sonarr/app/values.yaml"
expect_fail 'shared claim mounted off the hardlink path' \
  'sonarr must mount media-data at /data.'

# --- Port agreement ----------------------------------------------------------------------

reset_tree
yq -i '.service.app.ports.http.port = 9697' "$media/prowlarr/app/values.yaml"
expect_fail 'service port drifted from the app default' \
  'prowlarr service port must be 9696.'

reset_tree
yq -i '.spec.rules[0].backendRefs[0].port = 9697' "$media/prowlarr/app/httproute.yaml"
expect_fail 'HTTPRoute backend port drifted from the service' \
  'prowlarr HTTPRoute backend port must be 9696.'

# --- Activation gate: Gatus --------------------------------------------------------------

reset_tree
yq -i 'del(.config.endpoints[] | select(.name == "prowlarr"))' "$gatus"
expect_fail 'active app with no Gatus endpoint' \
  'Active prowlarr has no Gatus endpoint.'

reset_tree
yq -i '.spec.suspend = true' "$media/prowlarr/ks.yaml"
expect_fail 'suspended app still probed by Gatus' \
  'Suspended prowlarr must not create a failing Gatus endpoint.'

# --- Activation gate: Homepage widgets ---------------------------------------------------
# This is the guard that keeps a staged app (Lidarr in PR1) from publishing a dashboard
# widget that cannot resolve until the operator creates its API-key Secret.

reset_tree
suspend_app prowlarr
expect_fail 'suspended app still publishing widget annotations' \
  'Suspended prowlarr must not publish widget.* annotations.'

reset_tree
yq -i '.metadata.annotations."gethomepage.dev/widget.type" = "sonarr"' \
  "$media/prowlarr/app/httproute.yaml"
expect_fail 'active app widget bound to the wrong service type' \
  'Active prowlarr widget.type annotation must be prowlarr.'

reset_tree
yq -i '.metadata.annotations."gethomepage.dev/widget.url" = "http://prowlarr.media.svc.cluster.local:8989"' \
  "$media/prowlarr/app/httproute.yaml"
expect_fail 'active app widget pointed at the wrong port' \
  'Active prowlarr widget.url annotation must be http://prowlarr.media.svc.cluster.local:9696.'

reset_tree
yq -i '.metadata.annotations."gethomepage.dev/widget.key" = "{{HOMEPAGE_VAR_SONARR_API_KEY}}"' \
  "$media/prowlarr/app/httproute.yaml"
expect_fail 'active app widget reading another app API key' \
  'Active prowlarr widget.key annotation must be {{HOMEPAGE_VAR_PROWLARR_API_KEY}}.'

# --- Staged Lidarr specifically ------------------------------------------------------------
# Lidarr ships suspended in PR1; activating it in Git without its monitoring must not pass.

reset_tree
yq -i '.spec.suspend = false' "$media/lidarr/ks.yaml"
expect_fail 'lidarr activated without its Gatus endpoint' \
  'Active lidarr has no Gatus endpoint.'

echo '*arr source validator tests passed.'
