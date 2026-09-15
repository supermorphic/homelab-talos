#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 1 ]] || {
	echo 'Usage: web-research-live-contract.sh <kubeconfig>' >&2
	exit 2
}

uv run --locked python scripts/test/web_research/live_contract.py "$1"
