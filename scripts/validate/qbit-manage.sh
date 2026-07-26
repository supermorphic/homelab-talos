#!/usr/bin/env bash
set -euo pipefail

# qbit_manage: UI-less scheduled qBittorrent policy engine (StuffAnThings). Talks to the
# internal qBittorrent Web API only — no HTTPRoute, no Service, no Gluetun netns, no
# media-data mount in PR1. Validates the static source; the live probe is qbit-manage-verify.
#
# SAFETY-FOCUSED validation. Several assertions marked "[stage: PR1]" pin this rollout stage
# and are deliberately relaxed in later PRs (tag_update in PR2, share_limits in PR3, cleanup
# in PR4). The assertions marked "[invariant]" must hold in EVERY stage — they encode the
# plan's non-negotiable safety rules (no category changes, no destructive features, no
# unknown-tracker catch-all, credentials from the Secret).
base='kubernetes/apps/media/qbit-manage'
ks="$base/ks.yaml"; hr="$base/app/helmrelease.yaml"; values="$base/app/values.yaml"
config="$base/app/config.yml"; secret="$base/app/qbit-manage-secret.sops.yaml"
oci='kubernetes/apps/media/namespace/app/ocirepository.yaml'
temp_dir="$(mktemp -d /tmp/homelab-talos-qbit-manage-validate.XXXXXX)"
trap 'rm -rf -- "$temp_dir"' EXIT

for f in "$ks" "$hr" "$values" "$config" "$secret" "$base/app/kustomization.yaml" "$oci"; do
  [[ -f "$f" ]] || { echo "Missing qbit-manage source: $f" >&2; exit 1; }
done
# UI-less: it must NOT carry an HTTPRoute (no operator UI, nothing connects to it).
[[ ! -f "$base/app/httproute.yaml" ]] || { echo 'qbit-manage must not define an HTTPRoute (UI-less).' >&2; exit 1; }
rg -qx '  - ./qbit-manage/ks.yaml' kubernetes/apps/media/kustomization.yaml || {
  echo 'Refusing: ./qbit-manage/ks.yaml is not wired into kubernetes/apps/media/kustomization.yaml.' >&2
  exit 1
}

# --- Flux Kustomization ---
suspend_state="$(yq -r '.spec.suspend // false' "$ks")"
[[ "$suspend_state" == 'true' || "$suspend_state" == 'false' ]]
# It carries a Secret, so it MUST declare SOPS decryption.
[[ "$(yq -r '.spec.decryption.provider // "none"' "$ks")" == 'sops' ]] || { echo 'qbit-manage ks.yaml must declare decryption.provider: sops (it carries a Secret).' >&2; exit 1; }
[[ "$(yq -r '.spec.decryption.secretRef.name // "none"' "$ks")" == 'sops-age' ]]
deps="$(yq -r '[.spec.dependsOn[].name] | sort | join(",")' "$ks")"
[[ "$deps" == 'media-storage,qbittorrent' ]] || { echo "qbit-manage dependsOn must be [media-storage, qbittorrent]; got: $deps." >&2; exit 1; }

[[ "$(yq -r '.spec.chartRef.name' "$hr")" == 'app-template' ]]

# --- Workload shape (repo/media conventions) ---
[[ "$(yq -r '.controllers."qbit-manage".type' "$values")" == 'deployment' ]]
[[ "$(yq -r '.controllers."qbit-manage".strategy' "$values")" == 'Recreate' ]]
[[ "$(yq -r '.controllers."qbit-manage".containers.app.image.repository' "$values")" == 'ghcr.io/stuffanthings/qbit_manage' ]]
tag="$(yq -r '.controllers."qbit-manage".containers.app.image.tag' "$values")"; [[ -n "$tag" && "$tag" != 'null' ]] || { echo 'qbit-manage image tag must be pinned.' >&2; exit 1; }
[[ "$tag" != 'latest' && "$tag" != 'develop' ]] || { echo 'qbit-manage must pin an immutable tag (not latest/develop).' >&2; exit 1; }
[[ "$(yq -r '.controllers."qbit-manage".containers.app.securityContext.capabilities.drop[]' "$values" | tr '\n' ' ')" == 'ALL ' ]]
[[ "$(yq -r '.controllers."qbit-manage".containers.app.securityContext.allowPrivilegeEscalation' "$values")" == 'false' ]]
[[ "$(yq -r '.controllers."qbit-manage".pod.securityContext.runAsNonRoot' "$values")" == 'true' ]]
[[ "$(yq -r '.controllers."qbit-manage".pod.securityContext.runAsUser' "$values")" == '568' ]] || { echo 'qbit-manage must run as non-root 568 (media default).' >&2; exit 1; }
# Credentials come ONLY from the Secret (envFrom), never inline. [invariant]
[[ "$(yq -r '.controllers."qbit-manage".containers.app.envFrom[0].secretRef.name' "$values")" == 'qbit-manage-secret' ]] || { echo 'qbit-manage must load QBT_USER/QBT_PASS via envFrom secretRef qbit-manage-secret.' >&2; exit 1; }
# UI-less: web server disabled so no Service/route is ever needed. [invariant]
[[ "$(yq -r '.controllers."qbit-manage".containers.app.env.QBT_WEB_SERVER' "$values")" == 'false' ]] || { echo 'qbit-manage must set QBT_WEB_SERVER=false (no UI).' >&2; exit 1; }
# PR1: no media-data mount (API-only). PR4 adds a download-root mount; relax then. [stage: PR1]
[[ "$(yq -r '.persistence.data // "none"' "$values")" == 'none' ]] || { echo 'qbit-manage must not mount media-data in PR1 (API-only).' >&2; exit 1; }

# --- SOPS Secret shape (encryption itself is enforced by the sops-encrypted pre-commit hook) ---
[[ "$(yq -r '.metadata.name' "$secret")" == 'qbit-manage-secret' ]]
[[ "$(yq -r '.metadata.namespace' "$secret")" == 'media' ]]
[[ "$(yq -r '.sops // "none"' "$secret")" != 'none' ]] || { echo 'qbit-manage-secret.sops.yaml is not SOPS-encrypted.' >&2; exit 1; }
for k in QBT_USER QBT_PASS; do
  [[ "$(yq -r ".stringData.$k // \"none\"" "$secret")" != 'none' ]] || { echo "qbit-manage-secret must define stringData.$k." >&2; exit 1; }
done

# --- Declarative policy (config.yml) safety semantics ---
# Connection points at the internal qBittorrent Service, credentials via !ENV. [invariant]
[[ "$(yq -r '.qbt.host' "$config")" == 'http://qbittorrent.media.svc.cluster.local:8080' ]] || { echo 'config.yml qbt.host must be the internal qBittorrent Service URL.' >&2; exit 1; }
rg -q '!ENV QBT_USER' "$config" || { echo 'config.yml qbt.user must resolve from !ENV QBT_USER (no literal credential).' >&2; exit 1; }
rg -q '!ENV QBT_PASS' "$config" || { echo 'config.yml qbt.pass must resolve from !ENV QBT_PASS (no literal credential).' >&2; exit 1; }

# [invariant] Categories are owned by Sonarr/Radarr — qbit_manage must never change them.
[[ "$(yq -r '.commands.cat_update' "$config")" == 'false' ]] || { echo 'commands.cat_update must be false (never change categories).' >&2; exit 1; }
# [invariant] Destructive / unrelated features stay disabled in this plan.
for cmd in rem_unregistered rem_orphaned tag_nohardlinks tag_tracker_error recheck; do
  [[ "$(yq -r ".commands.$cmd" "$config")" == 'false' ]] || { echo "commands.$cmd must be false (destructive/unrelated feature)." >&2; exit 1; }
done
# [invariant] No catch-all: unknown trackers must never be mapped to public / any cleanup.
[[ "$(yq -r '.tracker.other // "none"' "$config")" == 'none' ]] || { echo 'config.yml must not define tracker.other (no unknown-tracker catch-all).' >&2; exit 1; }

# [stage: PR1] Inert: dry-run on, tagging/limits off, both cleanup controls safe.
#   PR2 sets tag_update: true; PR3 sets share_limits: true; PR4 sets skip_cleanup: false
#   and the share_limits.public group cleanup: true. Relax these lines in those PRs.
[[ "$(yq -r '.commands.dry_run' "$config")" == 'true' ]] || { echo '[PR1] commands.dry_run must be true.' >&2; exit 1; }
[[ "$(yq -r '.commands.tag_update' "$config")" == 'false' ]] || { echo '[PR1] commands.tag_update must be false.' >&2; exit 1; }
[[ "$(yq -r '.commands.share_limits' "$config")" == 'false' ]] || { echo '[PR1] commands.share_limits must be false.' >&2; exit 1; }
[[ "$(yq -r '.commands.skip_cleanup' "$config")" == 'true' ]] || { echo '[PR1] commands.skip_cleanup must be true.' >&2; exit 1; }
[[ "$(yq -r '.recyclebin.enabled' "$config")" == 'false' ]] || { echo '[PR1] recyclebin.enabled must be false.' >&2; exit 1; }
# [stage: PR1] No tracker/share_limits rules yet.
[[ "$(yq -r '.tracker // "none"' "$config")" == 'none' ]] || { echo '[PR1] config.yml must not define a tracker: section yet (added in PR2).' >&2; exit 1; }
[[ "$(yq -r '.share_limits // "none"' "$config")" == 'none' ]] || { echo '[PR1] config.yml must not define a share_limits: section yet (added in PR3).' >&2; exit 1; }

# --- No Gatus endpoint ever (UI-less; nothing to black-box probe over the gateway). ---
! rg -q '^    - name: qbit-manage$' kubernetes/apps/monitoring/gatus/app/values.yaml || { echo 'qbit-manage is UI-less and must not register a Gatus endpoint.' >&2; exit 1; }

# --- Pinned render: Deployment only, Recreate, no Service, no HTTPRoute ---
chart_url="$(yq -r '.spec.url' "$oci")"
chart_tag="$(yq -r '.spec.ref.tag' "$oci")"
kustomize build "$base/app" >/dev/null
helm template qbit-manage "$chart_url" --version "$chart_tag" --namespace media --values "$values" >"$temp_dir/render.yaml"
[[ "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$temp_dir/render.yaml")" == 'qbit-manage' ]]
[[ "$(yq -r 'select(.kind == "Deployment") | .spec.strategy.type' "$temp_dir/render.yaml")" == 'Recreate' ]]
! yq -r 'select(.kind == "Service") | .metadata.name' "$temp_dir/render.yaml" | rg -q . || { echo 'qbit-manage render unexpectedly contains a Service (should be UI-less).' >&2; exit 1; }
! yq -r 'select(.kind == "HTTPRoute") | .metadata.name' "$temp_dir/render.yaml" | rg -q . || { echo 'qbit-manage render unexpectedly contains an HTTPRoute.' >&2; exit 1; }

echo "qbit-manage $tag source (app-template, UI-less API client, SOPS creds via envFrom, inert dry-run policy with no catch-all/destructive features, no Service/HTTPRoute/Gatus, pinned render) passed validation."
