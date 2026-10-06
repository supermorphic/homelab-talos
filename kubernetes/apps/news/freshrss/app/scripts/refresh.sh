#!/bin/sh
set -eu
exec 8>/run/news/service.lock
flock -sn 8 || exit 0
[ ! -e /run/news/maintenance-request ] || exit 0
# A single lock bounds scheduler/manual refresh concurrency and future maintenance.
exec 9>/run/news/refresh.lock
flock -n 9 || exit 0
if timeout -s TERM -k 10 300 php /var/www/FreshRSS/app/actualize_script.php >/dev/null 2>&1; then
    date +%s > /run/news/last-refresh
else
    echo 'FreshRSS refresh failed or exceeded its time budget' >&2
    exit 1
fi
