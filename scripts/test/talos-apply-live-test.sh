#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
apply_live="$repo_root/scripts/talos/apply-live.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/talos-apply-live-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

stub_bin="$fixture/bin"
state_dir="$fixture/state"
talosconfig="$fixture/talosconfig"
generated_config="$fixture/nuc2.yaml"
call_log="$state_dir/calls.log"
mkdir -p "$stub_bin" "$state_dir"
touch "$talosconfig" "$generated_config"

cat >"$stub_bin/talosctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'talosctl %s\n' "$*" >>"$FAKE_CALL_LOG"

if [[ "${1:-} ${2:-}" == 'get hostname' ]]; then
  cat <<YAML
spec:
  hostname: ${FAKE_HOSTNAME:-nuc2}
YAML
  exit 0
fi

[[ "${1:-}" == 'apply-config' ]] || {
  echo "unexpected talosctl arguments: $*" >&2
  exit 64
}

if [[ " $* " != *' --dry-run '* ]]; then
  exit 0
fi

count=0
[[ ! -f "$FAKE_STATE_DIR/dry-run-count" ]] || count="$(<"$FAKE_STATE_DIR/dry-run-count")"
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_STATE_DIR/dry-run-count"

if (( count == 1 )); then
  cat <<'OUTPUT'
Apply configuration in no-reboot mode
Config diff:

--- old
+++ new
@@ fixture @@
-old value
+new value
OUTPUT
  exit 0
fi

case "${FAKE_POST_APPLY:-converged}" in
  converged)
    printf 'Apply configuration in no-reboot mode\nConfig diff:\n\nNo changes.\n'
    ;;
  drift)
    cat <<'OUTPUT'
Apply configuration in no-reboot mode
Config diff:

--- old
+++ new
@@ fixture @@
-old value
+still pending
OUTPUT
    ;;
  failure)
    echo 'FAKE_POST_FAILURE_DETAILS_SHOULD_NOT_ESCAPE' >&2
    exit 75
    ;;
  *)
    echo "unexpected post-apply scenario: $FAKE_POST_APPLY" >&2
    exit 64
    ;;
esac
EOF
chmod +x "$stub_bin/talosctl"

reset_case() {
  rm -f -- "$state_dir"/*
  : >"$call_log"
}

run_apply_live() {
  (
    while [[ "${1:-}" == *=* ]]; do
      export "${1?}"
      shift
    done
    PATH="$stub_bin:$PATH" \
      FAKE_CALL_LOG="$call_log" \
      FAKE_STATE_DIR="$state_dir" \
      "$apply_live" nuc2 "$talosconfig" "$generated_config"
  )
}

count_calls() {
  local pattern="$1"
  local count
  count="$(rg -c -- "$pattern" "$call_log" || true)"
  printf '%s\n' "${count:-0}"
}

count_real_applies() {
  awk '/^talosctl apply-config / && $0 !~ / --dry-run$/ {count++} END {print count + 0}' \
    "$call_log"
}

assert_apply_shape() {
  local expected_dry_runs="$1"
  local expected_real_applies="$2"
  local actual_dry_runs actual_real_applies
  actual_dry_runs="$(count_calls '^talosctl apply-config .* --dry-run$')"
  actual_real_applies="$(count_real_applies)"
  [[ "$actual_dry_runs" == "$expected_dry_runs" && "$actual_real_applies" == "$expected_real_applies" ]] || {
    echo "Expected dry-run/apply calls $expected_dry_runs/$expected_real_applies; found $actual_dry_runs/$actual_real_applies." >&2
    cat "$call_log" >&2
    exit 1
  }
}

reset_case
if run_apply_live FAKE_HOSTNAME=wrong >"$state_dir/wrong-hostname.out" 2>&1; then
  echo 'apply-live accepted the wrong secure hostname.' >&2
  exit 1
fi
assert_apply_shape 0 0

reset_case
if run_apply_live >"$state_dir/missing-confirmation.out" 2>&1; then
  echo 'apply-live accepted a missing confirmation.' >&2
  exit 1
fi
assert_apply_shape 1 0

reset_case
if run_apply_live \
  TALOS_APPLY_LIVE_CONFIRM=wrong \
  >"$state_dir/wrong-confirmation.out" 2>&1; then
  echo 'apply-live accepted the wrong confirmation.' >&2
  exit 1
fi
assert_apply_shape 1 0

reset_case
run_apply_live \
  FAKE_POST_APPLY=converged \
  TALOS_APPLY_LIVE_CONFIRM=apply-live:nuc2:192.168.90.11:no-reboot \
  >"$state_dir/converged.out" 2>&1
assert_apply_shape 2 1
mapfile -t apply_calls < <(rg '^talosctl apply-config ' "$call_log")
[[ "${apply_calls[0]}" == *' --dry-run' ]]
[[ "${apply_calls[1]}" != *' --dry-run' ]]
[[ "${apply_calls[2]}" == *' --dry-run' ]]
rg -Fq 'Talos apply-live converged on nuc2; the post-apply dry run reports no changes.' \
  "$state_dir/converged.out"
if rg -q -- ' --insecure( |$)' "$call_log"; then
  echo 'apply-live used an insecure Talos API call.' >&2
  exit 1
fi

reset_case
if run_apply_live \
  FAKE_POST_APPLY=drift \
  TALOS_APPLY_LIVE_CONFIRM=apply-live:nuc2:192.168.90.11:no-reboot \
  >"$state_dir/drift.out" 2>&1; then
  echo 'apply-live accepted remaining machine-configuration drift.' >&2
  exit 1
fi
assert_apply_shape 2 1
rg -Fq 'Talos still reports machine-configuration drift after apply-live for nuc2.' \
  "$state_dir/drift.out"
rg -Fq -- '+still pending' "$state_dir/drift.out"

reset_case
if run_apply_live \
  FAKE_POST_APPLY=failure \
  TALOS_APPLY_LIVE_CONFIRM=apply-live:nuc2:192.168.90.11:no-reboot \
  >"$state_dir/post-failure.out" 2>&1; then
  echo 'apply-live accepted a failed post-apply dry run.' >&2
  exit 1
fi
assert_apply_shape 2 1
rg -Fq 'Talos post-apply convergence check failed for nuc2.' "$state_dir/post-failure.out"
if rg -Fq 'FAKE_POST_FAILURE_DETAILS_SHOULD_NOT_ESCAPE' "$state_dir/post-failure.out"; then
  echo 'apply-live exposed unbounded post-apply failure details.' >&2
  exit 1
fi

printf '%s\n' 'Talos apply-live behavior fixture passed.'
