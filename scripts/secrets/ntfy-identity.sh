#!/usr/bin/env bash
# Registry-backed ntfy credential lifecycle. One canonical Secret (ntfy-secret in the
# ntfy namespace) holds every declarative-auth list plus the alertmanager adapter's
# auth.yml; the Homepage widget token is mirrored into Secret/homepage-ntfy because
# Secrets cannot cross namespaces. Existing bcrypt hashes and tokens are preserved by
# default; credentials are generated only for missing or explicitly rotated identities.
# Nothing secret is ever printed. See docs/ntfy-startup-guide.md.
#
# Actions:
#   ensure <identity>     Add a missing active identity (surgical; preserves all else).
#   reconcile all         Authoritative: apply the whole registry, remove retired
#                         identities, fail on Secret drift that is not tombstoned.
#   rotate <identity>     New token. Git-managed consumers switch immediately;
#                         API-managed consumers (seerr-api) stage a pending token.
#   finalize <identity>   Promote a staged pending token, revoking the previous one.
set -euo pipefail

action="${1:-}"
identity_arg="${2:-}"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

registry_file="${NTFY_IDENTITIES_FILE:-$repo_root/kubernetes/apps/monitoring/ntfy/config/identities.yaml}"
secret_file="${NTFY_SECRET_FILE:-$repo_root/kubernetes/apps/monitoring/ntfy/app/secret.sops.yaml}"
homepage_secret_file="${NTFY_HOMEPAGE_SECRET_FILE:-$repo_root/kubernetes/apps/monitoring/homepage/app/homepage-ntfy.sops.yaml}"
values_file="${NTFY_VALUES_FILE:-$repo_root/kubernetes/apps/monitoring/ntfy/app/values.yaml}"
adapter_values_file="${NTFY_ADAPTER_VALUES_FILE:-$repo_root/kubernetes/apps/monitoring/alertmanager-ntfy/app/values.yaml}"
homepage_deployment_file="${NTFY_HOMEPAGE_DEPLOYMENT_FILE:-$repo_root/kubernetes/apps/monitoring/homepage/app/deployment.yaml}"
sops_policy_file="${NTFY_SOPS_POLICY_FILE:-$repo_root/.sops.yaml}"

usage() {
  echo 'Usage: ntfy-identity.sh <ensure|reconcile|rotate|finalize> <identity|all>' >&2
  exit 2
}

fail() {
  echo "$1" >&2
  exit 1
}

case "$action" in
  ensure | reconcile | rotate | finalize) ;;
  *) usage ;;
esac
[[ -n "$identity_arg" ]] || usage
[[ -f "$registry_file" ]] || fail "Missing ntfy identity registry: $registry_file"

# ---------------------------------------------------------------------------
# Registry parsing and validation (fail on unknown or malformed entries).
# registry_ids is sorted so every list the script builds is deterministically
# ordered by identity name, regardless of registry document order.
# ---------------------------------------------------------------------------
declare -A reg_status=() reg_credential=() reg_consumer=() reg_acls=()
declare -a registry_ids=()
while IFS= read -r id; do
  registry_ids+=("$id")
done < <(yq -r '.identities | keys | .[]' "$registry_file" | LC_ALL=C sort)
[[ "${#registry_ids[@]}" -gt 0 ]] || fail "Refusing: $registry_file has no identities."

password_identity_count=0
declare -A seen_consumers=()
for id in "${registry_ids[@]}"; do
  [[ "$id" =~ ^[a-z][a-z0-9-]*$ ]] ||
    fail "Refusing: malformed identity name '$id' in $registry_file."
  status="$(yq -r ".identities[\"$id\"].status // \"\"" "$registry_file")"
  case "$status" in
    active)
      credential="$(yq -r ".identities[\"$id\"].credential // \"\"" "$registry_file")"
      consumer="$(yq -r ".identities[\"$id\"].consumer // \"\"" "$registry_file")"
      [[ "$credential" =~ ^(password|token)$ ]] ||
        fail "Refusing: identity '$id' has invalid credential '$credential' (password|token)."
      [[ "$consumer" =~ ^(none|alertmanager-auth|seerr-api|homepage-secret)$ ]] ||
        fail "Refusing: identity '$id' has invalid consumer '$consumer'."
      if [[ "$credential" == 'password' ]]; then
        [[ "$consumer" == 'none' ]] ||
          fail "Refusing: password identity '$id' must have consumer 'none'."
        password_identity_count=$((password_identity_count + 1))
      fi
      if [[ "$consumer" != 'none' ]]; then
        [[ "$credential" == 'token' ]] ||
          fail "Refusing: consumer '$consumer' on identity '$id' requires a token credential."
        [[ -z "${seen_consumers[$consumer]:-}" ]] ||
          fail "Refusing: consumer '$consumer' is claimed by both '${seen_consumers[$consumer]}' and '$id'."
        seen_consumers[$consumer]="$id"
      fi
      acl_count="$(yq -r ".identities[\"$id\"].access | length" "$registry_file" 2>/dev/null || echo 0)"
      [[ "$acl_count" =~ ^[0-9]+$ && "$acl_count" -gt 0 ]] ||
        fail "Refusing: active identity '$id' must declare at least one access entry."
      acls=''
      while IFS= read -r entry; do
        [[ "$entry" =~ ^[a-z][a-z0-9_-]*:(ro|wo|rw)$ ]] ||
          fail "Refusing: identity '$id' has malformed access entry '$entry' (topic:(ro|wo|rw))."
        acls+="${acls:+$'\n'}$entry"
      done < <(yq -r ".identities[\"$id\"].access[] | .topic + \":\" + .permission" "$registry_file")
      reg_credential[$id]="$credential"
      reg_consumer[$id]="$consumer"
      reg_acls[$id]="$acls"
      ;;
    retired)
      extra_keys="$(yq -r "[.identities[\"$id\"] | keys | .[] | select(. != \"status\" and . != \"note\")] | join(\",\")" "$registry_file")"
      [[ -z "$extra_keys" ]] ||
        fail "Refusing: retired identity '$id' may only carry status/note (found: $extra_keys)."
      ;;
    *)
      fail "Refusing: identity '$id' has invalid status '$status' (active|retired)."
      ;;
  esac
  reg_status[$id]="$status"
done
[[ "$password_identity_count" -le 1 ]] ||
  fail 'Refusing: at most one password (human) identity is allowed.'

if [[ "$action" == 'reconcile' ]]; then
  [[ "$identity_arg" == 'all' ]] ||
    fail "Refusing: reconcile applies to the whole registry; use 'reconcile all'."
else
  [[ -n "${reg_status[$identity_arg]:-}" ]] ||
    fail "Refusing: '$identity_arg' is not an identity in $registry_file."
  [[ "${reg_status[$identity_arg]}" == 'active' ]] ||
    fail "Refusing: identity '$identity_arg' is retired; retired identities are only removed by 'reconcile all'."
fi
case "$action" in
  rotate)
    [[ "${reg_credential[$identity_arg]}" == 'token' ]] ||
      fail "Refusing: '$identity_arg' is the human password identity; use 'just repo ntfy-subscriber-password' instead."
    ;;
  finalize)
    [[ "${reg_consumer[$identity_arg]}" == 'seerr-api' ]] ||
      fail 'Refusing: finalize only applies to API-managed (staged rotation) consumers.'
    ;;
esac

# ---------------------------------------------------------------------------
# Guard: a deliberate second operator act, scoped to action + identity + target.
# ---------------------------------------------------------------------------
expected_confirmation="${action}:monitoring:ntfy:${identity_arg}:sops"
[[ "${NTFY_IDENTITY_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo "Refusing to $action the ntfy identity '$identity_arg'." >&2
  echo "Set NTFY_IDENTITY_CONFIRM='$expected_confirmation' after reviewing the target." >&2
  exit 1
}

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-talos-ntfy-identity.XXXXXX")"
trap 'rm -rf -- "$temp_dir"' EXIT
umask 077

# ---------------------------------------------------------------------------
# Credential helpers. Every generated or read secret value is registered in
# sensitive_values so the encrypted outputs can be proven not to contain it.
# ---------------------------------------------------------------------------
declare -a sensitive_values=()

generate_entropy() {
  local entropy
  entropy="$(LC_ALL=C od -An -N32 -tx1 /dev/urandom | tr -d '[:space:]')"
  [[ "$entropy" =~ ^[a-f0-9]{64}$ ]] ||
    fail 'Refusing: could not generate cryptographically random credential material.'
  sensitive_values+=("$entropy")
  printf '%s' "$entropy"
}

generate_hash() {
  local id="$1" line hash
  line="$(printf '%s\n' "$(generate_entropy)" | htpasswd -niBC 10 "$id")"
  hash="${line#*:}"
  [[ "$hash" =~ ^\$2[aby]\$ ]] || fail "Refusing: generated password hash for '$id' is not bcrypt."
  sensitive_values+=("$hash")
  printf '%s' "$hash"
}

generate_token() {
  local token
  token="tk_$(generate_entropy)"
  token="${token:0:32}"
  [[ "$token" =~ ^tk_[a-z0-9]{29}$ ]] ||
    fail 'Refusing: generated token has the wrong format (tk_ + 29 lowercase alphanumerics).'
  sensitive_values+=("$token")
  printf '%s' "$token"
}

# ---------------------------------------------------------------------------
# Current state from the canonical Secret (if present). Entry order within each
# list is preserved exactly for untouched identities.
# ---------------------------------------------------------------------------
declare -A cur_user_entry=() cur_acl_entries=() cur_token_entries=() cur_known=()
auth_users=''
auth_access=''
auth_tokens=''
if [[ -f "$secret_file" ]]; then
  sops --decrypt "$secret_file" >"$temp_dir/current-secret.yaml"
  auth_users="$(yq -r '.stringData.NTFY_AUTH_USERS // ""' "$temp_dir/current-secret.yaml")"
  auth_access="$(yq -r '.stringData.NTFY_AUTH_ACCESS // ""' "$temp_dir/current-secret.yaml")"
  auth_tokens="$(yq -r '.stringData.NTFY_AUTH_TOKENS // ""' "$temp_dir/current-secret.yaml")"
  if [[ -z "$auth_users" || -z "$auth_access" || -z "$auth_tokens" ]]; then
    fail 'Refusing: the existing ntfy Secret does not contain all declarative auth lists.'
  fi

  IFS=',' read -ra entries <<<"$auth_users"
  for entry in "${entries[@]}"; do
    name="${entry%%:*}"
    cur_user_entry[$name]="$entry"
    cur_known[$name]=1
    hash="${entry#*:}"
    sensitive_values+=("${hash%:*}")
  done

  IFS=',' read -ra entries <<<"$auth_access"
  for entry in "${entries[@]}"; do
    name="${entry%%:*}"
    cur_acl_entries[$name]+="${cur_acl_entries[$name]:+$'\n'}$entry"
    cur_known[$name]=1
  done

  IFS=',' read -ra entries <<<"$auth_tokens"
  for entry in "${entries[@]}"; do
    name="${entry%%:*}"
    rest="${entry#*:}"
    cur_token_entries[$name]+="${cur_token_entries[$name]:+$'\n'}$entry"
    cur_known[$name]=1
    sensitive_values+=("${rest%%:*}")
  done
fi

# Reconcile is authoritative: anything present in the Secret but absent from the
# registry must be tombstoned (status: retired) first, never silently dropped.
if [[ "$action" == 'reconcile' ]]; then
  drift=''
  for name in "${!cur_known[@]}"; do
    [[ -n "${reg_status[$name]:-}" ]] || drift+="${drift:+, }$name"
  done
  [[ -z "$drift" ]] ||
    fail "Refusing: the Secret holds identities missing from the registry ($drift). Tombstone them (status: retired) in $registry_file to authorize removal."
fi

# ---------------------------------------------------------------------------
# Desired state for the touched identities. Hashes and tokens carry over;
# credentials are generated only when missing or explicitly rotated.
# ---------------------------------------------------------------------------
declare -A new_user_entry=() new_token_entries=()
declare -a active_ids=() touched_ids=() candidate_ids=()
for id in "${registry_ids[@]}"; do
  [[ "${reg_status[$id]}" == 'active' ]] || continue
  active_ids+=("$id")
done

if [[ "$action" == 'reconcile' ]]; then
  touched_ids=("${active_ids[@]}")
else
  touched_ids=("$identity_arg")
fi

for id in "${touched_ids[@]}"; do
  # User entry: preserve the existing hash, generate one for token identities,
  # and never invent the human-known password.
  if [[ -n "${cur_user_entry[$id]:-}" ]]; then
    new_user_entry[$id]="${cur_user_entry[$id]}"
  elif [[ "${reg_credential[$id]}" == 'token' ]]; then
    new_user_entry[$id]="$id:$(generate_hash "$id"):user"
  else
    fail "Refusing: no existing password hash for '$id'. Run 'just repo ntfy-subscriber-password' first; reconciliation never invents the human-known password."
  fi

  # Token entries.
  if [[ "${reg_credential[$id]}" == 'token' ]]; then
    if [[ "$action" == 'rotate' && "$id" == "$identity_arg" ]]; then
      new_token="$(generate_token)"
      if [[ "${reg_consumer[$id]}" == 'seerr-api' ]]; then
        # Staged rotation: keep the current token valid, stage the pending one.
        while IFS= read -r entry; do
          [[ -n "$entry" && "$entry" != *':pending' ]] || continue
          new_token_entries[$id]+="${new_token_entries[$id]:+$'\n'}$entry"
        done <<<"${cur_token_entries[$id]:-}"
        new_token_entries[$id]+="${new_token_entries[$id]:+$'\n'}$id:$new_token:pending"
      else
        new_token_entries[$id]="$id:$new_token"
      fi
    elif [[ "$action" == 'finalize' && "$id" == "$identity_arg" ]]; then
      pending_entry=''
      while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        if [[ "$entry" == *':pending' ]]; then
          [[ -z "$pending_entry" ]] || fail "Refusing: identity '$id' has multiple pending tokens."
          pending_entry="$entry"
        fi
      done <<<"${cur_token_entries[$id]:-}"
      [[ -n "$pending_entry" ]] ||
        fail "Refusing: identity '$id' has no pending token; run 'just repo ntfy-identity rotate $id' first."
      pending_token="${pending_entry#*:}"
      pending_token="${pending_token%:*}"
      sensitive_values+=("$pending_token")
      new_token_entries[$id]="$id:$pending_token"
    else
      if [[ -n "${cur_token_entries[$id]:-}" ]]; then
        new_token_entries[$id]="${cur_token_entries[$id]}"
      else
        new_token_entries[$id]="$id:$(generate_token)"
      fi
    fi
  fi
done

# ---------------------------------------------------------------------------
# Build the canonical lists: identities in alphabetical order, entries within an
# identity in registry order (ACLs) or provisioned order (tokens). Surgical
# actions keep every untouched identity's entries exactly as they were.
# ---------------------------------------------------------------------------
declare -A list_user=() list_acls=() list_tokens=()
if [[ "$action" == 'reconcile' ]]; then
  candidate_ids=("${active_ids[@]}")
  for id in "${candidate_ids[@]}"; do
    list_user[$id]="${new_user_entry[$id]}"
    while IFS= read -r acl; do
      [[ -n "$acl" ]] || continue
      list_acls[$id]+="${list_acls[$id]:+$'\n'}$id:$acl"
    done <<<"${reg_acls[$id]}"
    list_tokens[$id]="${new_token_entries[$id]:-}"
  done
else
  declare -A surgical=()
  for id in "${!cur_known[@]}"; do
    surgical[$id]=1
  done
  surgical[$identity_arg]=1
  mapfile -t candidate_ids < <(printf '%s\n' "${!surgical[@]}" | LC_ALL=C sort)
  for id in "${candidate_ids[@]}"; do
    if [[ "$id" == "$identity_arg" ]]; then
      list_user[$id]="${new_user_entry[$id]}"
      # Registry ACLs are authoritative for the touched identity.
      while IFS= read -r acl; do
        [[ -n "$acl" ]] || continue
        list_acls[$id]+="${list_acls[$id]:+$'\n'}$id:$acl"
      done <<<"${reg_acls[$id]}"
      list_tokens[$id]="${new_token_entries[$id]:-}"
    else
      list_user[$id]="${cur_user_entry[$id]:-}"
      list_acls[$id]="${cur_acl_entries[$id]:-}"
      list_tokens[$id]="${cur_token_entries[$id]:-}"
    fi
  done
fi

new_auth_users=''
new_auth_access=''
new_auth_tokens=''
for id in "${candidate_ids[@]}"; do
  [[ -z "${list_user[$id]:-}" ]] || new_auth_users+="${new_auth_users:+,}${list_user[$id]}"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    new_auth_access+="${new_auth_access:+,}$entry"
  done <<<"${list_acls[$id]:-}"
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    new_auth_tokens+="${new_auth_tokens:+,}$entry"
  done <<<"${list_tokens[$id]:-}"
done

current_token_for() { # <identity> -> first non-pending token from the OUTPUT lists
  local id="$1" entry token=''
  while IFS= read -r entry; do
    [[ -n "$entry" && "$entry" != *':pending' ]] || continue
    token="${entry#*:}"
    token="${token%%:*}"
    break
  done <<<"${list_tokens[$id]:-}"
  printf '%s' "$token"
}

# The adapter consumes the alertmanager-auth identity through an auth.yml key
# embedded in the same canonical Secret (same namespace). Without that identity,
# the existing key is carried over untouched.
new_auth_yml=''
if [[ -f "$secret_file" ]] &&
  yq -e '.stringData["auth.yml"]' "$temp_dir/current-secret.yaml" >/dev/null 2>&1; then
  yq -r '.stringData["auth.yml"]' "$temp_dir/current-secret.yaml" >"$temp_dir/auth.yml.current"
  new_auth_yml="$temp_dir/auth.yml.current"
fi
if [[ -n "${seen_consumers[alertmanager-auth]:-}" ]]; then
  am_id="${seen_consumers[alertmanager-auth]}"
  if [[ -n "${reg_status[$am_id]:-}" && "${reg_status[$am_id]}" == 'active' ]]; then
    am_token="$(current_token_for "$am_id")"
    if [[ -n "$am_token" ]]; then
      sensitive_values+=("$am_token")
      AM_TOKEN="$am_token" yq -n '.ntfy.auth.token = strenv(AM_TOKEN)' >"$temp_dir/auth.yml"
      new_auth_yml="$temp_dir/auth.yml"
    fi
  elif [[ "$action" == 'reconcile' ]]; then
    new_auth_yml='' # retired consumer: reconcile drops the key as well.
  fi
fi

# Homepage token mirror (cross-namespace copy), only for the homepage-secret consumer.
homepage_token=''
if [[ -n "${seen_consumers[homepage-secret]:-}" ]]; then
  hp_id="${seen_consumers[homepage-secret]}"
  if [[ -n "${reg_status[$hp_id]:-}" && "${reg_status[$hp_id]}" == 'active' ]]; then
    homepage_token="$(current_token_for "$hp_id")"
    [[ -n "$homepage_token" ]] && sensitive_values+=("$homepage_token")
  fi
fi

# ---------------------------------------------------------------------------
# Change detection against the decrypted current state.
# ---------------------------------------------------------------------------
old_auth_yml=''
[[ -f "$temp_dir/auth.yml.current" ]] && old_auth_yml="$(cat "$temp_dir/auth.yml.current")"
new_auth_yml_content=''
[[ -n "$new_auth_yml" ]] && new_auth_yml_content="$(cat "$new_auth_yml")"

changed_secret=true
if [[ -f "$secret_file" &&
  "$new_auth_users" == "$auth_users" &&
  "$new_auth_access" == "$auth_access" &&
  "$new_auth_tokens" == "$auth_tokens" &&
  "$new_auth_yml_content" == "$old_auth_yml" ]]; then
  changed_secret=false
fi

changed_homepage=false
if [[ -n "$homepage_token" ]]; then
  changed_homepage=true
  if [[ -f "$homepage_secret_file" ]]; then
    sops --decrypt "$homepage_secret_file" >"$temp_dir/current-homepage.yaml"
    current_homepage_token="$(yq -r '.stringData.token // ""' "$temp_dir/current-homepage.yaml")"
    [[ -n "$current_homepage_token" ]] && sensitive_values+=("$current_homepage_token")
    [[ "$current_homepage_token" != "$homepage_token" ]] || changed_homepage=false
  fi
fi

if [[ "$changed_secret" == false && "$changed_homepage" == false ]]; then
  echo "ntfy credentials for '$identity_arg' are already synchronized; nothing to do."
  exit 0
fi

# ---------------------------------------------------------------------------
# Build, encrypt, and verify every output before replacing any tracked file.
# ---------------------------------------------------------------------------
expected_recipient="$(yq -r '.creation_rules[1].age' "$sops_policy_file")"
verify_encrypted() {
  local candidate="$1" value
  [[ "$(sops filestatus "$candidate" | yq -r '.encrypted')" == 'true' ]] ||
    fail "Refusing: $candidate is not SOPS-encrypted."
  [[ "$(yq -r '.sops.age[].recipient' "$candidate" | sort -u)" == "$expected_recipient" ]] ||
    fail "Refusing: $candidate is not encrypted to this repository's age recipient."
  for value in "${sensitive_values[@]}"; do
    if rg -Fq -- "$value" "$candidate"; then
      echo "Refusing: a plaintext credential appears in $candidate." >&2
      exit 1
    fi
  done
}

declare -a pending_moves=()
if [[ "$changed_secret" == true ]]; then
  AUTH_USERS="$new_auth_users" AUTH_ACCESS="$new_auth_access" AUTH_TOKENS="$new_auth_tokens" \
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
  if [[ -n "$new_auth_yml" ]]; then
    AUTH_YML_FILE="$new_auth_yml" \
      yq -i '.stringData["auth.yml"] = load_str(strenv(AUTH_YML_FILE))' "$temp_dir/ntfy-secret.yaml"
  fi
  sops --encrypt --filename-override "$secret_file" \
    "$temp_dir/ntfy-secret.yaml" >"$temp_dir/ntfy-secret.sops.yaml"
  verify_encrypted "$temp_dir/ntfy-secret.sops.yaml"
  pending_moves+=("$temp_dir/ntfy-secret.sops.yaml:$secret_file")
fi

if [[ "$changed_homepage" == true ]]; then
  HP_TOKEN="$homepage_token" yq -n '
    .apiVersion = "v1" |
    .kind = "Secret" |
    .metadata.name = "homepage-ntfy" |
    .metadata.namespace = "homepage" |
    .type = "Opaque" |
    .stringData.token = strenv(HP_TOKEN)' \
    >"$temp_dir/homepage-ntfy.yaml"
  sops --encrypt --filename-override "$homepage_secret_file" \
    "$temp_dir/homepage-ntfy.yaml" >"$temp_dir/homepage-ntfy.sops.yaml"
  verify_encrypted "$temp_dir/homepage-ntfy.sops.yaml"
  pending_moves+=("$temp_dir/homepage-ntfy.sops.yaml:$homepage_secret_file")
fi

# Install atomically; restore already-installed originals if a later move fails.
declare -a installed=()
for move in "${pending_moves[@]}"; do
  candidate="${move%%:*}"
  target="${move#*:}"
  if [[ -f "$target" ]]; then
    cp -- "$target" "$temp_dir/backup-$(basename "$target")"
  fi
  if ! mv -- "$candidate" "$target"; then
    for done_move in "${installed[@]}"; do
      done_target="${done_move#*:}"
      if [[ -f "$temp_dir/backup-$(basename "$done_target")" ]]; then
        cp -- "$temp_dir/backup-$(basename "$done_target")" "$done_target"
      fi
    done
    fail "Refusing: installing $target failed; restored previously installed originals."
  fi
  installed+=("$move")
done

# Stamp every credential consumer's pod-template hash so rotations restart them:
# the ntfy pod (env), the alertmanager adapter (mounted auth.yml from the same
# Secret), and the Homepage pod (its own Secret).
if [[ "$changed_secret" == true ]]; then
  revision="$(git hash-object "$secret_file")"
  REV="$revision" yq -i '.controllers.ntfy.pod.annotations.sops-hash = strenv(REV)' "$values_file"
  REV="$revision" yq -i '.controllers["alertmanager-ntfy"].pod.annotations["sops-hash"] = strenv(REV)' "$adapter_values_file"
  echo "Updated encrypted $secret_file; stamped sops-hash in the ntfy and alertmanager-ntfy values."
fi
if [[ "$changed_homepage" == true ]]; then
  revision="$(git hash-object "$homepage_secret_file")"
  REV="$revision" yq -i '.spec.template.metadata.annotations["sops-hash"] = strenv(REV)' "$homepage_deployment_file"
  echo "Updated encrypted $homepage_secret_file; stamped sops-hash in the Homepage deployment."
fi

case "$action" in
  rotate)
    if [[ "${reg_consumer[$identity_arg]}" == 'seerr-api' ]]; then
      echo "Staged a pending token for '$identity_arg'; run 'just kube ntfy-consumer-sync $identity_arg' to test and synchronize it, then 'just repo ntfy-identity finalize $identity_arg' to revoke the previous token."
    else
      echo "Rotated the '$identity_arg' token; commit and let Flux reconcile to roll every credential consumer."
    fi
    ;;
  finalize)
    echo "Finalized '$identity_arg': the pending token is now the only provisioned token; the previous token is revoked once Flux reconciles."
    ;;
  *)
    echo "ntfy identity lifecycle '$action' completed for '$identity_arg'."
    ;;
esac
