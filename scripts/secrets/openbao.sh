#!/usr/bin/env bash
# Operator-only writer: validate the selected identity using the existing workflow.
set -euo pipefail
set +x
umask 077
just repo secrets >/dev/null
exec uv run --locked python -m scripts.openbao.secrets
