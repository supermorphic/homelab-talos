#!/usr/bin/env bash
# Exercise the session sweeper SOPS Secret writer with stub encryption.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-session-sweeper-secret.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT
tree="$test_dir/tree"
stub_bin="$test_dir/bin"
script=scripts/operations/automation-data-session-sweeper-secret.sh
app=kubernetes/apps/automation-data/postgresql/app
target="$app/session-sweeper-credentials.sops.yaml"
recipient='age1syntheticrecipientforautomationdata0000000000000000000000000'
confirmation='write:automation-data:session-sweeper:sops'
fail() {
  echo "automation-data session sweeper Secret writer test failed: $*" >&2
  exit 1
}

mkdir -p "$stub_bin"
cat >"$stub_bin/just" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == 'repo secrets' ]] || exit 98
EOF
# The stub records the plaintext password it received so the test can prove that
# the written file never contains it.
cat >"$stub_bin/sops" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == filestatus ]]; then
  echo 'encrypted: true'
  exit 0
fi
[[ "$1" == --encrypt && "$2" == --filename-override && "$#" -eq 4 ]] || exit 98
[[ "${FAKE_SOPS_FAIL:-}" != true ]] || exit 97
[[ "$3" == kubernetes/apps/automation-data/postgresql/app/session-sweeper-credentials.sops.yaml ]]
yq -r '.stringData.password' "$4" >>"$PASSWORD_LOG"
cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: $(yq -r '.metadata.name' "$4")
  namespace: $(yq -r '.metadata.namespace' "$4")
type: Opaque
stringData:
  password: ENC[synthetic]
sops:
  age:
    - recipient: ${FAKE_SOPS_RECIPIENT:-age1syntheticrecipientforautomationdata0000000000000000000000000}
YAML
EOF
chmod 700 "$stub_bin/just" "$stub_bin/sops"

mkdir -p "$tree/$app" "$tree/scripts/operations"
cp "$repo_root/$script" "$tree/$script"
# Start from the staged package even after the real one selects the Secret.
grep -vxF '  - ./session-sweeper-credentials.sops.yaml' "$repo_root/$app/kustomization.yaml" \
  >"$tree/$app/kustomization.yaml"
cat >"$tree/.sops.yaml" <<EOF
creation_rules:
  - path_regex: ^talos/talsecret\\.sops\\.ya?ml$
    age: age1synthetictalosrecipient00000000000000000000000000000000000
  - path_regex: ^kubernetes/.*\\.sops\\.ya?ml$
    age: $recipient
EOF
original_kustomization="$test_dir/kustomization.original"
cp "$tree/$app/kustomization.yaml" "$original_kustomization"

run_writer() {
  (cd "$tree" && env PATH="$stub_bin:$PATH" PASSWORD_LOG="$test_dir/passwords" "$@" \
    "$script") >"$test_dir/out" 2>&1
}

if run_writer AUTOMATION_DATA_SESSION_SWEEPER_SECRET_CONFIRM=; then
  fail 'the writer must require confirmation'
fi
rg -Fq "AUTOMATION_DATA_SESSION_SWEEPER_SECRET_CONFIRM='$confirmation'" "$test_dir/out" ||
  fail 'the writer must name its confirmation'
[[ ! -e "$tree/$target" ]] || fail 'a refused write must not create the Secret file'

run_writer AUTOMATION_DATA_SESSION_SWEEPER_SECRET_CONFIRM="$confirmation" ||
  fail "the writer failed: $(cat "$test_dir/out")"
[[ "$(yq -r '[.kind, .metadata.name, .metadata.namespace, (.stringData | keys | join(","))] | join("|")' \
  "$tree/$target")" == 'Secret|automation-data-session-sweeper|automation-data|password' ]] ||
  fail 'the writer must produce the sweeper Secret with only the password key'
first_password="$(tail -1 "$test_dir/passwords")"
[[ "$first_password" =~ ^[0-9a-f]{64}$ ]] || fail 'the writer must generate a 64-hex password'
! rg -Fq -- "$first_password" "$tree/$target" "$test_dir/out" ||
  fail 'the plaintext password reached the Secret file or the output'
[[ "$(yq -r '[.resources[] | select(. == "./session-sweeper-credentials.sops.yaml")] | length' \
  "$tree/$app/kustomization.yaml")" == 1 ]] || fail 'the writer must select the Secret once'
diff <(grep -vxF '  - ./session-sweeper-credentials.sops.yaml' "$tree/$app/kustomization.yaml") \
  "$original_kustomization" >/dev/null || fail 'the writer must change only the resource entry'

# Rerunning rotates the password and keeps a single resource entry.
cp "$tree/$app/kustomization.yaml" "$test_dir/kustomization.selected"
run_writer AUTOMATION_DATA_SESSION_SWEEPER_SECRET_CONFIRM="$confirmation" ||
  fail 'rotation failed'
[[ "$(tail -1 "$test_dir/passwords")" != "$first_password" ]] ||
  fail 'rotation must generate a new password'
cmp -s "$tree/$app/kustomization.yaml" "$test_dir/kustomization.selected" ||
  fail 'rotation must not change the kustomization'

# A failed or mismatched encryption leaves the previous files in place.
cp "$tree/$target" "$test_dir/secret.previous"
for failure in FAKE_SOPS_FAIL=true "FAKE_SOPS_RECIPIENT=age1wrongrecipient"; do
  if run_writer AUTOMATION_DATA_SESSION_SWEEPER_SECRET_CONFIRM="$confirmation" "$failure"; then
    fail "the writer must refuse when $failure"
  fi
  cmp -s "$tree/$target" "$test_dir/secret.previous" ||
    fail "the previous Secret must survive $failure"
  cmp -s "$tree/$app/kustomization.yaml" "$test_dir/kustomization.selected" ||
    fail "the kustomization must survive $failure"
done

(cd "$repo_root" && just --justfile .just/repository.just --dry-run \
  automation-data-session-sweeper-secret >/dev/null 2>&1) ||
  fail 'the repo automation-data-session-sweeper-secret recipe is missing'

echo 'automation-data session sweeper Secret writer test passed'
