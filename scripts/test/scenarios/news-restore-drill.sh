#!/usr/bin/env bash
# Synthetic paired recovery, using only the registered suite-bound test profile.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
exec uv run --locked --no-dev python -m scripts.test.news.cluster_recovery "$@"
