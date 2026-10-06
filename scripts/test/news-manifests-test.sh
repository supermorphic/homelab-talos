#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
exec uv run --locked --no-dev python -m unittest discover -s scripts/test/news -p test_manifests.py
