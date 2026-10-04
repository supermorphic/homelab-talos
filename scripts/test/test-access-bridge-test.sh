#!/usr/bin/env bash
set -euo pipefail

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/test-access-bridge.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT
mkdir "$fixture_root/bin"
real_uv="$(command -v uv)"
cat >"$fixture_root/bin/uv" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
argv=("$@")
while [[ "$#" -gt 0 && "$1" != 'scripts.test.access' ]]; do shift; done
[[ "$#" -gt 0 ]] || exec "$TEST_FIXTURE_REAL_UV" "${argv[@]}"
shift
printf '%s\n' "$*" >>"$TEST_FIXTURE_ACCESS_TRACE"
case "$1" in
  resolve) exec "$TEST_FIXTURE_REAL_UV" "${argv[@]}" ;;
  prepare)
    config="$TEST_FIXTURE_ACCESS_ROOT/private/$3/config"
    mkdir -p "$(dirname "$config")"
    printf 'synthetic invocation\n' >"$config"
    printf '%s\n' "$config"
    ;;
  validate) [[ -f "$2" && "$2" == "$TEST_FIXTURE_ACCESS_ROOT/private/"* ]] ;;
  inherit) [[ "$2" == 'verification.flux' && "$3" == "$TEST_FIXTURE_ACCESS_ROOT/private/parent/config" && -f "$3" ]] ;;
  purpose)
    case "$2" in campaign-observer|campaign-coordinator|report-publisher) ;; *) exit 2 ;; esac
    config="$TEST_FIXTURE_ACCESS_ROOT/private/$3-$2/config"
    mkdir -p "$(dirname "$config")"
    printf 'synthetic purpose invocation\n' >"$config"
    printf '%s\n' "$config"
    ;;
  purpose-check)
    [[ "${TEST_FIXTURE_PURPOSE_CHECK_FAIL:-}" != true ]] || exit 7
    [[ "$4" == "$TEST_FIXTURE_ACCESS_ROOT/private/$3-$2/config" && -f "$4" ]]
    ;;
  remove) [[ "$2" == "$TEST_FIXTURE_ACCESS_ROOT/private/"* ]] && rm -- "$2" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$fixture_root/bin/uv"
export TEST_FIXTURE_REAL_UV="$real_uv"
export TEST_FIXTURE_ACCESS_TRACE="$fixture_root/trace"
export TEST_FIXTURE_ACCESS_ROOT="$fixture_root"
export PATH="$fixture_root/bin:$PATH"

real_git="$(command -v git)"
export TEST_FIXTURE_REAL_GIT="$real_git"
cat >"$fixture_root/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == 'rev-parse --show-toplevel' ]]; then
  printf '%s\n' "$TEST_FIXTURE_ACCESS_ROOT"
else
  exec "$TEST_FIXTURE_REAL_GIT" "$@"
fi
STUB
cat >"$fixture_root/bin/mise" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'exec -- just talos readerconfig' ]] || exit 64
printf '%s\n' 'reader-bootstrap' >> "$TEST_FIXTURE_ACCESS_TRACE"
mkdir -p "$TEST_FIXTURE_ACCESS_ROOT/.talos"
printf '%s\n' 'synthetic-reader' > "$TEST_FIXTURE_ACCESS_ROOT/.talos/config"
STUB
cat >"$fixture_root/bin/talosctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "config info --talosconfig $TEST_FIXTURE_ACCESS_ROOT/.talos/config --output json" ]] || exit 64
[[ "${TEST_FIXTURE_READER_ROLE:-os:reader}" == os:reader ]] || {
  printf '%s\n' '{"roles":["os:admin"]}'
  exit
}
printf '%s\n' '{"roles":["os:reader"]}'
STUB
chmod +x "$fixture_root/bin/git" "$fixture_root/bin/mise" "$fixture_root/bin/talosctl"

# Independent purposes never replace the selected suite or borrow its config.
TEST_KUBECONFIG=/synthetic/selected-suite TEST_ACCESS_CONFIG=/synthetic/selected-suite \
  bash -e -c 'source scripts/test/lib/access.sh
    test_access_purpose_open campaign-observer purpose-run
    observer="$TEST_ACCESS_PURPOSE_CONFIG"
    test_access_purpose_open campaign-coordinator purpose-run
    coordinator="$TEST_ACCESS_PURPOSE_CONFIG"
    test_access_purpose_open report-publisher purpose-run
    publisher="$TEST_ACCESS_PURPOSE_CONFIG"
    [[ "$observer" != "$coordinator" && "$coordinator" != "$publisher" &&
       "$observer" != "$publisher" && "$TEST_KUBECONFIG" == /synthetic/selected-suite &&
       "$TEST_ACCESS_CONFIG" == /synthetic/selected-suite ]]
    test_access_purpose_check campaign-observer purpose-run "$observer"
    if test_access_purpose_check campaign-coordinator purpose-run "$observer"; then exit 1; fi
    if test_access_purpose_check report-publisher other-run "$publisher"; then exit 1; fi
    test_access_purposes_close
    [[ ! -f "$observer" && ! -f "$coordinator" && ! -f "$publisher" ]]
    test_access_purposes_close'
TEST_FIXTURE_PURPOSE_CHECK_FAIL=true \
  bash -e -c 'source scripts/test/lib/access.sh
    if test_access_purpose_open report-publisher rejected-purpose; then exit 1; fi
    [[ -z "$TEST_ACCESS_PURPOSE_CONFIG" ]]
    test_access_purposes_close
    [[ ! -f "$TEST_FIXTURE_ACCESS_ROOT/private/rejected-purpose-report-publisher/config" ]]'
: >"$fixture_root/trace"

# Null-profile execution does not read enrollment or prepare a config.
TALOSCONFIG=/synthetic/ambient-talos KUBECONFIG=/synthetic/ambient-admin TEST_KUBECONFIG=/synthetic/explicit-admin \
  bash -e -c 'source scripts/test/lib/access.sh; test_access_open validation.openbao offline-run; [[ -z "$TEST_KUBECONFIG" && "$KUBECONFIG" == /dev/null && -z "$TALOSCONFIG" ]]; test_access_close'
[[ "$(<"$fixture_root/trace")" == 'resolve validation.openbao' ]]

# The declared physical/Talos boundary remains an explicit operator workflow.
set +e
NODE_OPERATOR_KUBECONFIG='' TEST_KUBECONFIG='' \
  bash -e -c 'source scripts/test/lib/access.sh; test_access_open test.resilience.node-abrupt-loss physical-run' >/dev/null 2>&1
physical_exit="$?"
set -e
[[ "$physical_exit" -ne 0 ]]
touch "$fixture_root/operator-config"
NODE_OPERATOR_KUBECONFIG="$fixture_root/operator-config" TEST_KUBECONFIG='' \
  bash -e -c 'source scripts/test/lib/access.sh; test_access_open test.resilience.node-abrupt-loss physical-run; [[ "$TEST_KUBECONFIG" == "$NODE_OPERATOR_KUBECONFIG" && -z "$TEST_ACCESS_CONFIG" ]]; test_access_check test.resilience.node-abrupt-loss; test_access_close'
[[ -f "$fixture_root/operator-config" ]]

# A direct invocation ignores ambient KUBECONFIG and exports only its own config.
: >"$fixture_root/trace"
TALOSCONFIG=/synthetic/ambient-talos KUBECONFIG=/synthetic/ambient-admin TEST_KUBECONFIG='' TEST_ACCESS_CONFIG='' \
  bash -e -c 'source scripts/test/lib/access.sh; test_access_open verification.flux direct-run; [[ "$TEST_KUBECONFIG" == "$TEST_FIXTURE_ACCESS_ROOT/private/direct-run/config" && "$KUBECONFIG" == "$TEST_KUBECONFIG" && "$TEST_ACCESS_CONFIG" == "$TEST_KUBECONFIG" && "$TALOSCONFIG" == "$TEST_FIXTURE_ACCESS_ROOT/.talos/config" ]]; test_access_arguments true @test-kubeconfig@; [[ "${TEST_ACCESS_ARGUMENTS[1]}" == "$TEST_KUBECONFIG" ]]; test_access_close'
[[ ! -f "$fixture_root/private/direct-run/config" ]]
[[ "$(tail -n 1 "$fixture_root/trace")" == "remove $fixture_root/private/direct-run/config" ]]

# A substituted admin role is rejected and the newly prepared config is removed.
TEST_FIXTURE_READER_ROLE=os:admin TEST_ACCESS_CONFIG='' TEST_KUBECONFIG=''   bash -e -c 'source scripts/test/lib/access.sh
    if test_access_open verification.flux bad-reader; then exit 1; fi
    [[ ! -f "$TEST_FIXTURE_ACCESS_ROOT/private/bad-reader/config" ]]' >/dev/null 2>&1
# No reader workflow or ambient Talos credential reaches an undeclared backend.
TALOSCONFIG=/synthetic/ambient-talos TEST_ACCESS_CONFIG='' TEST_KUBECONFIG=''   bash -e -c 'source scripts/test/lib/access.sh
    test_access_open verification.metrics-server no-reader
    [[ -z "$TALOSCONFIG" ]]
    test_access_close'

# Explicit unbound config and fixture catalog fail before preparing credentials.
for variant in explicit fixture; do
  : >"$fixture_root/trace"
  set +e
  if [[ "$variant" == explicit ]]; then
    TEST_KUBECONFIG=/synthetic/explicit-admin TEST_ACCESS_CONFIG='' \
      bash -e -c 'source scripts/test/lib/access.sh; test_access_open verification.flux refused' >/dev/null 2>&1
  else
    TEST_CATALOG_PATH=/synthetic/fixture-catalog TEST_KUBECONFIG='' TEST_ACCESS_CONFIG='' \
      bash -e -c 'source scripts/test/lib/access.sh; test_access_open verification.flux refused' >/dev/null 2>&1
  fi
  exit_code="$?"
  set -e
  [[ "$exit_code" -ne 0 ]]
  if rg -q 'prepare|validate|inherit|remove' "$fixture_root/trace"; then exit 1; fi
done

# Only a validated parent may be inherited, and a child cannot remove it.
mkdir -p "$fixture_root/private/parent"
printf 'synthetic parent\n' >"$fixture_root/private/parent/config"
TEST_ACCESS_CONFIG="$fixture_root/private/parent/config" \
TEST_KUBECONFIG="$fixture_root/private/parent/config" \
  bash -e -c 'source scripts/test/lib/access.sh; test_access_open verification.flux child-run; test_access_close'
[[ -f "$fixture_root/private/parent/config" ]]
set +e
TEST_ACCESS_CONFIG="$fixture_root/private/parent/config" TEST_KUBECONFIG='' \
  bash -e -c 'source scripts/test/lib/access.sh; test_access_open test.flux-restart wrong-child' >/dev/null 2>&1
exit_code="$?"
set -e
[[ "$exit_code" -ne 0 ]]

# Static credential paths and manual context switches never reach a backend.
for argument in .kube/config --context=diagnostic use-context --kubeconfig=/synthetic/admin; do
  set +e
  TEST_KUBECONFIG="$fixture_root/private/parent/config" \
    bash -e -c 'source scripts/test/lib/access.sh; test_access_arguments true "$1"' _ "$argument" >/dev/null 2>&1
  exit_code="$?"
  set -e
  [[ "$exit_code" -ne 0 ]]
done
printf 'Test credential shell bridge checks passed.\n'
