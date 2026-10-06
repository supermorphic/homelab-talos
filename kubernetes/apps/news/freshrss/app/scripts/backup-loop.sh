#!/bin/sh
set -eu
umask 077
: "${BACKUP_DIR:?}"
while :; do
    if [ -f /run/news/initialized ]; then
        latest=0
        for set_dir in "$BACKUP_DIR"/set-*; do
            [ -f "$set_dir/manifest" ] || continue
            stamp=$(sed -n 's/^created_epoch=\([0-9]*\)$/\1/p' "$set_dir/manifest")
            case "$stamp" in ''|*[!0-9]*) continue;; esac
            [ "$stamp" -le "$latest" ] || latest=$stamp
        done
        if [ "$(( $(date +%s) - latest ))" -ge 86400 ]; then
            sh /opt/news/backup.sh || true
        fi
    fi
    sleep 3600
done
