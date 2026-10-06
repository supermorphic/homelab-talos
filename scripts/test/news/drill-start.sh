#!/bin/sh
set -eu
phase=${1:?source or restored required}
case "$phase" in source|restored) ;; *) exit 2;; esac
if [ "$phase" = restored ]; then
    deadline=$(( $(date +%s) + 660 ))
    while [ ! -f /run/news/restore-complete ]; do
        [ "$(date +%s)" -lt "$deadline" ] || exit 1
        sleep 1
    done
fi
mkdir -p "$DATA_PATH"
deadline=$(( $(date +%s) + 120 ))
# PHP reads its own environment; shell expansion would expose credentials.
# shellcheck disable=SC2016
while ! php -r 'try { $db = new PDO("pgsql:host=127.0.0.1;dbname=freshrss;connect_timeout=5", "freshrss", getenv("NEWS_DB_PASSWORD")); $db->query("SELECT 1"); } catch (Throwable $e) { exit(1); }' >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || exit 1
    sleep 1
done
exec sh /opt/news/start.sh
