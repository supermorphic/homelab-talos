#!/bin/sh
set -eu
umask 077
mkdir -p /run/news /tmp/news-sessions
php /opt/news/bootstrap.php

httpd -f /opt/news-httpd.conf -D FOREGROUND &
web_pid=$!
(
    while sleep 900; do
        sh /opt/news/refresh.sh || true
    done
) &
refresh_pid=$!
cleanup() {
    trap - TERM INT EXIT
    kill "$refresh_pid" "$web_pid" 2>/dev/null || true
    wait "$refresh_pid" "$web_pid" 2>/dev/null || true
}
trap cleanup TERM INT EXIT
wait "$web_pid"
