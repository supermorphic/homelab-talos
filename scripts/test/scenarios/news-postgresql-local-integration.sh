#!/usr/bin/env bash
# Database-only acceptance; application acceptance uses news-local-integration.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
exec uv run --locked --no-dev python scripts/test/news/postgresql_integration.py
