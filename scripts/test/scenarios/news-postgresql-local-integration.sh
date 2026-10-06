#!/usr/bin/env bash
# Database-only acceptance; this does not admit FreshRSS or the licensed extractor.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
exec uv run --locked --no-dev python scripts/test/news/postgresql_integration.py
