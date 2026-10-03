#!/usr/bin/env bash
# Offline unit test for the run-probe.sh allowlist: unknown/missing targets must be
# rejected with exit 2 before any cluster access.
set -euo pipefail

runner='scripts/test/run-probe.sh'

expect_dispatch_rejection() {
  local description="$1"
  shift
  local exit_code

  set +e
  "$runner" "$@" >/dev/null 2>&1
  exit_code="$?"
  set -e

  [[ "$exit_code" -eq 2 ]] || {
    echo "${description}: expected dispatch exit 2, got ${exit_code}." >&2
    exit 1
  }
}

expect_dispatch_rejection 'unknown probe target is rejected' bogus
expect_dispatch_rejection 'path traversal is not a target' ../../../scripts/foo
expect_dispatch_rejection 'probe requires an explicit target'
expect_dispatch_rejection 'probe rejects extra arguments' qbittorrent extra

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/probe-dispatch-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
git -C "$fixture_root" init --quiet
mkdir -p "$fixture_root/scripts/test" "$fixture_root/scripts/lib"
cp "$runner" "$fixture_root/scripts/test/run-probe.sh"
cp scripts/lib/common.sh "$fixture_root/scripts/lib/common.sh"
cat >"$fixture_root/scripts/test/run-catalog-suite.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"${DISPATCH_TEST_CALLS:?}"
EOF
chmod +x "$fixture_root/scripts/test/run-catalog-suite.sh"
# Each public probe must reach the coordinator without a legacy config file.
for target in qbittorrent vpn-leak dns-isolation; do
  (
    cd "$fixture_root"
    DISPATCH_TEST_CALLS="$fixture_root/calls" scripts/test/run-probe.sh "$target"
  )
  rg -q '^probe\.[a-z-]+ -- tests/probes/.+ @test-kubeconfig@$' "$fixture_root/calls"
done

echo 'run-probe dispatch tests passed.'
