#!/bin/sh
# Hash the actual mounted release and extension bytes, never just their names.
set -eu
root=/opt/news-extraction
[ -f "$root/release.json" ]
id=$(sed -n 's/^  "id": "\([a-f0-9]\{64\}\)"[,]*$/\1/p' "$root/release.json")
[ "${#id}" -eq 64 ]
entries=$(awk -F '"' '
    /^  "extension_files": \{/ { inside=1; next }
    inside && /^  \}/ { inside=0; next }
    inside { print $2 " " $4 }
' "$root/release.json")
[ -n "$entries" ]
count=0
while read -r file expected; do
    case "$file" in ''|*[!A-Za-z0-9_.-]*) exit 1;; esac
    [ "${#expected}" -eq 64 ]
    [ -f "$root/extension/$file" ]
    actual=$(sha256sum "$root/extension/$file")
    [ "${actual%% *}" = "$expected" ]
    count=$((count + 1))
    [ "$count" -le 64 ]
done <<EOF
$entries
EOF
case "${1:-}" in
    id) printf '%s\n' "$id" ;;
    hash) LC_ALL=C sha256sum "$root/release.json" "$root"/extension/* | sha256sum | cut -d ' ' -f 1 ;;
    *) echo 'Usage: extraction-inputs.sh id|hash' >&2; exit 2 ;;
esac
