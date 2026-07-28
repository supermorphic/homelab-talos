#!/usr/bin/env bash
set -euo pipefail

validator='scripts/test/validate-catalog.sh'
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-talos-catalog-test.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT

"$validator" tests/catalog.yaml >/dev/null

expect_rejection() {
  local description="$1" fixture="$2"
  if "$validator" "$fixture" >/dev/null 2>&1; then
    echo "Catalog validator accepted invalid fixture: $description" >&2
    exit 1
  fi
}

cp tests/catalog.yaml "$temp_dir/duplicate.yaml"
yq -i '.suites += [.suites[0]]' "$temp_dir/duplicate.yaml"
expect_rejection 'duplicate suite id and dispatch tuple' "$temp_dir/duplicate.yaml"

cp tests/catalog.yaml "$temp_dir/unsafe-path.yaml"
yq -i '(.suites[] | select(.metadata.id == "chainsaw.smoke.cluster.default") | .dispatch.path) = "../outside"' \
  "$temp_dir/unsafe-path.yaml"
expect_rejection 'unsafe dispatch path' "$temp_dir/unsafe-path.yaml"

cp tests/catalog.yaml "$temp_dir/direct-runtime.yaml"
yq -i '(.suites[] | select(.metadata.id == "test.integration.media-hardlink") |
  .dispatch.runtime) = "shell-string"' "$temp_dir/direct-runtime.yaml"
expect_rejection 'untyped direct runtime' "$temp_dir/direct-runtime.yaml"

cp tests/catalog.yaml "$temp_dir/direct-args.yaml"
yq -i '(.suites[] | select(.metadata.id == "test.integration.media-hardlink") |
  .dispatch.args) = ".kube/config --unsafe"' "$temp_dir/direct-args.yaml"
expect_rejection 'direct shell string instead of argument vector' "$temp_dir/direct-args.yaml"

cp tests/catalog.yaml "$temp_dir/unguarded-mutation.yaml"
yq -i '(.suites[] | select(.metadata.id == "test.cilium-connectivity") | .confirmation) = {
  "type": "none", "variable": null, "expected": null
}' "$temp_dir/unguarded-mutation.yaml"
expect_rejection 'mutation without confirmation classification' "$temp_dir/unguarded-mutation.yaml"

cp tests/catalog.yaml "$temp_dir/unsafe-runner-command.yaml"
yq -i '(.suites[] | select(.metadata.id == "verification.metrics-server") |
  .runner.command) = "mise exec -- just kube metrics-server-verify; touch /tmp/unsafe"' \
  "$temp_dir/unsafe-runner-command.yaml"
expect_rejection 'shell operators in catalog runner command' \
  "$temp_dir/unsafe-runner-command.yaml"

cp tests/catalog.yaml "$temp_dir/missing-ci-command.yaml"
yq -i 'del(.suites[] | select(.metadata.id == "validation.trivy"))' \
  "$temp_dir/missing-ci-command.yaml"
expect_rejection 'just ci child without a catalog suite' "$temp_dir/missing-ci-command.yaml"

cp tests/catalog.yaml "$temp_dir/unknown-campaign-member.yaml"
yq -i '.campaigns.e2e.members += ["test.e2e.not-registered"]' \
  "$temp_dir/unknown-campaign-member.yaml"
expect_rejection 'unknown campaign member' "$temp_dir/unknown-campaign-member.yaml"

cp tests/catalog.yaml "$temp_dir/campaign-cycle.yaml"
yq -i '.campaigns.standard.includes += ["full"]' "$temp_dir/campaign-cycle.yaml"
expect_rejection 'campaign include cycle' "$temp_dir/campaign-cycle.yaml"

cp tests/catalog.yaml "$temp_dir/missing-tier-member.yaml"
yq -i '.campaigns.verification.members = .campaigns.verification.members[:-1]' \
  "$temp_dir/missing-tier-member.yaml"
expect_rejection 'catalog suite omitted from explicit campaign' \
  "$temp_dir/missing-tier-member.yaml"

cp tests/catalog.yaml "$temp_dir/duplicate-campaign-member.yaml"
yq -i '.campaigns.e2e.members += [.campaigns.e2e.members[0]]' \
  "$temp_dir/duplicate-campaign-member.yaml"
expect_rejection 'duplicate resolved campaign member' \
  "$temp_dir/duplicate-campaign-member.yaml"

echo 'Test catalog negative fixtures passed.'
