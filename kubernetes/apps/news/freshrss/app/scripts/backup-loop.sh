#!/bin/sh
set -eu
umask 077
: "${BACKUP_DIR:?}"
while :; do
    if [ -f /run/news/initialized ]; then
        timeout -s TERM -k 10 600 sh /opt/news/backup-status.sh || true
        latest=$(cat /run/news/last-backup 2>/dev/null || echo 0)
        if [ "$(( $(date +%s) - latest ))" -ge 86400 ]; then
            sh /opt/news/backup.sh || true
        fi
    fi
    sleep 3600
done
