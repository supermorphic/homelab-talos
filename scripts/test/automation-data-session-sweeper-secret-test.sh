#!/usr/bin/env bash
# Exercise the session sweeper SOPS Secret writer with real SOPS and throwaway age keys.
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-session-sweeper-secret.XXXXXX")"
trap 'rm -rf -- "$test_dir"' EXIT
tree="$test_dir/tree"
stub_bin="$test_dir/bin"
script=scripts/operations/automation-data-session-sweeper-secret.sh
app=kubernetes/apps/automation-data/postgresql/app
target="$app/session-sweeper-credentials.sops.yaml"
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
# Real SOPS reads and writes every file, so its format detection is exercised. The
# wrapper only injects an encryption failure or a wrong recipient.
age-keygen -o "$test_dir/age.key" 2>/dev/null
age-keygen -o "$test_dir/wrong-age.key" 2>/dev/null
recipient="$(age-keygen -y "$test_dir/age.key")"
wrong_recipient="$(age-keygen -y "$test_dir/wrong-age.key")"
cat >"$stub_bin/sops" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == --encrypt ]]; then
  [[ "\$2" == --filename-override && "\$#" -eq 4 ]] || exit 98
  [[ "\$3" == $target ]] || exit 98
  [[ "\${FAKE_SOPS_FAIL:-}" != true ]] || exit 97
  if [[ -n "\${FAKE_SOPS_RECIPIENT:-}" ]]; then
    exec $(command -v sops) --encrypt --age "\$FAKE_SOPS_RECIPIENT" --filename-override "\$3" "\$4"
  fi
fi
exec $(command -v sops) "\$@"
EOF
chmod 700 "$stub_bin/just" "$stub_bin/sops"

mkdir -p "$tree/$app" "$tree/scripts/operations"
cp "$repo_root/$script" "$tree/$script"
# Start from the staged package even after the real one selects the Secret.
grep -vxF '  - ./session-sweeper-credentials.sops.yaml' "$repo_root/$app/kustomization.yaml" \
  >"$tree/$app/kustomization.yaml"
# Keep the repository's rules, including encrypted_regex, with throwaway recipients.
recipient="$recipient" wrong_recipient="$wrong_recipient" yq '
  .creation_rules[].age = strenv(wrong_recipient) |
  (.creation_rules[] | select(.path_regex | test("kubernetes")) | .age) = strenv(recipient)
' "$repo_root/.sops.yaml" >"$tree/.sops.yaml"
original_kustomization="$test_dir/kustomization.original"
cp "$tree/$app/kustomization.yaml" "$original_kustomization"

run_writer() {
  (cd "$tree" && env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE PATH="$stub_bin:$PATH" "$@" \
    "$script") >"$test_dir/out" 2>&1
}
written_password() {
  SOPS_AGE_KEY_FILE="$test_dir/age.key" sops --decrypt \
    --extract '["stringData"]["password"]' "$tree/$target"
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
first_password="$(written_password)"
[[ "$first_password" =~ ^[0-9a-f]{64}$ ]] || fail 'the writer must generate a 64-hex password'
if rg -Fq -- "$first_password" "$tree/$target" "$test_dir/out"; then
  fail 'the plaintext password reached the Secret file or the output'
fi
[[ "$(yq -r '[.resources[] | select(. == "./session-sweeper-credentials.sops.yaml")] | length' \
  "$tree/$app/kustomization.yaml")" == 1 ]] || fail 'the writer must select the Secret once'
diff <(grep -vxF '  - ./session-sweeper-credentials.sops.yaml' "$tree/$app/kustomization.yaml") \
  "$original_kustomization" >/dev/null || fail 'the writer must change only the resource entry'

# Rerunning rotates the password and keeps a single resource entry.
cp "$tree/$app/kustomization.yaml" "$test_dir/kustomization.selected"
run_writer AUTOMATION_DATA_SESSION_SWEEPER_SECRET_CONFIRM="$confirmation" ||
  fail 'rotation failed'
[[ "$(written_password)" != "$first_password" ]] ||
  fail 'rotation must generate a new password'
cmp -s "$tree/$app/kustomization.yaml" "$test_dir/kustomization.selected" ||
  fail 'rotation must not change the kustomization'

# A failed or mismatched encryption leaves the previous files in place.
cp "$tree/$target" "$test_dir/secret.previous"
for failure in FAKE_SOPS_FAIL=true "FAKE_SOPS_RECIPIENT=$wrong_recipient"; do
  if run_writer AUTOMATION_DATA_SESSION_SWEEPER_SECRET_CONFIRM="$confirmation" "$failure"; then
    fail "the writer must refuse when $failure"
  fi
  [[ "$failure" != FAKE_SOPS_RECIPIENT=* ]] ||
    rg -Fq 'does not use the expected recipient' "$test_dir/out" ||
    fail 'a wrong recipient must be refused by the recipient check'
  cmp -s "$tree/$target" "$test_dir/secret.previous" ||
    fail "the previous Secret must survive $failure"
  cmp -s "$tree/$app/kustomization.yaml" "$test_dir/kustomization.selected" ||
    fail "the kustomization must survive $failure"
done

(cd "$repo_root" && just --justfile .just/repository.just --dry-run \
  automation-data-session-sweeper-secret >/dev/null 2>&1) ||
  fail 'the repo automation-data-session-sweeper-secret recipe is missing'

echo 'automation-data session sweeper Secret writer test passed'
