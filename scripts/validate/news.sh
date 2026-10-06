#!/usr/bin/env bash
# Offline database/application/storage/bootstrap validation; native acceptance is separate.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
uv run --locked --no-dev python -m unittest discover -s scripts/test/news -p 'test_*.py'
shellcheck kubernetes/apps/news/postgresql/app/scripts/init-news.sh \
	kubernetes/apps/news/freshrss/app/scripts/*.sh \
	scripts/test/news-manifests-test.sh scripts/test/scenarios/news*-local-integration.sh
shellcheck -x scripts/verify/news.sh
scripts/validate/alerts.sh news
echo 'News source checks passed; runtime integration and native acceptance are separate gates.'
