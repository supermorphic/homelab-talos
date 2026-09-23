#!/usr/bin/env bash
set -euo pipefail

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/homelab-node-operations-test.XXXXXX")"
trap 'rm -rf -- "$fixture_root"' EXIT

fail() {
  echo "$*" >&2
  exit 1
}

assert_fails() {
  local description="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    fail "$description"
  fi
}

source scripts/lib/node-operations.sh
source scripts/node/resize-longhorn.sh

resolve_node_target nuc1
[[ "$NODE_NAME" == nuc1 && "$NODE_IP" == 192.168.90.10 ]]
resolve_node_target nuc2
[[ "$NODE_NAME" == nuc2 && "$NODE_IP" == 192.168.90.11 ]]
resolve_node_target nuc3
[[ "$NODE_NAME" == nuc3 && "$NODE_IP" == 192.168.90.12 ]]
[[ "$NODE_CLUSTER_ENDPOINTS" == 192.168.90.10,192.168.90.11,192.168.90.12 ]]
assert_fails 'An unknown node target was accepted.' resolve_node_target node-a

export confirmation_value='expected-value'
require_exact_confirmation confirmation_value expected-value
assert_fails 'An incorrect confirmation was accepted.' \
  require_exact_confirmation confirmation_value other-value

run_checkout_case() (
  local layout="$1"
  git() {
    case "$*" in
      'rev-parse --path-format=absolute --git-dir')
        [[ "$layout" == primary ]] && printf '/fixture/repo/.git\n' ||
          printf '/fixture/repo/.git/worktrees/task\n'
        ;;
      'rev-parse --path-format=absolute --git-common-dir')
        printf '/fixture/repo/.git\n'
        ;;
      'rev-parse --show-superproject-working-tree')
        printf '\n'
        ;;
      *) return 64 ;;
    esac
  }
  require_operator_checkout
)
run_checkout_case primary
assert_fails 'A linked worktree was accepted for operator mutation.' \
  run_checkout_case linked
NODE_ALLOW_LINKED_WORKTREE_FOR_TESTS=true run_checkout_case linked

calls="$fixture_root/transaction.calls"
transaction_failure=''
verify_test_lease_holder() {
  printf 'holder\n' >>"$calls"
  [[ "$transaction_failure" != holder ]]
}
assert_established_disruption_admissible() {
  printf 'admission\n' >>"$calls"
  [[ "$transaction_failure" != admission ]]
}
resize_just() {
  [[ "$*" == 'bootstrap _resize-longhorn-raw nuc1' ]] || return 64
  printf 'resize\n' >>"$calls"
}

: >"$calls"
run_resize_longhorn_transaction fixture-kubeconfig nuc1 holder-example
[[ "$(cat "$calls")" == $'holder\nadmission\nresize' ]]

for transaction_failure in holder admission; do
  : >"$calls"
  assert_fails "$transaction_failure failure did not stop the resize transaction." \
    run_resize_longhorn_transaction fixture-kubeconfig nuc1 holder-example
  if rg -qx resize "$calls"; then
    fail "$transaction_failure failure allowed the raw resize."
  fi
done
transaction_failure=''

top_level="$fixture_root/top-level"
mkdir -p "$top_level/clusterconfig"
touch "$top_level/kubeconfig" "$top_level/talosconfig" \
  "$top_level/clusterconfig/nuc1.yaml"
fake_just="$fixture_root/fake-just"
cat >"$fake_just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'resize\n' >>"${NODE_OPERATIONS_TEST_CALLS:?}"
EOF
chmod +x "$fake_just"

require_operator_checkout() { :; }
acquire_test_lease() { :; }
start_test_lease_renewal() { : >"$3"; }
stop_test_lease_renewal() { :; }
release_test_lease() { :; }
resize_just() { "${NODE_JUST:-just}" "$@"; }
: >"$calls"
if (
  cd "$top_level"
  NODE_JUST="$fake_just" \
  NODE_OPERATIONS_TEST_CALLS="$calls" \
  TALOS_RESIZE_LONGHORN_CONFIRM=resize-longhorn:nuc1:192.168.90.10 \
    resize_longhorn_main nuc1 "$top_level/kubeconfig" "$top_level/talosconfig"
) >/dev/null 2>&1; then
  fail 'A pre-transaction Lease renewal failure was accepted.'
fi
[[ ! -s "$calls" ]] || fail 'A pre-transaction Lease renewal failure reached the raw resize.'

echo 'Retained node operation tests passed.'
