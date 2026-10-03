#!/usr/bin/env bash
# Shell bridge to the canonical Python authority and invocation lifecycle.

_TEST_ACCESS_OWNED_PATH=''
_TEST_ACCESS_CLOSE_STATUS=0
_TEST_ACCESS_CATALOG_DIGEST=''
_TEST_ACCESS_PURPOSE_PATHS=()
_TEST_ACCESS_PURPOSE_CLOSE_STATUS=0

test_access_resolve() {
  uv run --locked --no-dev python -m scripts.test.access resolve "$1"
}

test_access_open() {
  local suite_id="$1" run_id="$2" declaration profile config parent
  declaration="$(test_access_resolve "$suite_id")" || return 1
  _TEST_ACCESS_CATALOG_DIGEST="$(yq -r '.catalog_digest' - <<<"$declaration")" || return 1
  profile="$(yq -r '.profile // "null"' - <<<"$declaration")" || return 1
  if [[ "$profile" == 'null' ]]; then
    if [[ "$(yq -r '.operator_boundary // "none"' - <<<"$declaration")" == physical-power-and-talos ]]; then
      config="${NODE_OPERATOR_KUBECONFIG:-}"
      [[ -z "${TEST_ACCESS_CONFIG:-}" && "$config" == /* && -f "$config" &&
         ( -z "${TEST_KUBECONFIG:-}" || "$TEST_KUBECONFIG" == "$config" ) ]] || {
        echo 'Physical node testing remains operator-run and requires an explicit NODE_OPERATOR_KUBECONFIG.' >&2
        return 1
      }
      export TEST_KUBECONFIG="$config" KUBECONFIG="$config" TEST_ACCESS_CONFIG=''
      return 0
    fi
    export TEST_KUBECONFIG='' TEST_ACCESS_CONFIG='' KUBECONFIG=/dev/null
    return 0
  fi
  parent="${TEST_ACCESS_CONFIG:-}"
  if [[ -n "$parent" ]]; then
    [[ -z "${TEST_KUBECONFIG:-}" || "$TEST_KUBECONFIG" == "$parent" ]] || {
      echo 'Test config does not match its parent invocation.' >&2
      return 1
    }
    uv run --locked --no-dev python -m scripts.test.access inherit "$suite_id" "$parent" \
      >/dev/null || return 1
    config="$parent"
  else
    [[ -z "${TEST_KUBECONFIG:-}" ]] || {
      echo 'Tests select credentials from the catalog; an unbound TEST_KUBECONFIG is not accepted.' >&2
      return 1
    }
    config="$(uv run --locked --no-dev python -m scripts.test.access prepare "$suite_id" "$run_id")" || return 1
    _TEST_ACCESS_OWNED_PATH="$config"
    if ! uv run --locked --no-dev python -m scripts.test.access validate "$config" >/dev/null; then
      test_access_close || true
      return 1
    fi
  fi
  [[ "$config" == /* && -f "$config" ]] || {
    test_access_close || true
    echo 'Test invocation did not produce a usable private config.' >&2
    return 1
  }
  export TEST_KUBECONFIG="$config" TEST_ACCESS_CONFIG="$config" KUBECONFIG="$config"
}

test_access_check() {
  local declaration
  if [[ -z "${TEST_ACCESS_CONFIG:-}" ]]; then
    declaration="$(test_access_resolve "$1")" || return 1
    [[ "$(yq -r '.catalog_digest' - <<<"$declaration")" == "$_TEST_ACCESS_CATALOG_DIGEST" &&
       "$(yq -r '.profile // "null"' - <<<"$declaration")" == null ]]
    return "$?"
  fi
  uv run --locked --no-dev python -m scripts.test.access inherit "$1" "$TEST_ACCESS_CONFIG" \
    >/dev/null
}

test_access_arguments() {
  local argument expects_config=false
  TEST_ACCESS_ARGUMENTS=()
  for argument in "$@"; do
    if [[ "$expects_config" == 'true' ]]; then
      [[ "$argument" == "${TEST_KUBECONFIG:-}" && -n "$argument" ]] || {
        echo 'Backend kubeconfig must be the selected invocation config.' >&2
        return 1
      }
      expects_config=false
    fi
    case "$argument" in
      @test-kubeconfig@) argument="${TEST_KUBECONFIG:-}" ;;
      .kube/config|*/.kube/config|--context|--context=*|use-context|set-context)
        echo 'Static Kubernetes credentials and manual context selection are not accepted by test dispatch.' >&2
        return 1
        ;;
      --kubeconfig) expects_config=true ;;
      --kubeconfig=*)
        [[ -n "${TEST_KUBECONFIG:-}" && "$argument" == "--kubeconfig=$TEST_KUBECONFIG" ]] || {
          echo 'Backend kubeconfig must be the selected invocation config.' >&2
          return 1
        }
        ;;
    esac
    TEST_ACCESS_ARGUMENTS+=("$argument")
  done
  [[ "$expects_config" == 'false' ]]
}

test_access_close() {
  local owned="$_TEST_ACCESS_OWNED_PATH"
  [[ -n "$owned" ]] || return "$_TEST_ACCESS_CLOSE_STATUS"
  _TEST_ACCESS_OWNED_PATH=''
  if ! uv run --locked --no-dev python -m scripts.test.access remove "$owned"; then
    _TEST_ACCESS_CLOSE_STATUS=1
  fi
  return "$_TEST_ACCESS_CLOSE_STATUS"
}

test_access_purpose_check() {
  uv run --locked --no-dev python -m scripts.test.access purpose-check "$1" "$2" "$3"
}

test_access_purpose_open() {
  local purpose="$1" run_id="$2" config
  TEST_ACCESS_PURPOSE_CONFIG=''
  config="$(uv run --locked --no-dev python -m scripts.test.access purpose "$purpose" "$run_id")" || return 1
  [[ "$config" == /* && -f "$config" ]] || {
    echo 'Orchestration did not produce a private purpose config.' >&2
    return 1
  }
  _TEST_ACCESS_PURPOSE_PATHS+=("$config")
  test_access_purpose_check "$purpose" "$run_id" "$config" || return 1
  # Shell callers consume this value; do not export orchestration paths to suites.
  # shellcheck disable=SC2034
  TEST_ACCESS_PURPOSE_CONFIG="$config"
}

test_access_purposes_close() {
  local config
  local owned=("${_TEST_ACCESS_PURPOSE_PATHS[@]}")
  _TEST_ACCESS_PURPOSE_PATHS=()
  for config in "${owned[@]}"; do
    if ! uv run --locked --no-dev python -m scripts.test.access remove "$config"; then
      _TEST_ACCESS_PURPOSE_CLOSE_STATUS=1
    fi
  done
  return "$_TEST_ACCESS_PURPOSE_CLOSE_STATUS"
}
