#!/usr/bin/env bash
# Kubernetes exec protocol only; resolve this checkout independently of caller cwd.
set -euo pipefail
set +x
[[ "$#" -eq 1 ]] || exit 2
launcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
checkout_root="$(cd -- "$launcher_dir/../.." && pwd -P)"
cd -- "$checkout_root"
exec mise exec -- uv run --locked --no-dev python -m scripts.openbao.credentials "$1"
