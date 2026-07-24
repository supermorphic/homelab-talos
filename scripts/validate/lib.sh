#!/usr/bin/env bash

# Offline source/render assertion helpers. These functions intentionally know
# nothing about a live cluster; live state belongs in Chainsaw scenarios.

validation_error() {
  local message="$1"
  shift
  printf 'ERROR: %s\n' "$message" >&2
  while (( $# >= 2 )); do
    printf '  %s: %s\n' "$1" "$2" >&2
    shift 2
  done
}

require_value() {
  local value="$1"
  local description="${2:-value}"
  if [[ -z "$value" || "$value" == 'null' ]]; then
    validation_error 'Required value is missing' \
      'description' "$description" \
      'actual' "${value:-<empty>}"
    return 1
  fi
}

assert_file() {
  local file="$1"
  local description="${2:-required file}"
  if [[ ! -f "$file" ]]; then
    validation_error 'Required file is missing' \
      'description' "$description" \
      'file' "$file"
    return 1
  fi
}

assert_wired() {
  local expected_line="$1"
  local parent_file="$2"
  if ! rg -Fxq -- "$expected_line" "$parent_file"; then
    validation_error 'Kustomization entry is missing' \
      'file' "$parent_file" \
      'expected line' "$expected_line"
    return 1
  fi
}

assert_yaml_eq() {
  local file="$1"
  local query="$2"
  local expected="$3"
  local description="${4:-YAML value}"
  local actual

  if ! actual="$(yq -r "$query" "$file")"; then
    validation_error 'Could not evaluate YAML query' \
      'description' "$description" \
      'file' "$file" \
      'query' "$query"
    return 1
  fi
  if [[ "$actual" != "$expected" ]]; then
    validation_error 'YAML value mismatch' \
      'description' "$description" \
      'file' "$file" \
      'query' "$query" \
      'expected' "$expected" \
      'actual' "${actual:-<empty>}"
    return 1
  fi
}

assert_yaml_values() {
  local file="$1"
  shift

  if (( $# == 0 || $# % 2 != 0 )); then
    validation_error 'assert_yaml_values requires query/expected pairs' \
      'file' "$file" \
      'argument count' "$#"
    return 2
  fi

  while (( $# )); do
    assert_yaml_eq "$file" "$1" "$2" || return 1
    shift 2
  done
}

assert_yaml() {
  local file="$1"
  local expression="$2"
  local description="${3:-YAML assertion}"

  if ! yq -e "$expression" "$file" >/dev/null; then
    validation_error 'YAML assertion failed' \
      'description' "$description" \
      'file' "$file" \
      'expression' "$expression"
    return 1
  fi
}

assert_yaml_set() {
  local file="$1"
  local query="$2"
  local description="${3:-YAML value}"
  local actual

  if ! actual="$(yq -r "$query" "$file")"; then
    validation_error 'Could not evaluate YAML query' \
      'description' "$description" \
      'file' "$file" \
      'query' "$query"
    return 1
  fi
  require_value "$actual" "$description" || {
    printf '  file: %s\n  query: %s\n' "$file" "$query" >&2
    return 1
  }
}

assert_pinned_value() {
  local value="$1"
  local description="${2:-version or image tag}"

  require_value "$value" "$description" || return 1
  case "${value,,}" in
    latest|main|master|stable|nightly)
      validation_error 'Mutable version or image tag is forbidden' \
        'description' "$description" \
        'actual' "$value"
      return 1
      ;;
  esac
}

assert_pinned_tag() {
  local file="$1"
  local query="$2"
  local description="${3:-image tag}"
  local tag

  if ! tag="$(yq -r "$query" "$file")"; then
    validation_error 'Could not evaluate image tag query' \
      'description' "$description" \
      'file' "$file" \
      'query' "$query"
    return 1
  fi
  assert_pinned_value "$tag" "$description" || {
    printf '  file: %s\n  query: %s\n' "$file" "$query" >&2
    return 1
  }
}

assert_depends_on() {
  local file="$1"
  shift
  local dependency

  for dependency in "$@"; do
    if ! EXPECTED_DEPENDENCY="$dependency" \
      yq -e '[.spec.dependsOn[]?.name] | contains([strenv(EXPECTED_DEPENDENCY)])' \
      "$file" >/dev/null; then
      validation_error 'Required Flux dependency is missing' \
        'file' "$file" \
        'dependency' "$dependency"
      return 1
    fi
  done
}
