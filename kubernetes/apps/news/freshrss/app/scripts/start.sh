#!/bin/sh
set -eu
case "${NEWS_POLLING_ENABLED-true}" in
    true|false) ;;
    *) echo 'NEWS_POLLING_ENABLED must be true or false' >&2; exit 2 ;;
esac
umask 077
mkdir -p /run/news /tmp/news-sessions
echo "$$" > /run/news/supervisor.pid
date +%s > /run/news/supervisor-heartbeat
# The helper can capture data only after every application writer releases this.
exec 8>/run/news/service.lock
exec 7>/run/news/backup-owner.lock
flock -s 8
# Kubernetes preserves emptyDir across container restarts. A PID from the old
# container may now identify an unrelated process in the new PID namespace.
if pgrep -x httpd >/dev/null; then
    echo 'FreshRSS startup found an existing HTTP process' >&2
    exit 1
fi
rm -f /run/news/httpd.pid
php /opt/news/bootstrap.php
touch /run/news/initialized

refresh_pid=''
if [ "${NEWS_POLLING_ENABLED-true}" = true ]; then
    (
        exec 8>&- 7>&-
        echo 'FreshRSS scheduler started' >&2
        while sleep 900; do
            sh /opt/news/refresh.sh || true
        done
        echo 'FreshRSS scheduler stopped' >&2
    ) &
    refresh_pid=$!
else
    echo 'FreshRSS scheduler disabled' >&2
fi
web_pid=''
cleanup() {
    trap - TERM INT EXIT
    for pid in ${refresh_pid:+"$refresh_pid"} ${web_pid:+"$web_pid"}; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
}
trap cleanup TERM INT EXIT
while :; do
    httpd -f /opt/news-httpd.conf -D FOREGROUND &
    web_pid=$!
    while kill -0 "$web_pid" 2>/dev/null; do
        date +%s > /run/news/supervisor-heartbeat
        if [ -e /run/news/maintenance-request ]; then
            # Apache closes its listener and drains workers before exiting.
            httpd -f /opt/news-httpd.conf -k graceful-stop >/dev/null 2>&1
            wait "$web_pid"
            web_pid=''
            flock -u 8
            while :; do
                date +%s > /run/news/supervisor-heartbeat
                if flock -sn 8; then
                    if [ ! -e /run/news/maintenance-request ]; then
                        break
                    fi
                    # A dead helper may leave a request. Prove that neither it
                    # nor an inherited worker still owns the backup operation.
                    if flock -n 7; then
                        rm -f /run/news/maintenance-request
                        flock -u 7
                        break
                    fi
                    flock -u 8
                fi
                sleep 1
            done
            break
        fi
        sleep 1
    done
    # An unexpected web exit must restart the container, not silently disable it.
    if [ -n "$web_pid" ]; then
        wait "$web_pid"
        exit 0
    fi
done
