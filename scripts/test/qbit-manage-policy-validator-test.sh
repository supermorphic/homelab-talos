#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

validator='scripts/validate/qbit-manage-policy.sh'
source_config='kubernetes/apps/media/qbit-manage/app/config.yml'
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-qbit-manage-policy-test.XXXXXX")"
test_config="$test_dir/config.yml"
trap 'rm -f "$test_config"; rmdir "$test_dir"' EXIT

reset_config() {
  cp "$source_config" "$test_config"
}

expect_pass() {
  local description="$1"
  "$validator" "$test_config" >/dev/null || {
    echo "$description: expected policy validation to pass." >&2
    exit 1
  }
}

expect_fail() {
  local description="$1"
  local expected_message="$2"
  local output exit_code

  set +e
  output="$("$validator" "$test_config" 2>&1)"
  exit_code="$?"
  set -e

  [[ "$exit_code" -eq 1 ]] || {
    echo "$description: expected exit 1, got $exit_code." >&2
    exit 1
  }
  rg -Fq "$expected_message" <<<"$output" || {
    echo "$description: missing expected failure message: $expected_message" >&2
    exit 1
  }
}

reset_config
expect_pass 'production policy'

reset_config
yq -i 'del(.share_limits.music)' "$test_config"
expect_fail 'music group removed' \
  'config.yml must define share_limits.music.'

reset_config
yq -i '.share_limits.music.max_ratio = 1.5' "$test_config"
expect_fail 'music ratio changed' \
  'share_limits.music.max_ratio must be 2.0.'

reset_config
yq -i '.share_limits.music.max_ratio = 2' "$test_config"
expect_pass 'music ratio serialized as an integer'

reset_config
yq -i '.share_limits.music.min_seeding_time = "1d"' "$test_config"
expect_fail 'music minimum seed time changed' \
  'share_limits.music.min_seeding_time must be 7d.'

reset_config
yq -i '.share_limits.music.max_seeding_time = "7d"' "$test_config"
expect_fail 'music maximum seed time changed' \
  'share_limits.music.max_seeding_time must be 30d.'

reset_config
yq -i '.share_limits.music.share_limit_action = "Remove"' "$test_config"
expect_fail 'music action changed' \
  'share_limits.music.share_limit_action must be Stop.'

reset_config
yq -i '.share_limits.music.cleanup = false' "$test_config"
expect_fail 'music cleanup disabled' \
  'share_limits.music.cleanup must be true.'

reset_config
yq -i '.share_limits.music.categories = ["movies"]' "$test_config"
expect_fail 'music categories changed' \
  'share_limits.music.categories must contain exactly music.'

reset_config
yq -i '.share_limits.music.exclude_any_tags = ["tracker-czteam"]' "$test_config"
expect_fail 'music missing tracker-private exclusion' \
  'share_limits.music.exclude_any_tags must include tracker-private.'

reset_config
yq -i '.share_limits.music.exclude_any_tags = ["tracker-private"]' "$test_config"
expect_fail 'music missing tracker-czteam exclusion' \
  'share_limits.music.exclude_any_tags must include tracker-czteam.'

reset_config
yq -i '.tracker."private.example".tag = "tracker-private"' "$test_config"
expect_pass 'named private tracker scalar tag'

reset_config
yq -i '.tracker."private.example".tag = ["tracker-private", "operator-reviewed"]' "$test_config"
expect_pass 'named private tracker list includes safety tag'

reset_config
yq -i '.settings.private_tag = "tracker-public"' "$test_config"
expect_fail 'private_tag net set to the wrong tag' \
  'config.yml settings.private_tag must be tracker-private (generic private-torrent safety net).'

reset_config
yq -i 'del(.settings.private_tag)' "$test_config"
expect_fail 'private_tag net removed' \
  'config.yml settings.private_tag must be tracker-private (generic private-torrent safety net).'

reset_config
yq -i '.share_limits.public.exclude_any_tags = ["tracker-private"]' "$test_config"
expect_fail 'public no longer excludes tracker-czteam' \
  'share_limits.public.exclude_any_tags must include tracker-czteam'

reset_config
yq -i '.tracker."tracker.czteam.me".tag = ["tracker-private"]' "$test_config"
expect_fail 'czteam mapping lost its tracker-czteam tag' \
  'At least one named tracker mapping must carry both tracker-private and tracker-czteam'

reset_config
yq -i '.tracker."tracker.example/passkey".tag = ["tracker-private", "tracker-czteam"]' "$test_config"
expect_fail 'tracker key carries URL/passkey syntax' \
  'keys must be bare announce hostnames'

reset_config
yq -i '.tracker."private.example".tag = "tracker-public"' "$test_config"
expect_fail 'named tracker mapped public' \
  'Every named tracker mapping must include tracker-private and exclude tracker-public.'

reset_config
yq -i '.tracker."private.example".tag = "operator-reviewed"' "$test_config"
expect_fail 'named tracker missing private safety tag' \
  'Every named tracker mapping must include tracker-private and exclude tracker-public.'

reset_config
yq -i '.tracker.other.tag = "tracker-private"' "$test_config"
expect_fail 'catch-all is exempt from named-private rule but must remain public' \
  'config.yml tracker.other.tag must be exactly tracker-public'

reset_config
yq -i '.share_limits.public.categories += ["music"]' "$test_config"
expect_fail 'extra managed category' \
  'share_limits.public.categories must contain exactly movies and tv.'

reset_config
yq -i '.share_limits.public.categories = ["movies"]' "$test_config"
expect_fail 'missing managed category' \
  'share_limits.public.categories must contain exactly movies and tv.'

reset_config
yq -i 'del(.share_limits.czteam)' "$test_config"
expect_fail 'czteam group removed' \
  'config.yml must define share_limits.czteam.'

reset_config
yq -i '.share_limits.future = {
  "priority": 5, "max_ratio": 1.0, "min_seeding_time": "1d",
  "max_seeding_time": "7d", "share_limit_action": "Stop", "cleanup": false
}' "$test_config"
expect_fail 'future finite-stop group above czteam' \
  'share_limits.czteam.priority must be the strict minimum across all groups'

reset_config
yq -i '.share_limits.future = {
  "priority": 50, "exclude_any_tags": ["tracker-private"],
  "max_ratio": 1.0, "min_seeding_time": "1d", "max_seeding_time": "7d",
  "share_limit_action": "Stop", "cleanup": true
}' "$test_config"
expect_fail 'cleanup-enabled future group missing a private exclusion' \
  'Every cleanup-enabled share_limits group must exclude tracker-private and tracker-czteam'

reset_config
yq -i '.share_limits.future = {
  "priority": 100, "max_ratio": 1.0, "min_seeding_time": "1d",
  "max_seeding_time": "7d", "share_limit_action": "Stop", "cleanup": false
}' "$test_config"
expect_fail 'future group reuses a resolution priority' \
  'share_limits priorities must be unique'

reset_config
yq -i '.share_limits.public.priority = "100"' "$test_config"
expect_fail 'share-limit priority is a YAML string instead of a number' \
  'Every share_limits priority must be a non-negative integer'

reset_config
yq -i '.share_limits.czteam.cleanup = true' "$test_config"
expect_fail 'czteam cleanup would delete a private torrent' \
  'share_limits.czteam.cleanup must be false'

reset_config
yq -i '.share_limits.czteam.share_limit_action = "Remove"' "$test_config"
expect_fail 'czteam action would remove a private torrent' \
  'share_limits.czteam.share_limit_action must be Stop'

reset_config
yq -i '.share_limits.czteam.max_seeding_time = "7d"' "$test_config"
expect_fail 'czteam finite max seed time would time-stop a below-ratio torrent' \
  'share_limits.czteam.max_seeding_time must be -1'

reset_config
yq -i '.share_limits.czteam.min_seeding_time = "1d"' "$test_config"
expect_fail 'czteam minimum seed floor too low' \
  'share_limits.czteam.min_seeding_time must be 7d'

echo 'qbit_manage policy validator tests passed.'
