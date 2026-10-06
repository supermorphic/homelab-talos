#!/bin/sh
set -eu
# Bound the complete pause, including drain, capture, validation and retention.
if [ "${1:-}" != --worker ]; then
    exec timeout -s TERM -k 10 600 sh "$0" --worker
fi
umask 077
: "${DATA_PATH:?}" "${BACKUP_DIR:?}" "${NEWS_APP_IMAGE:?}" "${NEWS_DATABASE_IMAGE:?}"
export PGCONNECT_TIMEOUT=5
export PGOPTIONS='-c statement_timeout=300000'
exec 9>/run/news/backup-owner.lock
flock -n 9 || exit 0
stage=''
cleanup() {
    status=$?
    trap - EXIT TERM INT
    rm -f /run/news/maintenance-request
    [ -z "$stage" ] || rm -rf "$stage"
    if [ "$status" -ne 0 ]; then
        echo 'News paired backup failed; no incomplete set was published' >&2
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' TERM INT
[ -f /run/news/initialized ]
: > /run/news/maintenance-request
exec 8>/run/news/service.lock
timeout -s TERM -k 10 360 flock 8
[ -f "$DATA_PATH/news-bootstrap.complete" ]
mkdir -p "$BACKUP_DIR"
# Both locks prove no capture worker can still write an abandoned staging set.
for pending in "$BACKUP_DIR"/.pending-[0-9]*-*; do
    [ -d "$pending" ] && [ ! -L "$pending" ] || continue
    rm -rf "$pending"
done
stamp=$(date +%s)
stage=$(mktemp -d "$BACKUP_DIR/.pending-$stamp-XXXXXX")
# Credentials and private content must never reach container logs.
timeout -s TERM -k 10 180 pg_dump --format=custom --no-owner --no-privileges --lock-wait-timeout=10000 \
    --file="$stage/database.dump" >/dev/null 2>&1
timeout -s TERM -k 10 180 tar -czf "$stage/data.tar.gz" -C "$DATA_PATH" . >/dev/null 2>&1
config_hash=$(cat /opt/news/* /opt/news-httpd.conf | sha256sum)
config_hash=${config_hash%% *}
printf 'format=news-paired-v1\ncreated_epoch=%s\napp_image=%s\ndatabase_image=%s\nconfig_sha256=%s\n' \
    "$stamp" "$NEWS_APP_IMAGE" "$NEWS_DATABASE_IMAGE" "$config_hash" > "$stage/manifest"
(cd "$stage" && sha256sum database.dump data.tar.gz manifest > SHA256SUMS)
timeout -s TERM -k 10 180 sh /opt/news/validate-backup.sh "$stage" >/dev/null 2>&1
# The directory rename is the sole completion signal; partial sets stay hidden.
final="$BACKUP_DIR/set-${stage##*/.pending-}"
[ ! -e "$final" ]
mv "$stage" "$final"
stage=''
printf '%s\n' "$stamp" > /run/news/last-backup.pending
mv /run/news/last-backup.pending /run/news/last-backup
rm -f /run/news/maintenance-request
flock -u 8
# Retain seven valid completed sets. Corrupt sets require attended investigation.
for candidate in "$BACKUP_DIR"/set-*; do
    [ -d "$candidate" ] || continue
    if sh /opt/news/validate-backup.sh "$candidate" >/dev/null 2>&1; then
        printf '%s\n' "$candidate"
    fi
done | LC_ALL=C sort -r | awk 'NR > 7' | while IFS= read -r old; do
    rm -rf "$old"
done
echo 'News paired backup complete locally; off-cluster confirmation is separate'
