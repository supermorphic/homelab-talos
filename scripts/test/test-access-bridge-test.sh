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
  remove) [[ "$2" == "$TEST_FIXTURE_ACCESS_ROOT/private/"* ]] && rm -- "$2" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$fixture_root/bin/uv"
export TEST_FIXTURE_REAL_UV="$real_uv"
export TEST_FIXTURE_ACCESS_TRACE="$fixture_root/trace"
export TEST_FIXTURE_ACCESS_ROOT="$fixture_root"
export PATH="$fixture_root/bin:$PATH"

# Null-profile execution does not read enrollment or prepare a config.
KUBECONFIG=/synthetic/ambient-admin TEST_KUBECONFIG=/synthetic/explicit-admin \
  bash -e -c 'source scripts/test/lib/access.sh; test_access_open validation.openbao offline-run; [[ -z "$TEST_KUBECONFIG" && "$KUBECONFIG" == /dev/null ]]; test_access_close'
[[ "$(<"$fixture_root/trace")" == 'resolve validation.openbao' ]]

# A direct invocation ignores ambient KUBECONFIG and exports only its own config.
: >"$fixture_root/trace"
KUBECONFIG=/synthetic/ambient-admin TEST_KUBECONFIG='' TEST_ACCESS_CONFIG='' \
  bash -e -c 'source scripts/test/lib/access.sh; test_access_open verification.flux direct-run; [[ "$TEST_KUBECONFIG" == "$TEST_FIXTURE_ACCESS_ROOT/private/direct-run/config" && "$KUBECONFIG" == "$TEST_KUBECONFIG" && "$TEST_ACCESS_CONFIG" == "$TEST_KUBECONFIG" ]]; test_access_arguments true @test-kubeconfig@; [[ "${TEST_ACCESS_ARGUMENTS[1]}" == "$TEST_KUBECONFIG" ]]; test_access_close'
[[ ! -f "$fixture_root/private/direct-run/config" ]]
[[ "$(tail -n 1 "$fixture_root/trace")" == "remove $fixture_root/private/direct-run/config" ]]

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
