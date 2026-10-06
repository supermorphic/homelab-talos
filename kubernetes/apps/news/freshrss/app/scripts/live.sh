#!/bin/sh
set -eu
pid=$(cat /run/news/supervisor.pid)
stamp=$(cat /run/news/supervisor-heartbeat)
kill -0 "$pid"
[ "$(( $(date +%s) - stamp ))" -lt 120 ]
