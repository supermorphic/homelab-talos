#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

uv run --locked --no-dev python scripts/test/catalog_compatibility.py
scripts/test/validate-harness-shell-consumer-test.sh
scripts/test/validate-harness-groups-test.sh

[[ "$(yq -r '.suites[] | select(.metadata.id == "validation.repo-validate") | .native_results.strategy' tests/catalog.yaml)" == native-junit ]]

if rg -n 'bash -n.*\$|find scripts/secrets scripts/test tests/probes' \
	scripts/test/validate-chainsaw.sh; then
	echo 'Harness must not rerun canonical Bash validation.' >&2
	exit 1
fi
if rg -n 'shellcheck.*--format=json|while .*shellcheck' \
	scripts/test/validate-chainsaw.sh; then
	echo 'Harness must not rerun canonical ShellCheck validation.' >&2
	exit 1
fi
if rg -n 'qbit-manage-policy-shellcheck' \
	scripts/test/validate-chainsaw.sh tests/catalog.yaml; then
	echo 'Focused qbit ShellCheck must remain owned by repository validation.' >&2
	exit 1
fi
git ls-files -co --exclude-standard -- scripts/validate |
	rg -qx 'scripts/validate/qbit-manage-policy.sh'
