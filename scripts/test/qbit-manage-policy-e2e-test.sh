#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/test/lib/qbit-manage-policy-e2e.sh
source scripts/test/lib/qbit-manage-policy-e2e.sh

test_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-qbm-policy-e2e-test.XXXXXX")"
cleanup() {
  rm -f \
    "$test_root/policy-false.yml" "$test_root/policy-true.yml" \
    "$test_root/negative.yml" "$test_root/job.yml"
  rmdir "$test_root"
}
trap cleanup EXIT

run_id='abc12345def67890'
source_config='kubernetes/apps/media/qbit-manage/app/config.yml'

validate_qbm_e2e_run_id "$run_id"
for invalid_id in '' short 'ABC12345' 'abc_12345' 'abc/12345' 'abc1234567890123456789012x'; do
  if validate_qbm_e2e_run_id "$invalid_id"; then
    echo "Accepted unsafe run ID: $invalid_id" >&2
    exit 1
  fi
done

for safe_path in \
  "/data/downloads/.e2e-qbit-manage-${run_id}" \
  "/data/downloads/.e2e-qbit-manage-${run_id}/payload" \
  "/data/media/.e2e-qbit-manage-${run_id}/payload" \
  "/data/downloads/.RecycleBin/e2e-qbm-${run_id}"; do
  validate_qbm_e2e_owned_path "$run_id" "$safe_path" || {
    echo "Rejected run-owned path: $safe_path" >&2
    exit 1
  }
done
for unsafe_path in \
  '' / /data/downloads /data/media \
  "/data/downloads/.e2e-qbit-manage-other" \
  "/data/downloads/.e2e-qbit-manage-${run_id}/../other" \
  "/data/downloads/.RecycleBin/unrelated"; do
  if validate_qbm_e2e_owned_path "$run_id" "$unsafe_path"; then
    echo "Accepted unsafe or unowned path: $unsafe_path" >&2
    exit 1
  fi
done

validate_qbm_e2e_relative_payload 'e2e-qbm/file.mp4'
for unsafe_payload in '' /absolute ../escape path/../escape path/..; do
  if validate_qbm_e2e_relative_payload "$unsafe_payload"; then
    echo "Accepted unsafe payload path: $unsafe_payload" >&2
    exit 1
  fi
done

qbm_e2e_refuse_preexisting_fixture '[]'
if qbm_e2e_refuse_preexisting_fixture \
  '[{"hash":"08ada5a7a6183aae1e09d831df6748d566095a10"}]' >/dev/null 2>&1; then
  echo 'Accepted a pre-existing fixed fixture.' >&2
  exit 1
fi

generate_qbm_e2e_policy_config "$source_config" "$test_root/policy-false.yml" "$run_id" false
validate_qbm_e2e_policy_config "$test_root/policy-false.yml" "$run_id" false
generate_qbm_e2e_policy_config "$source_config" "$test_root/policy-true.yml" "$run_id" true
validate_qbm_e2e_policy_config "$test_root/policy-true.yml" "$run_id" true

expect_invalid_config() {
  local expression="$1"
  cp "$test_root/policy-false.yml" "$test_root/negative.yml"
  EXPRESSION_VALUE='unsafe' yq -i "$expression" "$test_root/negative.yml"
  if validate_qbm_e2e_policy_config "$test_root/negative.yml" "$run_id" false \
    >/dev/null 2>&1; then
    echo "Unsafe generated policy passed validation: $expression" >&2
    exit 1
  fi
}

expect_invalid_config '.commands.tag_update = true'
expect_invalid_config '.commands.rem_orphaned = true'
expect_invalid_config '.commands.extra = false'
expect_invalid_config '.settings.disable_qbt_default_share_limits = true'
expect_invalid_config '.settings.share_limits_tag = "~shared"'
expect_invalid_config '.share_limits.e2e_qbm_abc12345def67890.categories = ["movies"]'
expect_invalid_config '.share_limits.e2e_qbm_abc12345def67890.include_all_tags = []'
expect_invalid_config '.share_limits.e2e_qbm_abc12345def67890.exclude_any_tags = []'
expect_invalid_config '.share_limits.e2e_qbm_abc12345def67890.cleanup = true'
expect_invalid_config '.share_limits.unrelated = {"priority": 2}'

generate_qbm_e2e_job_manifest \
  "$test_root/job.yml" "$run_id" limits \
  ghcr.io/stuffanthings/qbit_manage:v4.10.0 "qbm-e2e-${run_id}-limits"
yq -e '
  .kind == "Job" and
  .metadata.namespace == "media" and
  .metadata.labels."homelab-talos/e2e-run" == "abc12345def67890" and
  .spec.backoffLimit == 0 and
  .spec.activeDeadlineSeconds == 120 and
  .spec.template.spec.automountServiceAccountToken == false and
  .spec.template.spec.securityContext.runAsUser == 568
' "$test_root/job.yml" >/dev/null
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "app") | .image' \
  "$test_root/job.yml")" == 'ghcr.io/stuffanthings/qbit_manage:v4.10.0' ]]
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "app") |
  .args | join(" ")' "$test_root/job.yml")" == 'python3 qbit_manage.py --run' ]]
[[ "$(yq -r '.spec.template.spec.containers[] | select(.name == "app") |
  .envFrom[0].secretRef.name' "$test_root/job.yml")" == 'qbit-manage-secret' ]]
[[ "$(yq -r '[.spec.template.spec.containers[] | select(.name == "app") |
  .volumeMounts[] | select(.mountPath == "/data/downloads")] | length' \
  "$test_root/job.yml")" -eq 1 ]]
[[ "$(yq -r '[.spec.template.spec.containers[] | select(.name == "app") |
  .volumeMounts[] | select(.mountPath == "/data/media")] | length' \
  "$test_root/job.yml")" -eq 0 ]]
[[ "$(yq -r '[.spec.template.spec.volumes[] |
  select(.persistentVolumeClaim.claimName == "media-data")] | length' \
  "$test_root/job.yml")" -eq 1 ]]
if rg -q 'QBT_(SHARE_LIMITS|TAG_UPDATE|REM_|DRY_RUN)' "$test_root/job.yml"; then
  echo 'Generated Job introduced a second command-authority surface via environment.' >&2
  exit 1
fi

api_helper='scripts/test/helpers/qbit-manage-policy-api.sh'
rg -Fq -- '--cookie-jar "$cookie_file"' "$api_helper"
rg -Fq -- '--cookie "$cookie_file"' "$api_helper"
rg -Fq 'api_get /api/v2/torrents/categories' "$api_helper"
rg -Fq 'api_get /api/v2/torrents/tags' "$api_helper"
if rg -n 'set -x|printenv|envFrom.*value|echo.*QBT_(USER|PASS)|printf.*QBT_(USER|PASS)' \
  "$api_helper"; then
  echo 'API helper contains a credential-exposure primitive.' >&2
  exit 1
fi

orchestrator='scripts/test/scenarios/qbit-manage-policy.sh'
rg -Fq 'trap cleanup EXIT' "$orchestrator"
rg -Fq 'validate_qbm_e2e_owned_path' "$orchestrator"
rg -Fq 'qbm_e2e_refuse_preexisting_fixture' "$orchestrator"
rg -Fq "api categories" "$orchestrator"
rg -Fq "api tags" "$orchestrator"
rg -Fq "run-named qBittorrent category already exists" "$orchestrator"
rg -Fq "run-named qBittorrent tag already exists" "$orchestrator"
rg -Fq 'run_policy_job cleanup2 true' "$orchestrator"
if rg -n 'kubectl.*logs|k logs|podLogs' "$orchestrator"; then
  echo 'Orchestrator must not collect application logs.' >&2
  exit 1
fi

echo 'qbit_manage policy E2E offline tests passed.'
