#!/usr/bin/env bash

# Consumed by the sourced orchestrator; ShellCheck analyzes this library independently.
# shellcheck disable=SC2034
QBM_E2E_FIXTURE_URL='https://webtorrent.io/torrents/sintel.torrent'
# shellcheck disable=SC2034
QBM_E2E_FIXTURE_HASH='08ada5a7a6183aae1e09d831df6748d566095a10'

validate_qbm_e2e_run_id() {
  [[ "$1" =~ ^[a-z0-9]{8,24}$ ]]
}

qbm_e2e_refuse_preexisting_fixture() {
  local info_json="$1"
  [[ "$(yq -r 'length' <<<"$info_json")" -eq 0 ]] || {
    echo "Refusing to adopt the pre-existing Sintel fixture (${QBM_E2E_FIXTURE_HASH})." >&2
    return 1
  }
}

validate_qbm_e2e_relative_payload() {
  local path="$1"
  [[ -n "$path" && "$path" != /* && "$path" != '..' && "$path" != ../* &&
    "$path" != */../* && "$path" != */.. ]]
}

validate_qbm_e2e_owned_path() {
  local run_id="$1"
  local path="$2"
  local download_root="/data/downloads/.e2e-qbit-manage-${run_id}"
  local media_root="/data/media/.e2e-qbit-manage-${run_id}"

  validate_qbm_e2e_run_id "$run_id" || return 1
  [[ -n "$path" && "$path" != *'..'* ]] || return 1
  case "$path" in
    "$download_root"|"$download_root"/*) return 0 ;;
    "$media_root"|"$media_root"/*) return 0 ;;
    /data/downloads/.RecycleBin/*"$run_id"*) return 0 ;;
    *) return 1 ;;
  esac
}

generate_qbm_e2e_policy_config() {
  local source_file="$1"
  local output_file="$2"
  local run_id="$3"
  local cleanup="$4"
  local group="e2e_qbm_${run_id}"
  local match="e2e-qbm-${run_id}"
  local limit_tag="e2e-qbm-limit-${run_id}"

  validate_qbm_e2e_run_id "$run_id" || {
    echo "Invalid qbit_manage E2E run ID: $run_id" >&2
    return 1
  }
  [[ "$cleanup" == true || "$cleanup" == false ]] || {
    echo "cleanup must be true or false, got: $cleanup" >&2
    return 1
  }

  RUN_ID="$run_id" GROUP="$group" MATCH="$match" LIMIT_TAG="$limit_tag" CLEANUP="$cleanup" \
    yq eval '{
      "commands": {
        "dry_run": false,
        "recheck": false,
        "cat_update": false,
        "tag_update": false,
        "rem_unregistered": false,
        "tag_tracker_error": false,
        "rem_orphaned": false,
        "tag_nohardlinks": false,
        "share_limits": true,
        "skip_cleanup": true
      },
      "qbt": .qbt,
      "settings": {
        "disable_qbt_default_share_limits": false,
        "share_limits_filter_completed": true,
        "share_limits_tag": ("~e2e_qbm_" + strenv(RUN_ID)),
        "share_limits_min_seeding_time_tag": ("e2e_qbm_min_seed_" + strenv(RUN_ID)),
        "share_limits_min_num_seeds_tag": ("e2e_qbm_min_seeds_" + strenv(RUN_ID)),
        "share_limits_last_active_tag": ("e2e_qbm_last_active_" + strenv(RUN_ID))
      },
      "directory": .directory,
      "recyclebin": (.recyclebin | .enabled = true | .save_torrents = false),
      "share_limits": {
        (strenv(GROUP)): {
          "priority": 1,
          "categories": [strenv(MATCH)],
          "include_all_tags": [strenv(MATCH)],
          "exclude_any_tags": ["tracker-private"],
          "custom_tag": strenv(LIMIT_TAG),
          "add_group_to_tag": true,
          "max_ratio": 0.01,
          "min_seeding_time": "1m",
          "max_seeding_time": "2m",
          "share_limit_action": "Stop",
          "cleanup": (strenv(CLEANUP) == "true")
        }
      }
    }' "$source_file" >"$output_file"
}

validate_qbm_e2e_policy_config() {
  local config_file="$1"
  local run_id="$2"
  local cleanup="$3"
  local group="e2e_qbm_${run_id}"
  local match="e2e-qbm-${run_id}"
  local limit_tag="e2e-qbm-limit-${run_id}"
  local top_keys command_keys setting_keys

  validate_qbm_e2e_run_id "$run_id" || return 1
  top_keys="$(yq -o=json -I=0 'keys | sort' "$config_file")"
  command_keys="$(yq -o=json -I=0 '.commands | keys | sort' "$config_file")"
  setting_keys="$(yq -o=json -I=0 '.settings | keys | sort' "$config_file")"
  [[ "$top_keys" == '["commands","directory","qbt","recyclebin","settings","share_limits"]' ]] ||
    return 1
  [[ "$command_keys" == '["cat_update","dry_run","recheck","rem_orphaned","rem_unregistered","share_limits","skip_cleanup","tag_nohardlinks","tag_tracker_error","tag_update"]' ]] ||
    return 1
  [[ "$setting_keys" == '["disable_qbt_default_share_limits","share_limits_filter_completed","share_limits_last_active_tag","share_limits_min_num_seeds_tag","share_limits_min_seeding_time_tag","share_limits_tag"]' ]] ||
    return 1
  RUN_ID="$run_id" GROUP="$group" MATCH="$match" LIMIT_TAG="$limit_tag" CLEANUP="$cleanup" \
    yq -e '
      .commands.dry_run == false and
      .commands.recheck == false and
      .commands.cat_update == false and
      .commands.tag_update == false and
      .commands.rem_unregistered == false and
      .commands.tag_tracker_error == false and
      .commands.rem_orphaned == false and
      .commands.tag_nohardlinks == false and
      .commands.share_limits == true and
      .commands.skip_cleanup == true and
      .qbt.host == "http://qbittorrent.media.svc.cluster.local:8080" and
      .qbt.user == "QBT_USER" and (.qbt.user | tag) == "!ENV" and
      .qbt.pass == "QBT_PASS" and (.qbt.pass | tag) == "!ENV" and
      .directory.root_dir == "/data/downloads" and
      .recyclebin.enabled == true and
      .recyclebin.save_torrents == false and
      .settings.disable_qbt_default_share_limits == false and
      .settings.share_limits_filter_completed == true and
      .settings.share_limits_tag == ("~e2e_qbm_" + strenv(RUN_ID)) and
      .settings.share_limits_min_seeding_time_tag == ("e2e_qbm_min_seed_" + strenv(RUN_ID)) and
      .settings.share_limits_min_num_seeds_tag == ("e2e_qbm_min_seeds_" + strenv(RUN_ID)) and
      .settings.share_limits_last_active_tag == ("e2e_qbm_last_active_" + strenv(RUN_ID)) and
      (.share_limits | length) == 1 and
      (.share_limits | has(strenv(GROUP))) and
      (.share_limits | .[strenv(GROUP)].priority) == 1 and
      (.share_limits | .[strenv(GROUP)].categories | length) == 1 and
      (.share_limits | .[strenv(GROUP)].categories[0]) == strenv(MATCH) and
      (.share_limits | .[strenv(GROUP)].include_all_tags | length) == 1 and
      (.share_limits | .[strenv(GROUP)].include_all_tags[0]) == strenv(MATCH) and
      (.share_limits | .[strenv(GROUP)].exclude_any_tags | length) == 1 and
      (.share_limits | .[strenv(GROUP)].exclude_any_tags[0]) == "tracker-private" and
      (.share_limits | .[strenv(GROUP)].custom_tag) == strenv(LIMIT_TAG) and
      (.share_limits | .[strenv(GROUP)].add_group_to_tag) == true and
      (.share_limits | .[strenv(GROUP)].max_ratio) == 0.01 and
      (.share_limits | .[strenv(GROUP)].min_seeding_time) == "1m" and
      (.share_limits | .[strenv(GROUP)].max_seeding_time) == "2m" and
      (.share_limits | .[strenv(GROUP)].share_limit_action) == "Stop" and
      (.share_limits | .[strenv(GROUP)].cleanup) == (strenv(CLEANUP) == "true")
    ' "$config_file" >/dev/null
}

generate_qbm_e2e_job_manifest() {
  local output_file="$1"
  local run_id="$2"
  local phase="$3"
  local image="$4"
  local config_map="$5"
  local job_name="qbm-e2e-${run_id}-${phase}"

  validate_qbm_e2e_run_id "$run_id" || return 1
  [[ "$phase" =~ ^[a-z0-9-]{2,16}$ ]] || return 1
  [[ -n "$image" && -n "$config_map" ]] || return 1

  RUN_ID="$run_id" JOB_NAME="$job_name" IMAGE="$image" CONFIG_MAP="$config_map" \
    yq --null-input '
      {
        "apiVersion": "batch/v1",
        "kind": "Job",
        "metadata": {
          "name": strenv(JOB_NAME),
          "namespace": "media",
          "labels": {
            "homelab-talos/e2e-run": strenv(RUN_ID),
            "homelab-talos/e2e-target": "qbit-manage-policy"
          }
        },
        "spec": {
          "backoffLimit": 0,
          "activeDeadlineSeconds": 120,
          "ttlSecondsAfterFinished": 600,
          "template": {
            "metadata": {
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
                "runAsUser": 568,
                "runAsGroup": 568,
                "fsGroup": 568,
                "fsGroupChangePolicy": "OnRootMismatch",
                "seccompProfile": {"type": "RuntimeDefault"}
              },
              "initContainers": [{
                "name": "init-config",
                "image": strenv(IMAGE),
                "command": ["/bin/sh", "-c", "cp /config-src/config.yml /config/config.yml"],
                "securityContext": {
                  "allowPrivilegeEscalation": false,
                  "capabilities": {"drop": ["ALL"]}
                },
                "volumeMounts": [
                  {"name": "config", "mountPath": "/config"},
                  {"name": "config-src", "mountPath": "/config-src", "readOnly": true}
                ]
              }],
              "containers": [{
                "name": "app",
                "image": strenv(IMAGE),
                "args": ["python3", "qbit_manage.py", "--run"],
                "env": [
                  {"name": "QBT_WEB_SERVER", "value": "false"},
                  {"name": "QBT_CONFIG_DIR", "value": "/config"},
                  {"name": "QBT_LOGFILE", "value": "qbit_manage.log"},
                  {"name": "QBT_LOG_LEVEL", "value": "INFO"},
                  {"name": "PYTHONDONTWRITEBYTECODE", "value": "1"}
                ],
                "envFrom": [{"secretRef": {"name": "qbit-manage-secret"}}],
                "securityContext": {
                  "allowPrivilegeEscalation": false,
                  "capabilities": {"drop": ["ALL"]}
                },
                "volumeMounts": [
                  {"name": "config", "mountPath": "/config"},
                  {
                    "name": "data",
                    "mountPath": "/data/downloads",
                    "subPath": "downloads"
                  }
                ]
              }],
              "volumes": [
                {"name": "config", "emptyDir": {}},
                {"name": "config-src", "configMap": {"name": strenv(CONFIG_MAP)}},
                {"name": "data", "persistentVolumeClaim": {"claimName": "media-data"}}
              ]
            }
          }
        }
      }
    ' >"$output_file"
}
