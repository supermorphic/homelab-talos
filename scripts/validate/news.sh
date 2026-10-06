#!/usr/bin/env bash
# Offline database/storage/bootstrap validation. FreshRSS and native acceptance are pending.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
uv run --locked --no-dev python -m unittest discover -s scripts/test/news -p 'test_*.py'
shellcheck kubernetes/apps/news/postgresql/app/scripts/init-news.sh \
	scripts/test/news-manifests-test.sh scripts/test/scenarios/news-postgresql-local-integration.sh
echo 'News database/storage/bootstrap source checks passed; FreshRSS runtime and native acceptance remain pending.'
