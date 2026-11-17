#!/usr/bin/env bash
# Write the SOPS-encrypted specification 036 session sweeper Secret with a newly
# generated password and select it in the PostgreSQL package. The password exists in
# plaintext only inside this process and a private temporary file.
set -euo pipefail

expected_confirmation='write:automation-data:session-sweeper:sops'
app='kubernetes/apps/automation-data/postgresql/app'
target="$app/session-sweeper-credentials.sops.yaml"
kustomization="$app/kustomization.yaml"
resource_entry='  - ./session-sweeper-credentials.sops.yaml'
[[ "${AUTOMATION_DATA_SESSION_SWEEPER_SECRET_CONFIRM:-}" == "$expected_confirmation" ]] || {
  echo 'Refusing to write the automation-data session sweeper Secret.' >&2
  echo "Set AUTOMATION_DATA_SESSION_SWEEPER_SECRET_CONFIRM='$expected_confirmation' after reviewing the target." >&2
  exit 1
}

umask 077
temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/homelab-talos-session-sweeper-secret.XXXXXX")"
committed=false
backup=''
cleanup() {
  local result="$?"
  trap - EXIT
  if [[ "$committed" != true && -n "$backup" ]]; then
    if [[ -e "$backup/secret" ]]; then
      mv -- "$backup/secret" "$target" || result=1
    else
      rm -f -- "$target" || result=1
    fi
    mv -- "$backup/kustomization" "$kustomization" || result=1
  fi
  rm -rf -- "$temp_dir" ${backup:+"$backup"}
  exit "$result"
}
trap cleanup EXIT

just repo secrets
# shellcheck disable=SC2016 # yq expression, not shell expansion.
mapfile -t recipients < <(
  target="$target" yq -r \
    '.creation_rules[] | select(.path_regex as $rule | env(target) | test($rule)) | .age' \
    .sops.yaml
)
[[ "${#recipients[@]}" -eq 1 && -n "${recipients[0]}" && "${recipients[0]}" != null ]] || {
  echo "Unable to select exactly one SOPS age recipient for $target." >&2
  exit 1
}

SWEEPER_PASSWORD="$(openssl rand -hex 32)"
export SWEEPER_PASSWORD
yq -n '
  .apiVersion = "v1" |
  .kind = "Secret" |
  .metadata.name = "automation-data-session-sweeper" |
  .metadata.namespace = "automation-data" |
  .type = "Opaque" |
  .stringData.password = strenv(SWEEPER_PASSWORD)
' >"$temp_dir/plaintext.yaml"
sops --encrypt --filename-override "$target" "$temp_dir/plaintext.yaml" >"$temp_dir/secret"
rm -f -- "$temp_dir/plaintext.yaml"

candidate="$temp_dir/secret"
[[ "$(sops filestatus "$candidate" | yq -r '.encrypted')" == true ]]
[[ "$(yq -r '[.sops.age[].recipient] | unique | join(",")' "$candidate")" == "${recipients[0]}" ]] || {
  echo 'The encrypted Secret does not use the expected recipient.' >&2
  exit 1
}
[[ "$(yq -r '[.apiVersion, .kind, .metadata.name, .metadata.namespace, .type,
  (keys | sort | join(",")), (.metadata | keys | sort | join(",")),
  (.stringData | keys | join(","))] | join("|")' "$candidate")" == \
  'v1|Secret|automation-data-session-sweeper|automation-data|Opaque|apiVersion,kind,metadata,sops,stringData,type|name,namespace|password' ]] || {
  echo 'The encrypted Secret is not the expected shape.' >&2
  exit 1
}
if rg -Fq -- "$SWEEPER_PASSWORD" "$candidate"; then
  echo 'The encrypted Secret contains the plaintext password.' >&2
  exit 1
fi
unset SWEEPER_PASSWORD

# Select the Secret alphabetically before the CronJob that uses it.
cp -- "$kustomization" "$temp_dir/kustomization"
if ! rg -Fxq -- "$resource_entry" "$kustomization"; then
  awk -v entry="$resource_entry" '$0 == "  - ./session-sweeper.yaml" { print entry } { print }' \
    "$kustomization" >"$temp_dir/kustomization"
fi
[[ "$(yq -r '[.resources[] | select(. == "./session-sweeper-credentials.sops.yaml")] | length' \
  "$temp_dir/kustomization")" == 1 ]] || {
  echo "Unable to select the Secret in $kustomization." >&2
  exit 1
}

backup="$(mktemp -d "$app/.session-sweeper-secret.XXXXXX")"
cp -- "$kustomization" "$backup/kustomization"
[[ ! -e "$target" ]] || cp -- "$target" "$backup/secret"
mv -- "$candidate" "$target"
mv -- "$temp_dir/kustomization" "$kustomization"
committed=true
echo "Wrote SOPS-encrypted $target and selected it in $kustomization."
echo 'Commit both files. After Flux applies them, run: just kube automation-data-session-sweeper-enable'
