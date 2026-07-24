#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

# Keep this validation contract cluster-independent even on an operator workstation.
export KUBECONFIG="$repo_root/tests/.offline-validation-no-kubeconfig"
unset SOPS_AGE_KEY SOPS_AGE_KEY_FILE

chainsaw lint configuration --file tests/config/chainsaw.yaml
conftest test --all-namespaces \
  --policy tests/policy/chainsaw \
  tests/config/chainsaw.yaml tests/chainsaw/smoke

test_count=0
while IFS= read -r test_file; do
  chainsaw lint test --file "$test_file"
  test_count=$((test_count + 1))
done < <(
  find tests/chainsaw tests/fixtures/chainsaw -type f \
    \( -name 'chainsaw-test.yaml' -o -name 'chainsaw-test.yml' \) \
    -print | LC_ALL=C sort
)

yaml_count=0
while IFS= read -r yaml_file; do
  yq eval-all 'true' "$yaml_file" >/dev/null
  yaml_count=$((yaml_count + 1))
done < <(
  find tests/chainsaw tests/fixtures/chainsaw -type f \
    \( -name '*.yaml' -o -name '*.yml' \) \
    -print | LC_ALL=C sort
)

script_count=0
while IFS= read -r script_file; do
  shellcheck --external-sources "$script_file"
  script_count=$((script_count + 1))
done < <(find scripts/test -type f -name '*.sh' -print | LC_ALL=C sort)

scripts/test/safety/require-chaos-confirmation-test.sh
scripts/test/lib/results-test.sh

printf 'Chainsaw offline validation passed: configurations=1 tests=%d yaml_files=%d shell_scripts=%d.\n' \
  "$test_count" "$yaml_count" "$script_count"
