#!/usr/bin/env bash
set -euo pipefail

exec uv run --locked --no-dev python scripts/test/catalog_compatibility.py
