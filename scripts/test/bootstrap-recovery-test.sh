#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
just_bin="$(command -v just)"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-recovery-test.XXXXXX")"
trap 'rm -rf -- "$fixture"' EXIT

test_repo="$fixture/repository"
stub_bin="$fixture/bin"
state_dir="$fixture/state"
mkdir -p \
  "$test_repo/.just" \
  "$test_repo/.kube" \
  "$test_repo/.talos" \
  "$test_repo/kubernetes/apps/kube-system/cilium" \
  "$stub_bin" \
  "$state_dir"

cp "$repo_root/.just/bootstrap.just" "$test_repo/.just/bootstrap.just"

cat >"$test_repo/.justfile" <<'EOF'
#!/usr/bin/env -S just --justfile

mod bootstrap ".just/bootstrap.just"
EOF

cat >"$test_repo/kubernetes/apps/kube-system/cilium/ks.yaml" <<'EOF'
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cilium
spec:
  suspend: true
EOF

cat >"$test_repo/.sops.yaml" <<'EOF'
creation_rules:
  - path_regex: kubernetes
    age: age1bootstraprecoveryfixture
EOF

touch "$test_repo/.kube/config" "$test_repo/.talos/config"

cat >"$stub_bin/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == 'status --porcelain' ]] || {
  echo "unexpected git arguments: $*" >&2
  exit 64
}
EOF

cat >"$stub_bin/just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'just %s\n' "$*" >>"$FAKE_CALL_LOG"
if [[ "${FAKE_CILIUM_FAILURE:-}" == 'before-resume' && "$*" == 'kube flux-validate' ]]; then
  exit 70
fi
if [[ "${FAKE_CILIUM_FAILURE:-}" == 'after-resume' && "$*" == 'kube cilium-postflight' ]]; then
  exit 71
fi
EOF

cat >"$stub_bin/yq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == '--inplace' ]]; then
  source_file="$3"
  sed 's/suspend: true/suspend: false/' "$source_file" >"$source_file.tmp"
  mv "$source_file.tmp" "$source_file"
  exit 0
fi

expression="${2:-}"
case "$expression" in
  '.spec.suspend')
    awk '$1 == "suspend:" {print $2}' "$3"
    ;;
  '.creation_rules[] | select(.path_regex | test("kubernetes")) | .age')
    printf '%s\n' 'age1bootstraprecoveryfixture'
    ;;
  '.items[] | .metadata.name + "\t" + .metadata.uid + "\t" + ([.status.containerStatuses[].restartCount] | join(","))')
    cat >/dev/null
    printf 'cilium-fixture\tfixture-uid\t0,0\n'
    ;;
  '.[] | select(.name == "cilium") | .revision')
    cat >/dev/null
    printf '%s\n' '2'
    ;;
  *)
    echo "unexpected yq arguments: $*" >&2
    exit 64
    ;;
esac
EOF

cat >"$stub_bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'kubectl %s\n' "$*" >>"$FAKE_CALL_LOG"
case "$*" in
  *'get kustomization cilium --output jsonpath={.spec.suspend}')
    printf '%s' 'true'
    ;;
  *'get secret sops-age --output jsonpath={.data.age\.agekey}')
    printf '%s' 'Zml4dHVyZS1rZXk='
    ;;
  *'get pods --selector app.kubernetes.io/part-of=cilium --output json')
    printf '%s\n' '{"items":[]}'
    ;;
  *'get helmrelease cilium'|*' wait '*)
    ;;
  *)
    echo "unexpected kubectl arguments: $*" >&2
    exit 64
    ;;
esac
EOF

cat >"$stub_bin/flux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'flux %s\n' "$*" >>"$FAKE_CALL_LOG"
case "${1:-}" in
  check|reconcile|resume|suspend) ;;
  *)
    echo "unexpected flux arguments: $*" >&2
    exit 64
    ;;
esac
EOF

cat >"$stub_bin/helm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'helm %s\n' "$*" >>"$FAKE_CALL_LOG"
printf '%s\n' '[]'
EOF

cat >"$stub_bin/age-keygen" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'age1bootstraprecoveryfixture'
EOF

cat >"$stub_bin/talosctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'talosctl %s\n' "$*" >>"$FAKE_CALL_LOG"

missing_members() {
  cat <<'TABLE'
NODE  ID  NAME
192.0.2.10  member-1  nuc1
192.0.2.12  member-3  nuc3
TABLE
}

complete_members() {
  cat <<'TABLE'
NODE  ID  NAME
192.0.2.10  member-1  nuc1
192.0.2.11  member-2  nuc2
192.0.2.12  member-3  nuc3
TABLE
}

case "${1:-} ${2:-}" in
  'etcd members')
    count=0
    [[ ! -f "$FAKE_STATE_DIR/member-count" ]] || count="$(<"$FAKE_STATE_DIR/member-count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_STATE_DIR/member-count"
    case "${FAKE_ETCD_SCENARIO:-healthy}" in
      never)
        missing_members
        ;;
      delayed)
        if (( count < 3 )); then missing_members; else complete_members; fi
        ;;
      *)
        if (( count == 1 )); then missing_members; else complete_members; fi
        ;;
    esac
    ;;
  'service etcd')
    count=0
    [[ ! -f "$FAKE_STATE_DIR/service-count" ]] || count="$(<"$FAKE_STATE_DIR/service-count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_STATE_DIR/service-count"
    if (( count == 1 )); then
      printf 'STATE Failed\nHEALTH Unknown\n'
    elif [[ "${FAKE_ETCD_SCENARIO:-healthy}" == 'service-fail' ]]; then
      printf 'STATE Running\nHEALTH Unhealthy\n'
    else
      printf 'STATE Running\nHEALTH Healthy\n'
    fi
    ;;
  'get members')
    cat <<'TABLE'
NODE NAMESPACE TYPE NAME
192.0.2.11 runtime Member nuc1
192.0.2.11 runtime Member nuc2
192.0.2.11 runtime Member nuc3
TABLE
    ;;
  'reboot '*)
    ;;
  'etcd status')
    if [[ "${FAKE_ETCD_SCENARIO:-healthy}" == 'status-fail' ]]; then
      cat <<'TABLE'
NODE  MEMBER ID  DB SIZE  IN USE  LEADER
192.0.2.10  member-1  1 MB  1 MB  member-1
192.0.2.11  member-2  1 MB  1 MB  member-1
TABLE
    else
      cat <<'TABLE'
NODE  MEMBER ID  DB SIZE  IN USE  LEADER
192.0.2.10  member-1  1 MB  1 MB  member-1
192.0.2.11  member-2  1 MB  1 MB  member-1
192.0.2.12  member-3  1 MB  1 MB  member-1
TABLE
    fi
    ;;
  'etcd alarm')
    [[ "${3:-}" == 'list' ]] || exit 64
    printf 'NODE  MEMBER ID  ALARM\n'
    if [[ "${FAKE_ETCD_SCENARIO:-healthy}" == 'alarm-fail' ]]; then
      printf '192.0.2.11  member-2  NOSPACE\n'
    fi
    ;;
  *)
    echo "unexpected talosctl arguments: $*" >&2
    exit 64
    ;;
esac
EOF

cat >"$stub_bin/sleep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sleep %s\n' "$*" >>"$FAKE_CALL_LOG"
EOF

chmod +x "$stub_bin"/*

source_file="$test_repo/kubernetes/apps/kube-system/cilium/ks.yaml"
call_log="$state_dir/calls.log"

source_suspend() {
  awk '$1 == "suspend:" {print $2}' "$source_file"
}

reset_case() {
  rm -f -- "$state_dir"/*
  sed 's/suspend: false/suspend: true/' "$source_file" >"$source_file.tmp"
  mv "$source_file.tmp" "$source_file"
  : >"$call_log"
}

run_recipe() {
  (
    cd "$test_repo"
    while [[ "${1:-}" == *=* ]]; do
      export "${1?}"
      shift
    done
    PATH="$stub_bin:$PATH" \
      FAKE_CALL_LOG="$call_log" \
      FAKE_STATE_DIR="$state_dir" \
      "$just_bin" --justfile .justfile "$@"
  )
}

assert_count() {
  local expected="$1"
  local pattern="$2"
  local actual
  actual="$(rg -c -- "$pattern" "$call_log" || true)"
  actual="${actual:-0}"
  [[ "$actual" == "$expected" ]] || {
    echo "Expected $expected calls matching '$pattern'; found $actual." >&2
    cat "$call_log" >&2
    for output in "$state_dir"/*.out; do
      [[ -e "$output" ]] || continue
      cat "$output" >&2
    done
    exit 1
  }
}

reset_case
if run_recipe \
  FAKE_CILIUM_FAILURE=before-resume \
  FLUX_CILIUM_ADOPTION_CONFIRM=adopt:cilium:kube-system:flux \
  bootstrap flux-adopt-cilium >"$state_dir/cilium-before.out" 2>&1; then
  echo 'Cilium adoption unexpectedly accepted a pre-resume validation failure.' >&2
  exit 1
fi
assert_count 0 '^flux resume kustomization cilium '
assert_count 0 '^flux suspend kustomization cilium '
[[ "$(source_suspend)" == 'true' ]]

reset_case
if run_recipe \
  FAKE_CILIUM_FAILURE=after-resume \
  FLUX_CILIUM_ADOPTION_CONFIRM=adopt:cilium:kube-system:flux \
  bootstrap flux-adopt-cilium >"$state_dir/cilium-after.out" 2>&1; then
  echo 'Cilium adoption unexpectedly accepted a post-resume verification failure.' >&2
  exit 1
fi
assert_count 1 '^flux resume kustomization cilium '
assert_count 1 '^flux suspend kustomization cilium '
[[ "$(source_suspend)" == 'true' ]]

reset_case
run_recipe \
  FLUX_CILIUM_ADOPTION_CONFIRM=adopt:cilium:kube-system:flux \
  bootstrap flux-adopt-cilium >"$state_dir/cilium-success.out" 2>&1
assert_count 1 '^flux resume kustomization cilium '
assert_count 0 '^flux suspend kustomization cilium '
[[ "$(source_suspend)" == 'false' ]]

for confirmation in absent wrong; do
  reset_case
  declare -a confirmation_env=()
  [[ "$confirmation" == 'absent' ]] || confirmation_env=(TALOS_ETCD_RETRY_CONFIRM=wrong)
  if run_recipe \
    FAKE_ETCD_SCENARIO=healthy \
    "${confirmation_env[@]}" \
    bootstrap retry-join nuc2 >"$state_dir/retry-$confirmation.out" 2>&1; then
    echo "retry-join accepted $confirmation confirmation." >&2
    exit 1
  fi
  assert_count 0 '^talosctl reboot '
done

reset_case
run_recipe \
  FAKE_ETCD_SCENARIO=delayed \
  TALOS_ETCD_RETRY_CONFIRM=retry-etcd-reboot:nuc2:192.168.90.11 \
  bootstrap retry-join nuc2 >"$state_dir/retry-delayed.out" 2>&1
assert_count 1 '^talosctl reboot '
assert_count 3 '^talosctl etcd members '
assert_count 1 '^sleep 5$'

for scenario in never service-fail status-fail alarm-fail; do
  reset_case
  if run_recipe \
    FAKE_ETCD_SCENARIO="$scenario" \
    TALOS_ETCD_RETRY_CONFIRM=retry-etcd-reboot:nuc2:192.168.90.11 \
    bootstrap retry-join nuc2 >"$state_dir/retry-$scenario.out" 2>&1; then
    echo "retry-join accepted the $scenario recovery state." >&2
    exit 1
  fi
  assert_count 1 '^talosctl reboot '
  assert_count 61 '^talosctl etcd members '
done

reset_case
run_recipe \
  FAKE_ETCD_SCENARIO=healthy \
  TALOS_ETCD_RETRY_CONFIRM=retry-etcd-reboot:nuc2:192.168.90.11 \
  bootstrap retry-join nuc2 >"$state_dir/retry-healthy.out" 2>&1
assert_count 1 '^talosctl reboot '
assert_count 2 '^talosctl etcd members '
assert_count 2 '^talosctl service etcd '
assert_count 1 '^talosctl etcd status '
assert_count 1 '^talosctl etcd alarm list '

printf '%s\n' 'Bootstrap recovery fixture passed.'
