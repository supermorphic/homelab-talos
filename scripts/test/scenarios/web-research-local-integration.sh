#!/usr/bin/env bash
# Disposable local acceptance for the production web-research runtime and policies.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"
exec uv run --locked python scripts/test/web_research/local_integration.py
