#!/bin/sh
# shellcheck shell=ash
set -eu
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi

backup_dir="${BACKUP_DIR:-/backups}"
artifact_timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
completed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
final_dump="$backup_dir/n8n-postgresql-$artifact_timestamp.dump"
final_checksum="$final_dump.sha256"
temporary_dump="$backup_dir/.n8n-postgresql-$artifact_timestamp-$$.dump.tmp"
temporary_checksum="$backup_dir/.n8n-postgresql-$artifact_timestamp-$$.dump.sha256.tmp"

pg_dump --format=custom --compress=9 --no-owner --no-privileges \
  --file "$temporary_dump" --dbname "$PGDATABASE"
pg_restore --file /dev/null "$temporary_dump"
checksum_line="$(sha256sum "$temporary_dump")"
checksum="${checksum_line%% *}"
printf '%s  %s\n' "$checksum" "$(basename "$final_dump")" >"$temporary_checksum"
mv -- "$temporary_dump" "$final_dump"
mv -- "$temporary_checksum" "$final_checksum"
(cd "$backup_dir" && sha256sum --check "$(basename "$final_checksum")")
psql --set=ON_ERROR_STOP=1 --set=completed_at="$completed_at" \
  --set=filename="$(basename "$final_dump")" \
  --set=checksum="$checksum" --file /scripts/update-backup-status.sql

# Publication cleanup is deliberately status-gated: failed status writes leave every
# artifact in place for diagnosis and the next successful run.
find "$backup_dir" -maxdepth 1 -type f -name '*.tmp' -exec rm -f -- {} \;
find "$backup_dir" -maxdepth 1 -type f -name '*.dump' -print |
  while IFS= read -r dump; do
    [ -f "$dump.sha256" ] || rm -f -- "$dump"
  done
find "$backup_dir" -maxdepth 1 -type f -name '*.dump.sha256' -print |
  while IFS= read -r checksum_file; do
    dump="${checksum_file%.sha256}"
    [ -f "$dump" ] || rm -f -- "$checksum_file"
  done
find "$backup_dir" -maxdepth 1 -type f -name '*.dump' -print |
  while IFS= read -r dump; do
    checksum_file="$dump.sha256"
    dump_basename="$(basename "$dump")"
    checksum_target="$(awk 'NF == 2 { print $2 }' "$checksum_file")"
    if [ "$checksum_target" != "$dump_basename" ] ||
      ! (cd "$backup_dir" && sha256sum --check "$(basename "$checksum_file")") \
        >/dev/null 2>&1; then
      rm -f -- "$dump" "$checksum_file"
    fi
  done
find "$backup_dir" -maxdepth 1 -type f -name '*.dump' -print |
  LC_ALL=C sort -r |
  awk 'NR > 7 { print }' |
  while IFS= read -r old_dump; do
    rm -f -- "$old_dump" "$old_dump.sha256"
  done
