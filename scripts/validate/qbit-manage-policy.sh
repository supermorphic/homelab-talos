#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
  echo 'Usage: qbit-manage-policy.sh <config.yml>' >&2
  exit 2
}

config="$1"
[[ -f "$config" ]] || {
  echo "Missing qbit_manage policy config: $config" >&2
  exit 1
}

# The category-based model has one public catch-all. Normalize scalar/list tag values so
# future private tracker entries can carry an additional operator tag without weakening the
# tracker-private exclusion.
# The dollar-prefixed names below are yq variables, not shell expansions.
# shellcheck disable=SC2016
other_tags="$(yq -o=json -I=0 '
  (.tracker.other.tag // null) as $tag
  | [$tag]
  | flatten
  | sort
' "$config")"
[[ "$other_tags" == '["tracker-public"]' ]] || {
  echo 'config.yml tracker.other.tag must be exactly tracker-public (category-based catch-all).' >&2
  exit 1
}

# shellcheck disable=SC2016
invalid_named_trackers="$(yq -r '
  .tracker
  | to_entries[]
  | select(.key != "other")
  | .value.tag as $tag
  | ([$tag] | flatten) as $tags
  | select(
      (($tags | contains(["tracker-private"])) | not)
      or ($tags | contains(["tracker-public"]))
    )
  | .key
' "$config")"
[[ -z "$invalid_named_trackers" ]] || {
  echo 'Every named tracker mapping must include tracker-private and exclude tracker-public.' >&2
  printf 'Invalid tracker keys:\n%s\n' "$invalid_named_trackers" >&2
  exit 1
}

# Tracker keys are bare announce HOSTNAMES (optionally pipe-delimited), never URLs — a key must
# not carry a scheme, path, query, or passkey, so a passkey-bearing announce URL can never be
# committed here. The offending key is deliberately NOT printed: it could contain the secret.
if yq -r '.tracker | keys | .[]' "$config" | rg -q '[/:?=]|\s'; then
  echo 'A tracker key contains URL/scheme/path/query/passkey syntax; keys must be bare announce hostnames. (Offending key not shown — it may contain a secret.)' >&2
  exit 1
fi

# CZTeam classification must be present: at least one named tracker mapping carries BOTH
# tracker-private and tracker-czteam. tracker-czteam selects the dedicated CZTeam share-limit
# group; pairing it with tracker-private keeps CZTeam protected even before that group exists.
# shellcheck disable=SC2016
czteam_mapping="$(yq -r '
  .tracker
  | to_entries[]
  | select(.key != "other")
  | ([.value.tag] | flatten) as $tags
  | select(($tags | contains(["tracker-private"])) and ($tags | contains(["tracker-czteam"])))
  | .key
' "$config")"
[[ -n "$czteam_mapping" ]] || {
  echo 'At least one named tracker mapping must carry both tracker-private and tracker-czteam (CZTeam classification).' >&2
  exit 1
}

# Generic private-torrent safety net: settings.private_tag auto-tags EVERY private torrent
# tracker-private, which both public share-limit groups (music and public) exclude. This
# host-independent layer keeps any private torrent (even from a tracker not named above) out of
# the public music and tv/movie policies, so it must stay set while both groups exclude
# tracker-private.
[[ "$(yq -r '.settings.private_tag // "none"' "$config")" == 'tracker-private' ]] || {
  echo 'config.yml settings.private_tag must be tracker-private (generic private-torrent safety net).' >&2
  exit 1
}

assert_share_limit_group() {
  local name="$1" expected_ratio="$2" expected_min="$3"
  local expected_max="$4" expected_action="$5" expected_cleanup="$6"
  local group=".share_limits.$name" actual_ratio

  [[ "$(yq -r "$group // \"none\"" "$config")" != 'none' ]] || {
    echo "config.yml must define share_limits.$name." >&2
    exit 1
  }
  actual_ratio="$(yq -r "$group.max_ratio" "$config")"
  [[ "$actual_ratio" == "$expected_ratio" || \
    ( "$expected_ratio" == *.0 && "$actual_ratio" == "${expected_ratio%.0}" ) ]] || {
    echo "share_limits.$name.max_ratio must be $expected_ratio." >&2
    exit 1
  }
  [[ "$(yq -r "$group.min_seeding_time" "$config")" == "$expected_min" ]] || {
    echo "share_limits.$name.min_seeding_time must be $expected_min." >&2
    exit 1
  }
  [[ "$(yq -r "$group.max_seeding_time" "$config")" == "$expected_max" ]] || {
    echo "share_limits.$name.max_seeding_time must be $expected_max." >&2
    exit 1
  }
  [[ "$(yq -r "$group.share_limit_action" "$config")" == "$expected_action" ]] || {
    echo "share_limits.$name.share_limit_action must be $expected_action." >&2
    exit 1
  }
  [[ "$(yq -r "$group.cleanup" "$config")" == "$expected_cleanup" ]] || {
    echo "share_limits.$name.cleanup must be $expected_cleanup." >&2
    exit 1
  }
}

assert_share_limit_group public 1.5 1d 7d Stop true
assert_share_limit_group music 2.0 7d 30d Stop true
music='.share_limits.music'
[[ "$(yq -r "$music.priority" "$config")" == '50' ]] || {
  echo 'share_limits.music.priority must be 50.' >&2
  exit 1
}
music_categories="$(yq -o=json -I=0 "$music.categories | sort" "$config")"
[[ "$music_categories" == '["music"]' ]] || {
  echo 'share_limits.music.categories must contain exactly music.' >&2
  exit 1
}
for private_tag in tracker-private tracker-czteam; do
  [[ "$(yq -r "($music.exclude_any_tags // []) | contains([\"$private_tag\"])" "$config")" == 'true' ]] || {
    echo "share_limits.music.exclude_any_tags must include $private_tag." >&2
    exit 1
  }
done
assert_share_limit_group czteam 2.0 7d -1 Stop false

sl='.share_limits.public'

[[ "$(yq -r "($sl.exclude_any_tags // []) | contains([\"tracker-private\"])" "$config")" == 'true' ]] || {
  echo 'share_limits.public.exclude_any_tags must include tracker-private.' >&2
  exit 1
}

[[ "$(yq -r "($sl.exclude_any_tags // []) | contains([\"tracker-czteam\"])" "$config")" == 'true' ]] || {
  echo 'share_limits.public.exclude_any_tags must include tracker-czteam (defense in depth for CZTeam).' >&2
  exit 1
}

categories="$(yq -o=json -I=0 "$sl.categories | sort" "$config")"
[[ "$categories" == '["movies","tv"]' ]] || {
  echo 'share_limits.public.categories must contain exactly movies and tv.' >&2
  exit 1
}

# CZTeam dedicated share-limit group — the private seeding policy. Assert its safety-critical
# shape so a later edit can't silently weaken it into a hit-and-run or a delete.
cz='.share_limits.czteam'
# Selected by tracker-czteam.
[[ "$(yq -r "($cz.include_all_tags // []) | contains([\"tracker-czteam\"])" "$config")" == 'true' ]] || {
  echo 'share_limits.czteam.include_all_tags must include tracker-czteam.' >&2
  exit 1
}

invalid_priorities=''
while IFS='|' read -r group priority priority_type; do
  if [[ "$priority_type" != '!!int' || ! "$priority" =~ ^[0-9]+$ ]]; then
    invalid_priorities+="${invalid_priorities:+,}$group"
  fi
done < <(yq -r '.share_limits | to_entries[] | [.key, .value.priority, (.value.priority | type)] | join("|")' "$config")
[[ -z "$invalid_priorities" ]] || {
  echo 'Every share_limits priority must be a non-negative integer.' >&2
  exit 1
}

# shellcheck disable=SC2016
unsafe_precedence="$(yq -r '
  .share_limits.czteam.priority as $cz
  | .share_limits
  | to_entries[]
  | select(.key != "czteam")
  | select(.value.priority <= $cz)
  | .key
' "$config")"
[[ -z "$unsafe_precedence" ]] || {
  echo 'share_limits.czteam.priority must be the strict minimum across all groups.' >&2
  exit 1
}

# shellcheck disable=SC2016
unsafe_cleanup="$(yq -r '
  .share_limits
  | to_entries[]
  | select(.value.cleanup == true)
  | select(
      ((.value.exclude_any_tags // []) | contains(["tracker-private"])) == false
      or ((.value.exclude_any_tags // []) | contains(["tracker-czteam"])) == false
    )
  | .key
' "$config")"
[[ -z "$unsafe_cleanup" ]] || {
  echo 'Every cleanup-enabled share_limits group must exclude tracker-private and tracker-czteam.' >&2
  exit 1
}

priority_count="$(yq -r '.share_limits | length' "$config")"
unique_priority_count="$(yq -r '[.share_limits[].priority] | unique | length' "$config")"
[[ "$priority_count" == "$unique_priority_count" ]] || {
  echo 'share_limits priorities must be unique.' >&2
  exit 1
}
