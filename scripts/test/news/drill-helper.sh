#!/bin/sh
set -eu
umask 077
phase=${1:?source or restored required}
case "$phase" in
capture) touch /run/news/capture-request; exit 0;;
captured) [ -f /run/news/captured-set ] || exit 75; cat /run/news/captured-set; exit 0;;
source|restored) ;; *) exit 2;; esac
export PGCONNECT_TIMEOUT=5 PGOPTIONS='-c statement_timeout=5000'
deadline=$(( $(date +%s) + 120 ))
while ! psql -XAtc 'SELECT 1' >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || exit 1
    sleep 1
done
if [ "$phase" = source ]; then
    deadline=$(( $(date +%s) + 600 ))
    while [ ! -f /run/news/capture-request ]; do
        [ "$(date +%s)" -lt "$deadline" ] || exit 1
        sleep 1
    done
    sh /opt/news/backup.sh
    set -- "$BACKUP_DIR"/set-*
    [ "$#" -eq 1 ] && [ -d "$1" ]
    printf '%s\n' "${1##*/}" > /run/news/captured-set
else
    mkdir -p "$DATA_PATH"
    sh /opt/news/restore.sh "$BACKUP_DIR/$NEWS_SELECTED_SET"
    touch /run/news/restore-complete
fi
# Keep PID1 as a shell, so orphaned bounded-tool children are reaped.
trap 'exit 0' TERM INT
while :; do sleep 1; done
