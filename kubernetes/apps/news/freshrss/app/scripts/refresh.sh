#!/bin/sh
set -eu
case "${NEWS_POLLING_ENABLED-true}" in
    true) ;;
    false) exit 0 ;;
    *) echo 'NEWS_POLLING_ENABLED must be true or false' >&2; exit 2 ;;
esac
exec 8>/run/news/service.lock
if ! flock -sn 8; then
    echo 'FreshRSS refresh skipped: service lock busy' >&2
    exit 0
fi
if [ -e /run/news/maintenance-request ]; then
    echo 'FreshRSS refresh skipped: maintenance requested' >&2
    exit 0
fi
# A single lock bounds scheduler/manual refresh concurrency and future maintenance.
exec 9>/run/news/refresh.lock
if ! flock -n 9; then
    echo 'FreshRSS refresh skipped: refresh lock busy' >&2
    exit 0
fi
echo 'FreshRSS refresh started' >&2
NEWS_REFRESH_DEADLINE=$(( $(date +%s) + 300 ))
export NEWS_REFRESH_DEADLINE
if timeout -s TERM -k 10 300 php /var/www/FreshRSS/app/actualize_script.php >/dev/null 2>&1; then
    date +%s > /run/news/last-refresh
    echo 'FreshRSS refresh completed' >&2
else
    echo 'FreshRSS refresh failed or exceeded its time budget' >&2
    exit 1
fi
