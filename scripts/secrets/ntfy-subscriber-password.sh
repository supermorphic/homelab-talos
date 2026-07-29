#!/usr/bin/env bash
# Set or change the human-known ntfy subscriber password. Prompts twice without echo,
# generates the bcrypt hash internally, and updates only the password identity's user
# entry (plus its registry-declared ACLs) in the canonical ntfy Secret. Every other
# identity's credentials are preserved byte-for-byte. Reconciliation never touches
# this password. Nothing secret is ever printed. See docs/ntfy-startup-guide.md.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

registry_file="${NTFY_IDENTITIES_FILE:-$repo_root/kubernetes/apps/monitoring/ntfy/config/identities.yaml}"
secret_file="${NTFY_SECRET_FILE:-$repo_root/kubernetes/apps/monitoring/ntfy/app/secret.sops.yaml}"
values_file="${NTFY_VALUES_FILE:-$repo_root/kubernetes/apps/monitoring/ntfy/app/values.yaml}"
adapter_values_file="${NTFY_ADAPTER_VALUES_FILE:-$repo_root/kubernetes/apps/monitoring/alertmanager-ntfy/app/values.yaml}"
sops_policy_file="${NTFY_SOPS_POLICY_FILE:-$repo_root/.sops.yaml}"

fail() {
  echo "$1" >&2
  exit 1
}

[[ -f "$registry_file" ]] || fail "Missing ntfy identity registry: $registry_file"

# The password identity is the registry's single active credential=password entry.
subscriber=''
while IFS= read -r id; do
  [[ "$(yq -r ".identities[\"$id\"].status // \"\"" "$registry_file")" == 'active' ]] || continue
  [[ "$(yq -r ".identities[\"$id\"].credential // \"\"" "$registry_file")" == 'password' ]] || continue
  [[ -z "$subscriber" ]] || fail 'Refusing: the registry allows at most one password identity.'
  subscriber="$id"
done < <(yq -r '.identities | keys | .[]' "$registry_file")
[[ -n "$subscriber" ]] || fail "Refusing: no active password identity in $registry_file."

expected_confirmation='write:monitoring:ntfy-subscriber:sops'
[[ "${NTFY_SUBSCRIBER_PASSWORD_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing to set the ntfy '$subscriber' password." >&2
  echo "Set NTFY_SUBSCRIBER_PASSWORD_CONFIRM='$expected_confirmation' after reviewing the target." >&2
  exit 1
}

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-talos-ntfy-subscriber.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
umask 077

password_first=''
password_second=''
read -r -s -p "New ntfy '$subscriber' password: " password_first
echo
read -r -s -p "Repeat the password: " password_second
echo
[[ "$password_first" == "$password_second" ]] || fail 'Refusing: the two passwords do not match; nothing was changed.'
[[ "${#password_first}" -ge 12 ]] || fail 'Refusing: the password must be at least 12 characters.'
password_second=''

hash_line="$(printf '%s\n' "$password_first" | htpasswd -niBC 10 "$subscriber")"
password_first=''
password_hash="${hash_line#*:}"
[[ "$password_hash" =~ ^\$2[aby]\$ ]] || fail 'Refusing: the generated password hash is not bcrypt.'

# Current lists (empty on first bootstrap); every non-subscriber entry carries over.
auth_users=''
auth_access=''
auth_tokens=''
auth_yml_present=false
if [[ -f "$secret_file" ]]; then
  sops --decrypt "$secret_file" >"$temp_dir/current-secret.yaml"
  auth_users="$(yq -r '.stringData.NTFY_AUTH_USERS // ""' "$temp_dir/current-secret.yaml")"
  auth_access="$(yq -r '.stringData.NTFY_AUTH_ACCESS // ""' "$temp_dir/current-secret.yaml")"
  auth_tokens="$(yq -r '.stringData.NTFY_AUTH_TOKENS // ""' "$temp_dir/current-secret.yaml")"
  if yq -e '.stringData["auth.yml"]' "$temp_dir/current-secret.yaml" >/dev/null 2>&1; then
    auth_yml_present=true
    yq -r '.stringData["auth.yml"]' "$temp_dir/current-secret.yaml" >"$temp_dir/auth.yml"
  fi
fi

# Replace only subscriber-prefixed entries; keep every other identity in place.
keep_entries() { # <comma-list> — entries not belonging to the subscriber
  local list="$1" entry kept=''
  IFS=',' read -ra entries <<<"$list"
  for entry in "${entries[@]}"; do
    [[ -n "$entry" && "${entry%%:*}" != "$subscriber" ]] || continue
    kept+="${kept:+,}$entry"
  done
  printf '%s' "$kept"
}

new_users="$(keep_entries "$auth_users")"
new_users+="${new_users:+,}$subscriber:$password_hash:user"

new_access="$(keep_entries "$auth_access")"
while IFS= read -r acl; do
  [[ -n "$acl" ]] || continue
  [[ "$acl" =~ ^[a-z][a-z0-9_-]*:(ro|wo|rw)$ ]] ||
    fail "Refusing: registry ACL '$acl' for '$subscriber' is malformed."
  new_access+="${new_access:+,}$subscriber:$acl"
done < <(yq -r ".identities[\"$subscriber\"].access[] | .topic + \":\" + .permission" "$registry_file")

AUTH_USERS="$new_users" AUTH_ACCESS="$new_access" AUTH_TOKENS="$auth_tokens" \
  yq -n '
    .apiVersion = "v1" |
    .kind = "Secret" |
    .metadata.name = "ntfy-secret" |
    .metadata.namespace = "ntfy" |
    .type = "Opaque" |
    .stringData.NTFY_AUTH_USERS = strenv(AUTH_USERS) |
    .stringData.NTFY_AUTH_ACCESS = strenv(AUTH_ACCESS) |
    .stringData.NTFY_AUTH_TOKENS = strenv(AUTH_TOKENS)' \
    >"$temp_dir/ntfy-secret.yaml"
if [[ "$auth_yml_present" == true ]]; then
  AUTH_YML_FILE="$temp_dir/auth.yml" \
    yq -i '.stringData["auth.yml"] = load_str(strenv(AUTH_YML_FILE))' "$temp_dir/ntfy-secret.yaml"
fi

sops --encrypt --filename-override "$secret_file" \
  "$temp_dir/ntfy-secret.yaml" >"$temp_dir/ntfy-secret.sops.yaml"
[[ "$(sops filestatus "$temp_dir/ntfy-secret.sops.yaml" | yq -r '.encrypted')" == 'true' ]] ||
  fail 'Refusing: the candidate Secret is not SOPS-encrypted.'
[[ "$(yq -r '.sops.age[].recipient' "$temp_dir/ntfy-secret.sops.yaml" | sort -u)" == \
  "$(yq -r '.creation_rules[1].age' "$sops_policy_file")" ]] ||
  fail "Refusing: the candidate is not encrypted to this repository's age recipient."
if rg -Fq -- "$password_hash" "$temp_dir/ntfy-secret.sops.yaml"; then
  echo 'Refusing: the plaintext password hash appears in the encrypted output.' >&2
  exit 1
fi

mv -- "$temp_dir/ntfy-secret.sops.yaml" "$secret_file"
revision="$(git hash-object "$secret_file")"
REV="$revision" yq -i '.controllers.ntfy.pod.annotations.sops-hash = strenv(REV)' "$values_file"
REV="$revision" yq -i '.controllers["alertmanager-ntfy"].pod.annotations["sops-hash"] = strenv(REV)' "$adapter_values_file"
echo "Updated encrypted $secret_file with the new '$subscriber' password hash; stamped sops-hash. Update the iPhone/web/CLI clients after Flux reconciles."
