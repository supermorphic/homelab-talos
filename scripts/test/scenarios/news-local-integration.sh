#!/usr/bin/env bash
# Actual FreshRSS/PostgreSQL acceptance; no cluster access or extraction service.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
exec uv run --locked --no-dev python scripts/test/news/freshrss_integration.py
