#!/usr/bin/env bash
set -euo pipefail

# qbit_manage: UI-less scheduled qBittorrent policy engine (StuffAnThings). Talks to the
# internal qBittorrent Web API only — no HTTPRoute, Service, or Gluetun netns. It mounts only
# the downloads subpath for recycle-bin cleanup and can never reach /data/media. Validates the
# active static policy; the live readiness/authentication probe is qbit-manage-verify.
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
# [invariant: never /media] Download-root mount: ONLY the downloads subPath is ever mounted, so
# qbit_manage physically cannot reach /data/media — a Plex library file can never be deleted
# here regardless of policy. It is read-write so the recycle bin can move download-side data.
[[ "$(yq -r '.persistence.data.existingClaim' "$values")" == 'media-data' ]] || { echo 'qbit-manage data mount must use existingClaim media-data.' >&2; exit 1; }
dl="$(yq -r '.persistence.data.advancedMounts."qbit-manage".app[0]' "$values")"
[[ "$(yq -r '.path' <<<"$dl")" == '/data/downloads' ]] || { echo 'qbit-manage data mount path must be /data/downloads.' >&2; exit 1; }
[[ "$(yq -r '.subPath' <<<"$dl")" == 'downloads' ]] || { echo 'qbit-manage must mount ONLY the downloads subPath (never /data/media).' >&2; exit 1; }
[[ "$(yq -r '.directory.root_dir' "$config")" == '/data/downloads' ]] || { echo 'config.yml directory.root_dir must be /data/downloads.' >&2; exit 1; }

# Auto-reload: config.yml is copied onto a writable emptyDir at pod start, so a ConfigMap-only
# change would not roll the pod. The config-hash pod annotation (= git hash-object of config.yml)
# is part of the pod template, so any config change rolls the Deployment. Enforce they match so a
# config edit can never silently fail to deploy.
want_hash="$(git hash-object "$config")"
have_hash="$(yq -r '.controllers."qbit-manage".pod.annotations."config-hash" // "none"' "$values")"
[[ "$have_hash" == "$want_hash" ]] || { echo "qbit-manage pod annotation config-hash ($have_hash) must equal git hash-object of config.yml ($want_hash) — update it in values.yaml." >&2; exit 1; }
# Credentials are loaded through envFrom only when the app process starts. A Secret-only
# reconcile does not replace the Pod, so bind the encrypted Secret revision into the Pod
# template and require every credential change to produce a Recreate rollout.
secret_revision="$(git hash-object "$secret")"
secret_rollout_revision="$(yq -r '.controllers."qbit-manage".pod.annotations."sops-hash" // "none"' "$values")"
[[ "$secret_rollout_revision" == "$secret_revision" ]] || {
  echo "qbit-manage pod annotation sops-hash ($secret_rollout_revision) must equal git hash-object of qbit-manage-secret.sops.yaml ($secret_revision)." >&2
  exit 1
}
# [invariant] qbit_manage rewrites config.yml on startup, so it MUST land on a writable
# volume. Deliver it via the init-config copy from the read-only ConfigMap onto the writable
# emptyDir /config — never mount the ConfigMap directly at /config/config.yml (read-only),
# which crashes the app with "Read-only file system: '/config/config.yml'".
[[ "$(yq -r '.persistence.config.type' "$values")" == 'emptyDir' ]] || { echo 'qbit-manage /config must be a writable emptyDir (qbit_manage rewrites config.yml).' >&2; exit 1; }
[[ "$(yq -r '.persistence."config-src".type' "$values")" == 'configMap' ]] || { echo 'qbit-manage config.yml must come from the config-src ConfigMap (copied in by init-config).' >&2; exit 1; }
yq -r '.controllers."qbit-manage".initContainers."init-config".command | join(" ")' "$values" | rg -q 'cp /config-src/config\.yml /config/config\.yml' || { echo 'qbit-manage init-config must copy config.yml from /config-src onto the writable /config.' >&2; exit 1; }
# The app container must NOT receive a read-only config.yml mount (the bug that crash-looped it).
[[ "$(yq -r '[.persistence[] | select(.advancedMounts."qbit-manage".app[]?.path == "/config/config.yml")] | length' "$values")" == '0' ]] || { echo 'qbit-manage app must not mount config.yml read-only; it is copied onto the writable /config by init-config.' >&2; exit 1; }

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

# [invariant] Categories are owned by Sonarr/Radarr/Lidarr — qbit_manage must never change them.
[[ "$(yq -r '.commands.cat_update' "$config")" == 'false' ]] || { echo 'commands.cat_update must be false (never change categories).' >&2; exit 1; }
# [invariant] Destructive / unrelated features stay disabled in this plan.
for cmd in rem_unregistered rem_orphaned tag_nohardlinks tag_tracker_error recheck; do
  [[ "$(yq -r ".commands.$cmd" "$config")" == 'false' ]] || { echo "commands.$cmd must be false (destructive/unrelated feature)." >&2; exit 1; }
done
scripts/validate/qbit-manage-policy.sh "$config"

# The active policy classifies trackers, applies limits, and cleans up eligible public music and
# tv/movie torrents. The tracker/category safety gates above are intentionally validated separately.
[[ "$(yq -r '.commands.dry_run' "$config")" == 'false' ]] || { echo 'commands.dry_run must be false (the reviewed policy is active).' >&2; exit 1; }
[[ "$(yq -r '.commands.tag_update' "$config")" == 'true' ]] || { echo 'commands.tag_update must be true (classification is active).' >&2; exit 1; }
[[ "$(yq -r '.commands.share_limits' "$config")" == 'true' ]] || { echo 'commands.share_limits must be true (limits are active).' >&2; exit 1; }
[[ "$(yq -r '.commands.skip_cleanup' "$config")" == 'false' ]] || { echo 'commands.skip_cleanup must be false (the recycle-bin retention pass is active).' >&2; exit 1; }
[[ "$(yq -r '.recyclebin.enabled' "$config")" == 'true' ]] || { echo 'recyclebin.enabled must be true (download-side recovery window).' >&2; exit 1; }
rb_days="$(yq -r '.recyclebin.empty_after_x_days // 0' "$config")"; [[ "$rb_days" -ge 1 ]] || { echo 'recyclebin.empty_after_x_days must set a recovery window (>= 1).' >&2; exit 1; }

# --- No Gatus endpoint ever (UI-less; nothing to black-box probe over the gateway). ---
! rg -q '^    - name: qbit-manage$' kubernetes/apps/monitoring/gatus/app/values.yaml || { echo 'qbit-manage is UI-less and must not register a Gatus endpoint.' >&2; exit 1; }

# --- Pinned render: Deployment only, Recreate, no Service, no HTTPRoute ---
chart_url="$(yq -r '.spec.url' "$oci")"
chart_tag="$(yq -r '.spec.ref.tag' "$oci")"
kustomize build "$base/app" >/dev/null
helm template qbit-manage "$chart_url" --version "$chart_tag" --namespace media --values "$values" >"$temp_dir/render.yaml"
[[ "$(yq -r 'select(.kind == "Deployment") | .metadata.name' "$temp_dir/render.yaml")" == 'qbit-manage' ]]
[[ "$(yq -r 'select(.kind == "Deployment") | .spec.strategy.type' "$temp_dir/render.yaml")" == 'Recreate' ]]
[[ "$(yq -r 'select(.kind == "Deployment") | .spec.template.metadata.annotations."sops-hash"' "$temp_dir/render.yaml")" == "$secret_revision" ]]
! yq -r 'select(.kind == "Service") | .metadata.name' "$temp_dir/render.yaml" | rg -q . || { echo 'qbit-manage render unexpectedly contains a Service (should be UI-less).' >&2; exit 1; }
! yq -r 'select(.kind == "HTTPRoute") | .metadata.name' "$temp_dir/render.yaml" | rg -q . || { echo 'qbit-manage render unexpectedly contains an HTTPRoute.' >&2; exit 1; }

echo "qbit-manage $tag source (app-template, UI-less API client, SOPS creds via envFrom, category-based classification + share limits, cleanup via 7d recycle bin with tracker-private excluded and /data/media never mounted, no Service/HTTPRoute/Gatus, pinned render) passed validation."
