#!/usr/bin/env bash
# Attended Git-first upgrade; the Python driver owns the existing disruption Lease.
set -euo pipefail
set +x
exec uv run --locked python -m scripts.test.scenarios.openbao_ha upgrade
