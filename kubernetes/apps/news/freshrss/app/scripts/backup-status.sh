#!/bin/sh
# Reconstruct status from completed artifacts after helper restart or retention.
set -eu
umask 077
: "${BACKUP_DIR:?}"
exec 9>/run/news/backup-owner.lock
flock -n 9 || exit 0
latest=0
for set_dir in "$BACKUP_DIR"/set-*; do
    [ -d "$set_dir" ] && [ ! -L "$set_dir" ] || continue
    stamp=$(sed -n 's/^created_epoch=\([0-9]*\)$/\1/p' "$set_dir/manifest" 2>/dev/null) || continue
    case "$stamp" in ''|*[!0-9]*) continue;; esac
    [ "$stamp" -gt "$latest" ] && [ "$stamp" -le "$(date +%s)" ] || continue
    # Validation is read-only. Only this coordinator needs the owner lease;
    # a timeout watchdog must not retain it after validation finishes.
    if timeout -s TERM -k 10 180 sh /opt/news/validate-backup.sh "$set_dir" 9>&- >/dev/null 2>&1; then
        latest=$stamp
    fi
done
printf '%s\n' "$latest" > /run/news/last-backup.pending
mv /run/news/last-backup.pending /run/news/last-backup
