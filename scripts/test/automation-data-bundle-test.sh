#!/usr/bin/env bash
set -euo pipefail

# A corrupt bundle must identify the failed check without exposing its contents.
test_root="$(mktemp -d "${TMPDIR:-/tmp}/automation-data-bundle-test.XXXXXX")"
trap 'rm -rf -- "$test_root"' EXIT
helper='scripts/test/lib/automation-data-bundle.sh'
bundle="$test_root/backups/automation-data-20260908T000000Z"
mkdir -p "$bundle" "$test_root/scratch"
export TMPDIR="$test_root/scratch"
export EXPECTED_DATABASE_SET_BASE64=Y0c5emRHZHlaWE09Cg==
printf 'database\tcG9zdGdyZXM=\tdump\n' >"$bundle/manifest.tsv"
printf 'issue317_backup_error\tdb\towner\tmigrator\truntime\terror\tfalse\t1\t\t\t\t\tstart\tupdated\tacceptance_backup_error\n' >"$bundle/registry.tsv"

seal() {
  (cd "$bundle" && sha256sum manifest.tsv registry.tsv >SHA256SUMS && sha256sum SHA256SUMS >COMPLETE)
}
check() {
  local expected_status="$1" expected_output="$2" status=0 output
  output="$(sh "$helper" "$test_root/backups" 2>&1)" || status="$?"
  [[ "$status" == "$expected_status" && "$output" == "$expected_output" ]] || {
    printf 'Bundle check failed: expected status %s and %s; got status %s and %s\n' \
      "$expected_status" "$expected_output" "$status" "$output" >&2
    exit 1
  }
}
seal
check 0 'bundle_valid=true database_count=1 error_record=present'
printf 'DO_NOT_EXPOSE\n' >>"$bundle/registry.tsv"
check 1 'bundle_check_failed=checksums'
seal
check 1 'bundle_check_failed=registry_format'
printf '%s' 'issue317_backup_error\tdb\towner\tmigrator\truntime\terror\tfalse\t1\t\t\t\t\tstart\tupdated\tacceptance_backup_error' >"$bundle/registry.tsv"
seal
check 1 'bundle_check_failed=registry_format'
printf 'other\tdb\towner\tmigrator\truntime\terror\tfalse\t1\t\t\t\t\tstart\tupdated\tacceptance_backup_error\n' >"$bundle/registry.tsv"
seal
check 1 'bundle_check_failed=error_record'
export EXPECTED_DATABASE_SET_BASE64=b3RoZXIK
check 1 'bundle_check_failed=database_inventory'
rm "$bundle/COMPLETE"
check 1 'bundle_check_failed=required_files'
printf 'Automation-data bundle diagnostic tests passed.\n'
