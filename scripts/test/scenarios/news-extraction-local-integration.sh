#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
uv run --locked --no-dev python scripts/test/news/extraction_local.py --phase "${1:-all}"
