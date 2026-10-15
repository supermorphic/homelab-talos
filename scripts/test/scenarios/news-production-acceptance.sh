#!/usr/bin/env bash
set -euo pipefail
exec uv run --locked --no-dev python -m scripts.test.news.production_acceptance
