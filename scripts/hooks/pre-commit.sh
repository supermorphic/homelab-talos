#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
hook_dir="$(cd "$(dirname "$0")" && pwd -P)"

cd "$repo_root"
exec mise exec -- pre-commit hook-impl \
  --config="$repo_root/.pre-commit-config.yaml" \
  --hook-type=pre-commit \
  --hook-dir="$hook_dir" \
  -- "$@"
