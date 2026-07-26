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

sl='.share_limits.public'
[[ "$(yq -r "$sl // \"none\"" "$config")" != 'none' ]] || {
  echo 'config.yml must define share_limits.public.' >&2
  exit 1
}

[[ "$(yq -r "($sl.exclude_any_tags // []) | contains([\"tracker-private\"])" "$config")" == 'true' ]] || {
  echo 'share_limits.public.exclude_any_tags must include tracker-private.' >&2
  exit 1
}

categories="$(yq -o=json -I=0 "$sl.categories | sort" "$config")"
[[ "$categories" == '["movies","tv"]' ]] || {
  echo 'share_limits.public.categories must contain exactly movies and tv.' >&2
  exit 1
}
