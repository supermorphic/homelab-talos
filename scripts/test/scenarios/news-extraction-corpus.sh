#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
uv run --locked --no-dev python -m scripts.test.news.extraction_corpus "${1:-replay}"
