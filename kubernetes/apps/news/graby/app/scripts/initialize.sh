#!/bin/sh
# Every child, retry and download shares this outer deadline.
set -eu
exec timeout --signal=TERM --kill-after=2s 298s /usr/bin/php8.4 -d extension=tidy "$(dirname "$0")/initialize.php"
