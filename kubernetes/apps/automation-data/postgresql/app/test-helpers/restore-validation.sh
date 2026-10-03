restore_fail() {
  printf 'restore_failure=%s\n' "$1" >&2
  exit 1
}

validate_bundle() {
  candidate="$1"
  test -d "$candidate" -a ! -L "$candidate" || return 1
  candidate_name="$(basename "$candidate")"
  printf '%s\n' "$candidate_name" | grep -Eq '^automation-data-[0-9]{8}T[0-9]{6}Z$' || return 1
  test -s "$candidate/globals.sql" -a -s "$candidate/registry.tsv" -a \
    -s "$candidate/manifest.tsv" -a -s "$candidate/SHA256SUMS" -a \
    -s "$candidate/COMPLETE" || return 1
  (cd "$candidate" && sha256sum -c SHA256SUMS >/dev/null 2>&1 && \
    sha256sum -c COMPLETE >/dev/null 2>&1) || return 1

  awk 'NF == 2 {print $2}' "$candidate/SHA256SUMS" | LC_ALL=C sort -u \
    > /tmp/restore-listed-files
  {
    cat /tmp/restore-listed-files
    printf '%s\n' COMPLETE SHA256SUMS
  } | LC_ALL=C sort -u > /tmp/restore-expected-files
  (cd "$candidate" && find . -type f -print | sed 's#^./##' | LC_ALL=C sort -u) \
    > /tmp/restore-actual-files
  cmp -s /tmp/restore-expected-files /tmp/restore-actual-files || return 1

  test "$(sed -n '1p' "$candidate/manifest.tsv")" = \
    "$(printf 'bundle_version\t1')" || return 1
  test "$(sed -n '5p' "$candidate/manifest.tsv")" = \
    "$(printf 'record_type\tdatabase_name_base64\tdump_path')" || return 1
  awk -F '\t' '$1 == "database" {print $3}' "$candidate/manifest.tsv" |
    LC_ALL=C sort -u > /tmp/restore-manifest-dumps
  find "$candidate/databases" -maxdepth 1 -type f -name 'db-*.dump' -print |
    sed "s#^$candidate/##" | LC_ALL=C sort -u > /tmp/restore-actual-dumps
  test -s /tmp/restore-manifest-dumps || return 1
  cmp -s /tmp/restore-manifest-dumps /tmp/restore-actual-dumps || return 1

  : > /tmp/restore-databases-base64
  while IFS="$(printf '\t')" read -r record encoded dump_path extra; do
    test "$record" = database || continue
    test -n "$encoded" -a -n "$dump_path" -a -z "${extra:-}" || return 1
    printf '%s\n' "$dump_path" | grep -Eq '^databases/db-[A-Za-z0-9_-]+\.dump$' || return 1
    database_with_sentinel="$(printf '%s' "$encoded" | base64 -d 2>/dev/null; printf x)" || return 1
    database_name="${database_with_sentinel%x}"
    test -n "$database_name" || return 1
    printf '%s\n' "$encoded" >> /tmp/restore-databases-base64
    pg_restore --list "$candidate/$dump_path" >/dev/null 2>&1 || return 1
  done < "$candidate/manifest.tsv"
  LC_ALL=C sort -u /tmp/restore-databases-base64 > /tmp/restore-databases-base64.sorted
  test "$(wc -l < /tmp/restore-databases-base64 | tr -d ' ')" = \
    "$(wc -l < /tmp/restore-databases-base64.sorted | tr -d ' ')" || return 1
  mv /tmp/restore-databases-base64.sorted /tmp/restore-databases-base64
  return 0
}
