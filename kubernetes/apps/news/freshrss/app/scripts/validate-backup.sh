#!/bin/sh
# Validate the complete recovery unit before publication or any target mutation.
set -eu
set_dir=${1:?backup set required}
[ -d "$set_dir" ] && [ ! -L "$set_dir" ]
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
for file in database.dump data.tar.gz manifest SHA256SUMS; do
    [ -f "$set_dir/$file" ] && [ ! -L "$set_dir/$file" ]
done
[ "$(find "$set_dir" -mindepth 1 -maxdepth 1 | wc -l)" -eq 4 ]
awk '
    NF != 2 || length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { exit 1 }
    $2 != "database.dump" && $2 != "data.tar.gz" && $2 != "manifest" { exit 1 }
    seen[$2]++ { exit 1 }
    END { if (NR != 3) exit 1 }
' "$set_dir/SHA256SUMS"
(cd "$set_dir" && sha256sum -c SHA256SUMS >/dev/null)
awk -F= '
    $1 == "format" && $2 == "news-paired-v1" { seen[$1]++; next }
    $1 == "created_epoch" && $2 ~ /^[0-9]+$/ { seen[$1]++; next }
    ($1 == "app_image" || $1 == "database_image") && $2 ~ /^[A-Za-z0-9_.:\/@-]+$/ { seen[$1]++; next }
    $1 == "config_sha256" && length($2) == 64 && $2 ~ /^[0-9a-f]+$/ { seen[$1]++; next }
    { exit 1 }
    END { if (NR != 5 || length(seen) != 5) exit 1 }
' "$set_dir/manifest"
# Decode every dump block, not just its table of contents.
pg_restore --file=/dev/null "$set_dir/database.dump"
tar -tzf "$set_dir/data.tar.gz" > "$scratch/names"
tar -tvzf "$set_dir/data.tar.gz" > "$scratch/types"
awk '
    /^\// || /(^|\/)\.\.(\/|$)/ || /[[:cntrl:]]/ { exit 1 }
    END { if (NR == 0) exit 1 }
' "$scratch/names"
# Do not let restore follow archive symlinks, hard links or special devices.
awk 'substr($0,1,1) != "-" && substr($0,1,1) != "d" { exit 1 }' "$scratch/types"
grep -qx './config.php' "$scratch/names"
grep -qx './news-bootstrap.complete' "$scratch/names"
