#!/usr/bin/env bash
# Guarded, operator-only qbit_manage policy E2E. It owns one fixed legal public fixture,
# one run-scoped category/tag/path set, and run-labeled ephemeral Kubernetes resources.
# It never adopts an existing fixture and never mounts or exposes media to qbit_manage.
# Single-quoted snippets intentionally expand only inside the in-pod shell.
# shellcheck disable=SC2016
set -Eeuo pipefail

[[ "$#" -eq 1 ]] || { echo 'Usage: qbit-manage-policy.sh <kubeconfig>' >&2; exit 2; }
kubeconfig="$1"
repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# shellcheck source=scripts/test/lib/qbit-manage-policy-e2e.sh
source scripts/test/lib/qbit-manage-policy-e2e.sh
scripts/test/safety/require-e2e-confirmation.sh qbit-manage-policy

ns='media'
run_dir="${HOMELAB_TEST_RUN_DIR:-}"
if [[ -z "$run_dir" ]]; then
  mkdir -p "$repo_root/.test-results"
  run_dir="$(mktemp -d "$repo_root/.test-results/$(date -u +%Y%m%dT%H%M%SZ)-$(git rev-parse --short=12 HEAD)-qbm-policy.XXXXXX")"
fi
mkdir -p "$run_dir/logs" "$run_dir/manifests" "$run_dir/diagnostics"
run_base="$(basename "$run_dir" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
[[ "${#run_base}" -ge 8 ]] || { echo 'Could not derive a safe E2E run ID.' >&2; exit 1; }
run_id="${run_base: -20}"
validate_qbm_e2e_run_id "$run_id" || { echo "Unsafe E2E run ID: $run_id" >&2; exit 1; }

fixture_hash="$QBM_E2E_FIXTURE_HASH"
fixture_url="$QBM_E2E_FIXTURE_URL"
category="e2e-qbm-${run_id}"
run_tag="$category"
limit_tag="e2e-qbm-limit-${run_id}"
torrent_name="e2e-qbm-${run_id}"
owned_tags_csv="${run_tag},${limit_tag},~e2e_qbm_${run_id}_1.e2e_qbm_${run_id},e2e_qbm_min_seed_${run_id},e2e_qbm_min_seeds_${run_id},e2e_qbm_last_active_${run_id}"
download_root="/data/downloads/.e2e-qbit-manage-${run_id}"
media_root="/data/media/.e2e-qbit-manage-${run_id}"
sentinel_path="${download_root}/.e2e-sentinel-${run_id}"
api_name="qbm-e2e-${run_id}-api"
api_config_map="${api_name}-script"
resource_selector="homelab-talos/e2e-run=${run_id}"

fixture_owned=false
category_owned=false
tags_owned=false
api_ready=false
sonarr_pod=''
source_path=''
media_path="${media_root}/payload"

k() { kubectl --kubeconfig "$kubeconfig" --namespace "$ns" "$@"; }

write_status() {
  local file="$1"
  local status="$2"
  local reason="$3"
  STATUS="$status" REASON="$reason" \
    yq --null-input --output-format json \
      '{"status": strenv(STATUS), "reason": strenv(REASON)}' >"$run_dir/$file"
}

write_status assertion.json not-classified 'workflow not completed'
write_status external-dependency.json not-classified 'fixture download not attempted'
write_status cleanup.json not-attempted 'teardown not started'
write_status recovery.json not-attempted 'teardown not started'

RUN_ID="$run_id" FIXTURE_HASH="$fixture_hash" CATEGORY="$category" \
DOWNLOAD_ROOT="$download_root" MEDIA_ROOT="$media_root" \
  yq --null-input --output-format json '{
    "schemaVersion": 1,
    "target": "qbit-manage-policy",
    "runId": strenv(RUN_ID),
    "fixture": {"infoHash": strenv(FIXTURE_HASH)},
    "ownership": {
      "category": strenv(CATEGORY),
      "downloadRoot": strenv(DOWNLOAD_ROOT),
      "mediaRoot": strenv(MEDIA_ROOT)
    },
    "phases": {},
    "jobs": {}
  }' >"$run_dir/evidence.json"

mark_assertion_failed() {
  write_status assertion.json failed "$1"
  return 1
}

mark_dependency_failed() {
  write_status external-dependency.json failed "$1"
  write_status assertion.json not-classified 'workflow stopped at the external fixture dependency'
  return 1
}

unexpected_error() {
  local assertion_status external_status
  trap - ERR
  set +e
  assertion_status="$(yq -r '.status' "$run_dir/assertion.json" 2>/dev/null)"
  external_status="$(yq -r '.status' "$run_dir/external-dependency.json" 2>/dev/null)"
  if [[ "$assertion_status" == 'not-classified' && "$external_status" != 'failed' ]]; then
    write_status assertion.json failed 'unexpected orchestrator or infrastructure failure'
  fi
}
trap unexpected_error ERR

app_exec_script() {
  local script="$1"
  shift
  k exec "$sonarr_pod" -c app -- sh -eu -c "$script" qbm-e2e "$@"
}

api() {
  [[ "$api_ready" == true ]] || return 1
  k exec "$api_name" -- /opt/e2e/qbt-api.sh "$@"
}

torrent_has_tag() {
  local info_json="$1"
  local expected_tag="$2"
  EXPECTED_TAG="$expected_tag" yq -e '
    length == 1 and
    (.[0].tags | split(",") | map(sub("^[ ]+"; "") | sub("[ ]+$"; "")) |
      any_c(. == strenv(EXPECTED_TAG)))
  ' <<<"$info_json" >/dev/null
}

safe_remove_owned_path() {
  local path="$1"
  validate_qbm_e2e_owned_path "$run_id" "$path" || {
    echo "Refusing unsafe teardown path: $path" >&2
    return 1
  }
  app_exec_script 'rm -rf -- "$1"' "$path"
}

discover_recycle_paths() {
  app_exec_script '
    root=/data/downloads/.RecycleBin
    [ -d "$root" ] || exit 0
    find "$root" -mindepth 1 -maxdepth 2 -name "*$1*" -print
  ' "$run_id"
}

cleanup() {
  local original_exit="$?"
  local cleanup_ok=true
  local info_json categories_json tags_json recycle_paths path remaining owned_tag
  trap - EXIT ERR
  set +e
  write_status cleanup.json not-attempted 'exact run-owned teardown in progress'
  write_status recovery.json not-attempted 'exact run-owned teardown in progress'

  if [[ "$api_ready" == true ]]; then
    if [[ "$fixture_owned" == true ]]; then
      info_json="$(api info "$fixture_hash" 2>/dev/null)"
      if [[ "$(yq -r 'length' <<<"$info_json" 2>/dev/null)" != '0' ]]; then
        api delete "$fixture_hash" >/dev/null 2>&1 || cleanup_ok=false
      fi
    fi
    if [[ "$category_owned" == true ]]; then
      api remove-category "$category" >/dev/null 2>&1 || cleanup_ok=false
    fi
    if [[ "$tags_owned" == true ]]; then
      api delete-tags "$owned_tags_csv" >/dev/null 2>&1 || cleanup_ok=false
    fi
    info_json="$(api info "$fixture_hash" 2>/dev/null)"
    [[ "$(yq -r 'length' <<<"$info_json" 2>/dev/null)" == '0' ]] || cleanup_ok=false
    categories_json="$(api categories 2>/dev/null)"
    CATEGORY="$category" yq -e 'has(strenv(CATEGORY)) | not' \
      <<<"$categories_json" >/dev/null 2>&1 || cleanup_ok=false
    tags_json="$(api tags 2>/dev/null)"
    while IFS= read -r owned_tag; do
      OWNED_TAG="$owned_tag" yq -e 'any_c(. == strenv(OWNED_TAG)) | not' \
        <<<"$tags_json" >/dev/null 2>&1 || cleanup_ok=false
    done < <(tr ',' '\n' <<<"$owned_tags_csv")
  elif [[ "$fixture_owned" == true || "$category_owned" == true || "$tags_owned" == true ]]; then
    cleanup_ok=false
  fi

  if [[ -n "$sonarr_pod" ]]; then
    safe_remove_owned_path "$download_root" >/dev/null 2>&1 || cleanup_ok=false
    safe_remove_owned_path "$media_root" >/dev/null 2>&1 || cleanup_ok=false
    recycle_paths="$(discover_recycle_paths 2>/dev/null)"
    while IFS= read -r path; do
      [[ -z "$path" ]] || safe_remove_owned_path "$path" >/dev/null 2>&1 || cleanup_ok=false
    done <<<"$recycle_paths"
    app_exec_script '
      [ ! -e "$1" ] && [ ! -e "$2" ] &&
      ! find /data/downloads/.RecycleBin -mindepth 1 -maxdepth 2 -name "*$3*" -print -quit 2>/dev/null | grep -q .
    ' "$download_root" "$media_root" "$run_id" >/dev/null 2>&1 || cleanup_ok=false
  elif [[ "$fixture_owned" == true ]]; then
    cleanup_ok=false
  fi

  k delete job,configmap,pod --selector "$resource_selector" \
    --ignore-not-found=true --wait=true --timeout=2m >/dev/null 2>&1 || cleanup_ok=false
  remaining="$(k get job,configmap,pod --selector "$resource_selector" \
    --output name --ignore-not-found 2>/dev/null)"
  [[ -z "$remaining" ]] || cleanup_ok=false

  if [[ "$cleanup_ok" == true ]]; then
    write_status cleanup.json passed 'all exact run-owned state removed'
    write_status recovery.json passed 'all exact run-owned state removed'
  else
    write_status cleanup.json failed "manual check required for run ${run_id}: ${download_root}, ${media_root}, and run-labeled media resources"
    write_status recovery.json failed "manual check required for run ${run_id}: ${download_root}, ${media_root}, and run-labeled media resources"
  fi
  return "$original_exit"
}
trap cleanup EXIT

create_api_helper() {
  local script_content
  local config_manifest="$run_dir/manifests/api-configmap.yaml"
  local pod_manifest="$run_dir/manifests/api-pod.yaml"
  script_content="$(<scripts/test/helpers/qbit-manage-policy-api.sh)"

  RUN_ID="$run_id" NAME="$api_config_map" SCRIPT_CONTENT="$script_content" \
    yq --null-input '{
      "apiVersion": "v1",
      "kind": "ConfigMap",
      "metadata": {
        "name": strenv(NAME),
        "namespace": "media",
        "labels": {
          "homelab-talos/e2e-run": strenv(RUN_ID),
          "homelab-talos/e2e-target": "qbit-manage-policy"
        }
      },
      "data": {"qbt-api.sh": strenv(SCRIPT_CONTENT)}
    }' >"$config_manifest"

  RUN_ID="$run_id" NAME="$api_name" CONFIG_MAP="$api_config_map" \
    yq --null-input '{
      "apiVersion": "v1",
      "kind": "Pod",
      "metadata": {
        "name": strenv(NAME),
        "namespace": "media",
        "labels": {
          "homelab-talos/e2e-run": strenv(RUN_ID),
          "homelab-talos/e2e-target": "qbit-manage-policy"
        }
      },
      "spec": {
        "restartPolicy": "Never",
        "automountServiceAccountToken": false,
        "securityContext": {
          "runAsNonRoot": true,
          "runAsUser": 100,
          "runAsGroup": 100,
          "seccompProfile": {"type": "RuntimeDefault"}
        },
        "containers": [{
          "name": "api",
          "image": "curlimages/curl:8.11.1",
          "command": ["/bin/sh", "-c"],
          "args": ["sleep 3600"],
          "envFrom": [{"secretRef": {"name": "qbit-manage-secret"}}],
          "securityContext": {
            "allowPrivilegeEscalation": false,
            "capabilities": {"drop": ["ALL"]}
          },
          "volumeMounts": [{
            "name": "script",
            "mountPath": "/opt/e2e",
            "readOnly": true
          }]
        }],
        "volumes": [{
          "name": "script",
          "configMap": {
            "name": strenv(CONFIG_MAP),
            "defaultMode": 365
          }
        }]
      }
    }' >"$pod_manifest"

  k apply -f "$config_manifest" >/dev/null
  k apply -f "$pod_manifest" >/dev/null
  k wait --for=condition=Ready "pod/$api_name" --timeout=3m >/dev/null
  api_ready=true
}

wait_for_job() {
  local job_name="$1"
  local job_json complete failed
  for _ in {1..24}; do
    job_json="$(k get job "$job_name" --output json)"
    complete="$(yq -r '.status.conditions[]? | select(.type == "Complete") | .status' <<<"$job_json")"
    failed="$(yq -r '.status.conditions[]? | select(.type == "Failed") | .status' <<<"$job_json")"
    [[ "$complete" == 'True' ]] && return 0
    [[ "$failed" == 'True' ]] && return 1
    sleep 5
  done
  return 1
}

run_policy_job() {
  local phase="$1"
  local cleanup_enabled="$2"
  local config_file="$run_dir/manifests/${phase}-config.yml"
  local config_manifest="$run_dir/manifests/${phase}-configmap.yaml"
  local job_manifest="$run_dir/manifests/${phase}-job.yaml"
  local config_map="qbm-e2e-${run_id}-${phase}"
  local job_name="$config_map"
  local config_content

  generate_qbm_e2e_policy_config "$live_config" "$config_file" "$run_id" "$cleanup_enabled"
  validate_qbm_e2e_policy_config "$config_file" "$run_id" "$cleanup_enabled"
  config_content="$(<"$config_file")"
  RUN_ID="$run_id" NAME="$config_map" CONFIG_CONTENT="$config_content" \
    yq --null-input '{
      "apiVersion": "v1",
      "kind": "ConfigMap",
      "metadata": {
        "name": strenv(NAME),
        "namespace": "media",
        "labels": {
          "homelab-talos/e2e-run": strenv(RUN_ID),
          "homelab-talos/e2e-target": "qbit-manage-policy"
        }
      },
      "data": {"config.yml": strenv(CONFIG_CONTENT)}
    }' >"$config_manifest"
  generate_qbm_e2e_job_manifest "$job_manifest" "$run_id" "$phase" "$qbm_image" "$config_map"

  k apply -f "$config_manifest" >/dev/null
  k apply -f "$job_manifest" >/dev/null
  wait_for_job "$job_name" || {
    echo "qbit_manage one-shot Job failed in phase $phase; application logs were not collected." >&2
    return 1
  }
  PHASE="$phase" JOB_NAME="$job_name" yq -i \
    '.jobs[strenv(PHASE)] = {"name": strenv(JOB_NAME), "status": "passed"}' \
    "$run_dir/evidence.json"
  k delete job "$job_name" --ignore-not-found=true --wait=true --timeout=2m >/dev/null
  k delete configmap "$config_map" --ignore-not-found=true --wait=true --timeout=2m >/dev/null
}

echo "Preflight: validating live qBittorrent/qbit_manage and run isolation (${run_id})."
scripts/verify/qbittorrent.sh "$kubeconfig"
scripts/verify/qbit-manage.sh "$kubeconfig"
k wait --for=condition=Ready pod --selector app.kubernetes.io/name=qbittorrent --timeout=5m >/dev/null
k wait --for=condition=Ready pod --selector app.kubernetes.io/name=sonarr --timeout=5m >/dev/null
sonarr_pod="$(
  k get pod --selector app.kubernetes.io/name=sonarr --output json |
    yq -r '[.items[] | select(.status.phase == "Running")][0].metadata.name // ""'
)"
[[ -n "$sonarr_pod" ]] || mark_assertion_failed 'no running Sonarr hardlink-probe pod'

deployment_json="$(k get deployment qbit-manage --output json)"
qbm_image="$(
  yq -r '.spec.template.spec.containers[] | select(.name == "app") | .image' <<<"$deployment_json"
)"
qbm_init_image="$(
  yq -r '.spec.template.spec.initContainers[] | select(.name == "init-config") | .image' <<<"$deployment_json"
)"
[[ "$qbm_image" == 'ghcr.io/stuffanthings/qbit_manage:v4.10.0' &&
  "$qbm_init_image" == "$qbm_image" ]] ||
  mark_assertion_failed 'live qbit_manage image differs from the validated v4.10.0 interface'
yq -e '
  .spec.template.spec.securityContext.runAsNonRoot == true and
  .spec.template.spec.securityContext.runAsUser == 568 and
  .spec.template.spec.securityContext.runAsGroup == 568 and
  .spec.template.spec.securityContext.fsGroup == 568 and
  .spec.template.spec.securityContext.seccompProfile.type == "RuntimeDefault"
' <<<"$deployment_json" >/dev/null ||
  mark_assertion_failed 'live qbit_manage security context or 15-minute schedule drifted'
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "app") |
  .securityContext.allowPrivilegeEscalation' <<<"$deployment_json")" == 'false' &&
  "$(yq -o=json -I=0 '.spec.template.spec.containers[] | select(.name == "app") |
  .securityContext.capabilities.drop' <<<"$deployment_json")" == '["ALL"]' &&
  "$(yq -r '.spec.template.spec.containers[] | select(.name == "app") |
  .env[] | select(.name == "QBT_SCHEDULE") | .value' <<<"$deployment_json")" == '15' ]] ||
  mark_assertion_failed 'live qbit_manage app security context or schedule drifted'

live_config_map="$(
  yq -r '.spec.template.spec.volumes[] |
    select(.name == "config-src") | .configMap.name' <<<"$deployment_json"
)"
live_config="$run_dir/manifests/deployed-config.yml"
k get configmap "$live_config_map" --output json | yq -r '.data."config.yml"' >"$live_config"
live_categories="$(yq -o=json -I=0 '.share_limits.public.categories | sort' "$live_config")"
live_private_exclusion="$(
  yq -o=json -I=0 '.share_limits.public.exclude_any_tags' "$live_config"
)"
yq -e '
  .commands.tag_update == true and
  .commands.share_limits == true and
  .directory.root_dir == "/data/downloads"
' "$live_config" >/dev/null ||
  mark_assertion_failed 'deployed production policy no longer provides category isolation'
[[ "$live_categories" == '["movies","tv"]' &&
  "$live_private_exclusion" == '["tracker-private"]' ]] ||
  mark_assertion_failed 'deployed production category/private exclusion drifted'

existing_resources="$(k get job,configmap,pod --selector "$resource_selector" --output name 2>/dev/null)"
[[ -z "$existing_resources" ]] || mark_assertion_failed 'run-labeled Kubernetes resources already exist'
app_exec_script '[ ! -e "$1" ] && [ ! -e "$2" ]' "$download_root" "$media_root" ||
  mark_assertion_failed 'run-owned filesystem path already exists'
[[ -z "$(discover_recycle_paths)" ]] || mark_assertion_failed 'run-owned recycle path already exists'

create_api_helper
preexisting_info="$(api info "$fixture_hash")"
qbm_e2e_refuse_preexisting_fixture "$preexisting_info"
preexisting_categories="$(api categories)"
CATEGORY="$category" yq -e 'has(strenv(CATEGORY)) | not' \
  <<<"$preexisting_categories" >/dev/null ||
  mark_assertion_failed 'run-named qBittorrent category already exists'
preexisting_tags="$(api tags)"
while IFS= read -r owned_tag; do
  if OWNED_TAG="$owned_tag" yq -e 'any_c(. == strenv(OWNED_TAG))' \
    <<<"$preexisting_tags" >/dev/null; then
    mark_assertion_failed 'run-named qBittorrent tag already exists'
  fi
done < <(tr ',' '\n' <<<"$owned_tags_csv")

api create-category "$category" "$download_root" >/dev/null
category_owned=true
api create-tags "$run_tag" >/dev/null
tags_owned=true

echo 'Download: adding the legal Sintel fixture through the VPN-backed qBittorrent instance.'
add_response="$(api add "$fixture_url" "$download_root" "$category" "$torrent_name")"
[[ "$add_response" == 'Ok.' ]] || mark_dependency_failed 'qBittorrent rejected the public fixture URL'
fixture_owned=true

download_complete=false
info_json='[]'
files_json='[]'
for _ in {1..120}; do
  info_json="$(api info "$fixture_hash")"
  if CATEGORY="$category" SAVE_PATH="$download_root" yq -e '
    length == 1 and
    .[0].hash == "08ada5a7a6183aae1e09d831df6748d566095a10" and
    .[0].category == strenv(CATEGORY) and
    (.[0].save_path | sub("/+$"; "")) == strenv(SAVE_PATH) and
    .[0].progress == 1 and
    .[0].amount_left == 0
  ' <<<"$info_json" >/dev/null; then
    files_json="$(api files "$fixture_hash")"
    if yq -e 'length > 0 and all_c(.progress == 1) and any_c(.size > 0)' \
      <<<"$files_json" >/dev/null; then
      download_complete=true
      break
    fi
  fi
  sleep 10
done
[[ "$download_complete" == true ]] ||
  mark_dependency_failed 'Sintel did not complete through VPN egress within 20 minutes'
write_status external-dependency.json passed 'public fixture downloaded and verified complete'
DOWNLOAD_SIZE="$(yq -r '.[0].size' <<<"$info_json")" \
COMPLETION_ON="$(yq -r '.[0].completion_on' <<<"$info_json")" \
FILE_COUNT="$(yq -r 'length' <<<"$files_json")" \
  yq -i '.phases.download = {
    "status": "passed",
    "sizeBytes": (strenv(DOWNLOAD_SIZE) | tonumber),
    "completionOn": (strenv(COMPLETION_ON) | tonumber),
    "fileCount": (strenv(FILE_COUNT) | tonumber)
  }' "$run_dir/evidence.json"

echo 'Classification: waiting for the deployed 15-minute scheduler to add tracker-public.'
classified=false
for _ in {1..120}; do
  info_json="$(api info "$fixture_hash")"
  if torrent_has_tag "$info_json" tracker-public &&
    ! torrent_has_tag "$info_json" tracker-private; then
    classified=true
    break
  fi
  sleep 10
done
[[ "$classified" == true ]] ||
  mark_assertion_failed 'production scheduler did not classify the fixture public within 20 minutes'
CLASSIFIED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)" yq -i \
  '.phases.classification = {
    "status": "passed",
    "classifiedAt": strenv(CLASSIFIED_AT),
    "tags": ["tracker-public"]
  }' "$run_dir/evidence.json"

api add-tags "$fixture_hash" "$run_tag" >/dev/null
files_json="$(api files "$fixture_hash")"
payload_rel="$(yq -r '[.[] | select(.size > 0 and .progress == 1)] | sort_by(.size) | .[-1].name' <<<"$files_json")"
validate_qbm_e2e_relative_payload "$payload_rel" ||
  mark_assertion_failed 'fixture returned an unsafe payload path'
source_path="${download_root}/${payload_rel}"
validate_qbm_e2e_owned_path "$run_id" "$source_path" ||
  mark_assertion_failed 'payload escaped the run-owned download root'

hardlink_stats="$(
  app_exec_script '
    mkdir -p "$2"
    ln "$1" "$2/payload"
    printf "%s %s %s %s" \
      "$(stat -c %i "$1")" "$(stat -c %h "$1")" "$(stat -c %s "$1")" \
      "$(sha256sum "$1" | cut -d " " -f 1)"
  ' "$source_path" "$media_root"
)"
read -r source_inode source_links source_size source_digest <<<"$hardlink_stats"
media_stats="$(app_exec_script '
  printf "%s %s %s %s" \
    "$(stat -c %i "$1")" "$(stat -c %h "$1")" "$(stat -c %s "$1")" \
    "$(sha256sum "$1" | cut -d " " -f 1)"
' "$media_path")"
read -r media_inode media_links media_size media_digest <<<"$media_stats"
[[ "$source_inode" =~ ^[0-9]+$ && "$source_inode" == "$media_inode" &&
  "$source_links" -ge 2 && "$media_links" -ge 2 &&
  "$source_size" == "$media_size" && "$source_digest" == "$media_digest" ]] ||
  mark_assertion_failed 'representative import did not produce a verified hardlink'
app_exec_script 'printf "%s" "$2" >"$1"' "$sentinel_path" "$run_id"
SOURCE_INODE="$source_inode" SOURCE_LINKS="$source_links" SOURCE_SIZE="$source_size" \
SOURCE_DIGEST="$source_digest" SOURCE_PATH="$source_path" MEDIA_PATH="$media_path" \
  yq -i '.phases.hardlink = {
    "status": "passed",
    "sourcePath": strenv(SOURCE_PATH),
    "mediaPath": strenv(MEDIA_PATH),
    "inode": (strenv(SOURCE_INODE) | tonumber),
    "initialLinkCount": (strenv(SOURCE_LINKS) | tonumber),
    "sizeBytes": (strenv(SOURCE_SIZE) | tonumber),
    "sha256": strenv(SOURCE_DIGEST)
  }' "$run_dir/evidence.json"

echo 'Private exclusion: proving tracker-private prevents the isolated cleanup policy.'
api add-tags "$fixture_hash" tracker-private >/dev/null
info_json="$(api info "$fixture_hash")"
if ! torrent_has_tag "$info_json" tracker-private ||
  ! torrent_has_tag "$info_json" "$run_tag"; then
  mark_assertion_failed 'private-exclusion premise was absent immediately before the Job'
fi
run_policy_job private true
info_json="$(api info "$fixture_hash")"
CATEGORY="$category" yq -e 'length == 1 and .[0].category == strenv(CATEGORY)' \
  <<<"$info_json" >/dev/null ||
  mark_assertion_failed 'private fixture was removed or recategorized'
torrent_has_tag "$info_json" "$limit_tag" &&
  mark_assertion_failed 'private fixture incorrectly received the isolated limit tag'
app_exec_script '[ -f "$1" ] && [ -f "$2" ] && [ -f "$3" ]' \
  "$source_path" "$media_path" "$sentinel_path" ||
  mark_assertion_failed 'private exclusion did not preserve all run-owned files'
api remove-tags "$fixture_hash" tracker-private >/dev/null
info_json="$(api info "$fixture_hash")"
if torrent_has_tag "$info_json" tracker-private ||
  ! torrent_has_tag "$info_json" "$run_tag"; then
  mark_assertion_failed 'failed to remove only the temporary private tag'
fi
yq -i '.phases.privateExclusion = {"status": "passed"}' "$run_dir/evidence.json"

echo 'Limits: applying the isolated two-minute stop policy without cleanup.'
run_policy_job limits false
limits_observed=false
for _ in {1..36}; do
  info_json="$(api info "$fixture_hash")"
  if CATEGORY="$category" yq -e '
    length == 1 and
    .[0].category == strenv(CATEGORY) and
    .[0].ratio_limit >= 0.009999 and .[0].ratio_limit <= 0.010001 and
    .[0].seeding_time_limit == 120 and
    (.[0].state == "stoppedUP" or .[0].state == "pausedUP")
  ' <<<"$info_json" >/dev/null &&
    torrent_has_tag "$info_json" "$limit_tag"; then
    limits_observed=true
    break
  fi
  sleep 5
done
[[ "$limits_observed" == true ]] ||
  mark_assertion_failed 'qbit_manage limits/tag/Stop state were not observed within three minutes'
app_exec_script '[ -f "$1" ] && [ -f "$2" ] && [ -f "$3" ]' \
  "$source_path" "$media_path" "$sentinel_path" ||
  mark_assertion_failed 'limit application removed run-owned files before cleanup'
LIMIT_STATE="$(yq -r '.[0].state' <<<"$info_json")" \
  yq -i '.phases.limits = {
    "status": "passed",
    "ratioLimit": 0.01,
    "seedingTimeLimitSeconds": 120,
    "state": strenv(LIMIT_STATE)
  }' "$run_dir/evidence.json"

echo 'Cleanup: running the recycle-bin policy and verifying hardlink survival.'
run_policy_job cleanup true
for _ in {1..12}; do
  info_json="$(api info "$fixture_hash")"
  [[ "$(yq -r 'length' <<<"$info_json")" -eq 0 ]] && break
  sleep 5
done
[[ "$(yq -r 'length' <<<"$info_json")" -eq 0 ]] ||
  mark_assertion_failed 'cleanup Job did not remove the owned torrent'
app_exec_script '[ ! -e "$1" ] && [ -f "$2" ] && [ -f "$3" ]' \
  "$source_path" "$media_path" "$sentinel_path" ||
  mark_assertion_failed 'cleanup did not remove only the payload-side path'
recycle_paths_before="$(discover_recycle_paths)"
[[ -n "$recycle_paths_before" ]] ||
  mark_assertion_failed 'cleanup did not create run-owned recycle-bin data'
while IFS= read -r recycle_path; do
  [[ -z "$recycle_path" ]] ||
    validate_qbm_e2e_owned_path "$run_id" "$recycle_path" ||
    mark_assertion_failed 'cleanup produced an unsafe or unowned recycle path'
done <<<"$recycle_paths_before"

media_stats_after="$(app_exec_script '
  printf "%s %s %s %s" \
    "$(stat -c %i "$1")" "$(stat -c %h "$1")" "$(stat -c %s "$1")" \
    "$(sha256sum "$1" | cut -d " " -f 1)"
' "$media_path")"
read -r media_inode_after media_links_after media_size_after media_digest_after <<<"$media_stats_after"
[[ "$media_inode_after" == "$media_inode" &&
  "$media_size_after" == "$media_size" &&
  "$media_digest_after" == "$media_digest" ]] ||
  mark_assertion_failed 'media hardlink inode, size, or digest changed during cleanup'

run_policy_job cleanup2 true
[[ "$(yq -r 'length' <<<"$(api info "$fixture_hash")")" -eq 0 ]] ||
  mark_assertion_failed 'idempotent cleanup unexpectedly recreated the torrent'
recycle_paths_after="$(discover_recycle_paths)"
[[ "$recycle_paths_after" == "$recycle_paths_before" ]] ||
  mark_assertion_failed 'idempotent cleanup created a duplicate recycle entry'
MEDIA_LINKS_AFTER="$media_links_after" RECYCLE_PATHS="$recycle_paths_after" \
  yq -i '.phases.cleanup = {
    "status": "passed",
    "mediaPostCleanupLinkCount": (strenv(MEDIA_LINKS_AFTER) | tonumber),
    "recyclePaths": (strenv(RECYCLE_PATHS) | split("\n"))
  }' "$run_dir/evidence.json"

write_status assertion.json passed 'classification, private exclusion, limits, recycle cleanup, hardlink survival, and idempotency passed'
echo "PASS: qbit_manage real-download policy E2E completed for owned run ${run_id}. Evidence: $run_dir"
