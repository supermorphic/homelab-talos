#!/usr/bin/env bash

automation_data_permission_restore_helpers() {
	cat <<'EOF'
automation_data_permission_acl_list() { # <archive> <output-list> <private-log>
  archive="$1"
  output_list="$2"
  private_log="$3"
  pg_restore --list "$archive" >"$output_list.all" 2>"$private_log" || return 1
  awk '
    /^[0-9]+; [0-9]+ [0-9]+ (ACL|DEFAULT ACL) / {
      key = $0
      sub(/^[0-9]+; [0-9]+ [0-9]+ /, "", key)
      print key "\t" $0
    }
  ' "$output_list.all" | LC_ALL=C sort | cut -f 2- >"$output_list" || return 1
}

automation_data_permission_object_owners() { # <TOC-list> <output>
  toc_list="$1"
  output="$2"
  awk '
    {
      entry = $0
      if (!sub(/^[0-9]+; [0-9]+ [0-9]+ /, "", entry))
        next
      if (entry ~ /^SCHEMA / ||
          (entry ~ /^TABLE / && entry !~ /^TABLE (ATTACH|DATA) /) ||
          entry ~ /^VIEW / ||
          (entry ~ /^MATERIALIZED VIEW / && entry !~ /^MATERIALIZED VIEW DATA /) ||
          entry ~ /^FOREIGN TABLE / ||
          (entry ~ /^SEQUENCE / && entry !~ /^SEQUENCE (OWNED BY|SET) /) ||
          entry ~ /^FUNCTION / || entry ~ /^PROCEDURE / || entry ~ /^AGGREGATE /)
        print entry
    }
  ' "$toc_list" | LC_ALL=C sort >"$output"
}

automation_data_permission_render_acl() { # <archive> <TOC-list> <output> <private-log>
  archive="$1"
  toc_list="$2"
  output="$3"
  private_log="$4"
  pg_restore --schema-only --use-list="$toc_list" \
    --restrict-key=6175746f6d6174696f6e5f64617461 \
    --file="$output.raw" "$archive" 2>"$private_log" || return 1
  # These exact comments describe tool versions, not restored permission state.
  sed \
    -e '/^-- Dumped from database version /d' \
    -e '/^-- Dumped by pg_dump version /d' \
    "$output.raw" >"$output" || return 1
}

automation_data_compare_restored_permissions_inner() { # <source-archive> <database> <directory>
  source_archive="$1"
  database="$2"
  comparison_dir="$3"
  candidate_archive="$comparison_dir/candidate.dump"
  private_log="$comparison_dir/postgresql.log"

  pg_dump --schema-only --format=custom --compress=0 \
    --file="$candidate_archive" --dbname="$database" \
    >"$private_log" 2>&1 || return 1
  automation_data_permission_acl_list "$source_archive" \
    "$comparison_dir/source-acl.list" "$private_log" || return 1
  automation_data_permission_acl_list "$candidate_archive" \
    "$comparison_dir/candidate-acl.list" "$private_log" || return 1
  automation_data_permission_render_acl "$source_archive" \
    "$comparison_dir/source-acl.list" "$comparison_dir/source-acl.sql" \
    "$private_log" || return 1
  automation_data_permission_render_acl "$candidate_archive" \
    "$comparison_dir/candidate-acl.list" "$comparison_dir/candidate-acl.sql" \
    "$private_log" || return 1
  cmp -s "$comparison_dir/source-acl.sql" "$comparison_dir/candidate-acl.sql" || return 1

  automation_data_permission_object_owners "$comparison_dir/source-acl.list.all" \
    "$comparison_dir/source-owners" || return 1
  automation_data_permission_object_owners "$comparison_dir/candidate-acl.list.all" \
    "$comparison_dir/candidate-owners" || return 1
  cmp -s "$comparison_dir/source-owners" "$comparison_dir/candidate-owners" || return 1
}

automation_data_compare_restored_permissions() { # <source-archive> <database>
  source_archive="$1"
  database="$2"
  umask 077
  comparison_dir="$(mktemp -d /tmp/restore-permission.XXXXXX 2>/dev/null)" || return 1
  comparison_status=0
  automation_data_compare_restored_permissions_inner \
    "$source_archive" "$database" "$comparison_dir" >/dev/null 2>&1 || comparison_status=1
  rm -rf -- "$comparison_dir" >/dev/null 2>&1 || comparison_status=1
  return "$comparison_status"
}
EOF
}
