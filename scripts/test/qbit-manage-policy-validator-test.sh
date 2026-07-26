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

echo 'qbit_manage policy validator tests passed.'
