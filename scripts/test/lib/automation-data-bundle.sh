#!/bin/sh
# Read-only bundle acceptance. Emit only fixed diagnostics, never artifact contents.
set -eu
fail() { printf 'bundle_check_failed=%s\n' "$1" >&2; exit 1; }
root="${1:-/backups}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/bundle-check.XXXXXX")" || fail scratch
trap 'rm -rf -- "$scratch"' EXIT
bundle="$(find "$root" -mindepth 1 -maxdepth 1 -type d -name 'automation-data-*' | LC_ALL=C sort | tail -n 1)"
[ -n "$bundle" ] || fail bundle_missing
for file in COMPLETE SHA256SUMS manifest.tsv registry.tsv; do
  [ -s "$bundle/$file" ] || fail required_files
done
(cd "$bundle" && sha256sum -c SHA256SUMS >/dev/null 2>&1 && sha256sum -c COMPLETE >/dev/null 2>&1) || fail checksums
printf %s "${EXPECTED_DATABASE_SET_BASE64:-}" | base64 -d >"$scratch/expected" 2>/dev/null || fail expected_inventory
[ -s "$scratch/expected" ] || fail expected_inventory
awk -F '\t' '$1 == "database" {print $2}' "$bundle/manifest.tsv" | LC_ALL=C sort -u >"$scratch/actual"
cmp -s "$scratch/expected" "$scratch/actual" || fail database_inventory
awk -F '\t' 'NF != 15 {bad=1} END {exit (bad || NR == 0)}' "$bundle/registry.tsv" || fail registry_format
awk -F '\t' '$1 == "issue317_backup_error" && $6 == "error" && $15 == "acceptance_backup_error" {found=1} END {exit !found}' "$bundle/registry.tsv" || fail error_record
database_count="$(wc -l <"$scratch/actual" | tr -d ' ')"
printf 'bundle_valid=true database_count=%s error_record=present\n' "$database_count"
